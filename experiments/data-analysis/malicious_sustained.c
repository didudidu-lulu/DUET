/*
 * Sustained (back-to-back) direct I/O for burst-bypass abuse experiments.
 * Does NOT call ioprio_override itself — the shell calls ./ioprio_override <pid>.
 * Periodic CPU spin so revocation heuristics can trigger when monitoring is on.
 *
 * On exit (signal or EOF), prints one line to stdout:
 *   MAL_SUMMARY ios=N avg_latency_us=X wall_s=Y throughput_MiB_s=Z
 *
 * Optional periodic bandwidth log (for time-series plots):
 *   env MAL_BW_LOG=<path>            tab-separated columns appended:
 *      t_boot_s   cum_ios   cum_bytes   cum_lat_ns
 *   env MAL_BW_LOG_INTERVAL_MS=<n>   sample period (default 200 ms)
 *   First line is a header.
 *
 * IMPORTANT: samples are written by a dedicated pthread driven by
 * clock_nanosleep(CLOCK_BOOTTIME). This guarantees samples land even when the
 * I/O thread is starved (e.g. demoted to BE while another RT task hogs the
 * disk) — without it, io_getevents blocks for many seconds and no samples are
 * produced, causing time-series plots to falsely "interpolate" the gap.
 *
 * I/O profile (aligned with exp_common sustained fio): 1 MiB O_DIRECT pread,
 * libaio with AIO_DEPTH=4 outstanding requests (same as fio iodepth=4).
 *
 * Usage: sudo ionice -c1 -n7 ./malicious_sustained [block_device]
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <libaio.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define IO_ALIGN (1048576u) // 1MB
#define AIO_DEPTH 32
#define SPIN_EVERY_IOS 32
#define SPIN_ITERS 400000u

static volatile sig_atomic_t running = 1;

/* Counters updated by the I/O thread, read by the sampler thread.
 * Atomic + acquire/release across both threads avoids needing a mutex on
 * the hot I/O path. Each counter fits in 64 bits → naturally atomic on
 * x86_64, but we still use stdatomic for portability and to avoid the
 * compiler reordering reads/writes around the sampler tick.
 */
static atomic_ullong g_cum_ios;
static atomic_ullong g_cum_bytes;
static atomic_llong g_cum_lat_ns;

static void on_sig(int sig)
{
	(void)sig;
	running = 0;
}

static long long now_ns(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (long long)ts.tv_sec * 1000000000LL + ts.tv_nsec;
}

/* CLOCK_BOOTTIME matches the kernel printk timestamp domain used by dmesg
 * (seconds since boot). Aligning the malicious bandwidth log to the same
 * clock lets the plotter overlay revoke timestamps from dmesg directly.
 */
static double now_boot_s(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_BOOTTIME, &ts);
	return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

static void cpu_spin(void)
{
	volatile unsigned long x = 0;
	unsigned int i;

	for (i = 0; i < SPIN_ITERS; i++)
		x += i * 13u;
	(void)x;
}

struct aio_slot {
	struct iocb cb;
	void *buf;
	long long submit_ns;
};

static int submit_slot(int fd, io_context_t ctx, struct aio_slot *slot,
		       unsigned long seq)
{
	off_t off = (off_t)((seq % 1000000u) * IO_ALIGN);
	struct iocb *cbp = &slot->cb;

	io_prep_pread(&slot->cb, fd, slot->buf, IO_ALIGN, off);
	/* io_prep_pread() memset's the whole iocb — set data after, not before. */
	slot->cb.data = slot;
	slot->submit_ns = now_ns();
	if (io_submit(ctx, 1, &cbp) != 1)
		return -1;
	return 0;
}

struct sampler_args {
	FILE *fp;
	int interval_ms;
};

/* Independent ticker thread: every interval_ms (CLOCK_BOOTTIME absolute),
 * snapshot the counters and write one TSV line. Driven by clock_nanosleep
 * with TIMER_ABSTIME so cumulative drift is bounded.
 */
static void *sampler_thread(void *arg)
{
	struct sampler_args *sa = (struct sampler_args *)arg;
	struct timespec next;

	clock_gettime(CLOCK_BOOTTIME, &next);
	while (__atomic_load_n(&running, __ATOMIC_RELAXED)) {
		long add_ns;
		double t;
		unsigned long long ios, bytes;
		long long lat;

		add_ns = (long)sa->interval_ms * 1000000L;
		next.tv_nsec += add_ns;
		while (next.tv_nsec >= 1000000000L) {
			next.tv_nsec -= 1000000000L;
			next.tv_sec += 1;
		}
		if (clock_nanosleep(CLOCK_BOOTTIME, TIMER_ABSTIME, &next,
				    NULL) != 0) {
			if (errno == EINTR)
				continue;
			break;
		}
		t = (double)next.tv_sec + (double)next.tv_nsec / 1e9;
		ios = atomic_load_explicit(&g_cum_ios, memory_order_acquire);
		bytes = atomic_load_explicit(&g_cum_bytes, memory_order_acquire);
		lat = atomic_load_explicit(&g_cum_lat_ns, memory_order_acquire);
		fprintf(sa->fp, "%.6f\t%llu\t%llu\t%lld\n", t, ios, bytes,
			lat);
		fflush(sa->fp);
	}
	return NULL;
}

static void print_summary(unsigned long ios, long long sum_lat_ns,
			  double wall_s)
{
	double avg_us = 0.0;
	double mib_s = 0.0;

	if (ios > 0 && sum_lat_ns > 0)
		avg_us = (double)sum_lat_ns / (double)ios / 1000.0;
	if (wall_s > 0.0 && ios > 0)
		mib_s = ((double)ios * (double)IO_ALIGN) / (wall_s * 1024.0 * 1024.0);

	printf("MAL_SUMMARY ios=%lu avg_latency_us=%.2f wall_s=%.3f throughput_MiB_s=%.6f\n",
	       ios, avg_us, wall_s, mib_s);
	fflush(stdout);
}

int main(int argc, char *argv[])
{
	const char *dev = (argc > 1) ? argv[1] : "/dev/nvme0n1";
	const char *bw_log_path = getenv("MAL_BW_LOG");
	int bw_interval_ms = 200;
	FILE *bw_fp = NULL;
	pthread_t sampler;
	int sampler_started = 0;
	struct sampler_args sa = {0};
	int fd;
	struct aio_slot slots[AIO_DEPTH];
	io_context_t ctx = 0;
	struct io_event events[AIO_DEPTH];
	unsigned long ios;
	unsigned long next_seq;
	int inflight;
	unsigned int si;
	long long sum_lat_ns = 0;
	long long wall0, wall1;

	signal(SIGINT, on_sig);
	signal(SIGTERM, on_sig);

	atomic_store(&g_cum_ios, 0ULL);
	atomic_store(&g_cum_bytes, 0ULL);
	atomic_store(&g_cum_lat_ns, 0LL);

	if (bw_log_path && *bw_log_path) {
		const char *env_iv = getenv("MAL_BW_LOG_INTERVAL_MS");

		if (env_iv && *env_iv) {
			int v = atoi(env_iv);

			if (v >= 10 && v <= 60000)
				bw_interval_ms = v;
		}
		bw_fp = fopen(bw_log_path, "w");
		if (bw_fp) {
			fprintf(bw_fp,
				"t_boot_s\tcum_ios\tcum_bytes\tcum_lat_ns\n");
			/* Initial t=0 sample with all zeros, to anchor the
			 * plotter's first interval rate computation.
			 */
			fprintf(bw_fp, "%.6f\t0\t0\t0\n", now_boot_s());
			fflush(bw_fp);
		} else {
			fprintf(stderr,
				"malicious_sustained: failed to open MAL_BW_LOG=%s: %s\n",
				bw_log_path, strerror(errno));
		}
	}

	fd = open(dev, O_RDONLY | O_DIRECT);
	if (fd < 0) {
		perror("open");
		if (bw_fp)
			fclose(bw_fp);
		return 1;
	}

	for (si = 0; si < AIO_DEPTH; si++) {
		slots[si].buf = NULL;
		if (posix_memalign(&slots[si].buf, IO_ALIGN, IO_ALIGN) != 0) {
			perror("posix_memalign");
			while (si > 0)
				free(slots[--si].buf);
			close(fd);
			if (bw_fp)
				fclose(bw_fp);
			return 1;
		}
	}

	if (io_setup(AIO_DEPTH, &ctx) < 0) {
		perror("io_setup");
		for (si = 0; si < AIO_DEPTH; si++)
			free(slots[si].buf);
		close(fd);
		if (bw_fp)
			fclose(bw_fp);
		return 1;
	}

	fprintf(stderr,
		"malicious_sustained pid=%d dev=%s bs=%u iodepth=%d (libaio pipeline + CPU spin)%s%s\n",
		(int)getpid(), dev, IO_ALIGN, AIO_DEPTH,
		bw_fp ? " bw_log=" : "",
		bw_fp ? bw_log_path : "");

	if (bw_fp) {
		sa.fp = bw_fp;
		sa.interval_ms = bw_interval_ms;
		if (pthread_create(&sampler, NULL, sampler_thread, &sa) == 0)
			sampler_started = 1;
		else
			fprintf(stderr,
				"malicious_sustained: pthread_create(sampler) failed: %s\n",
				strerror(errno));
	}

	wall0 = now_ns();
	ios = 0;
	next_seq = 0;
	inflight = 0;
	for (si = 0; si < AIO_DEPTH && running; si++) {
		if (submit_slot(fd, ctx, &slots[si], next_seq++) < 0) {
			perror("io_submit");
			running = 0;
			break;
		}
		inflight++;
	}

	while (inflight > 0) {
		int n, ei;
		long long done_ns;

		n = io_getevents(ctx, 1, AIO_DEPTH, events, NULL);
		if (n < 0) {
			perror("io_getevents");
			break;
		}
		if (n == 0)
			continue;

		done_ns = now_ns();
		for (ei = 0; ei < n; ei++) {
			/* obj points at the completed iocb (inside aio_slot). */
			struct aio_slot *slot = (struct aio_slot *)((char *)events[ei].obj -
					offsetof(struct aio_slot, cb));

			sum_lat_ns += done_ns - slot->submit_ns;
			ios++;

			atomic_store_explicit(&g_cum_ios, (unsigned long long)ios,
					      memory_order_release);
			atomic_store_explicit(&g_cum_bytes,
					      (unsigned long long)ios *
						      (unsigned long long)IO_ALIGN,
					      memory_order_release);
			atomic_store_explicit(&g_cum_lat_ns, sum_lat_ns,
					      memory_order_release);

			if ((ios % SPIN_EVERY_IOS) == 0)
				cpu_spin();

			inflight--;
			if (running &&
			    submit_slot(fd, ctx, slot, next_seq++) < 0) {
				perror("io_submit");
				running = 0;
			} else if (running) {
				inflight++;
			}
		}
	}
	wall1 = now_ns();

	/* Stop sampler: 'running' already cleared by on_sig (or by I/O error).
	 * Wait for it to drain its current sleep so the last write completes
	 * before we close the file.
	 */
	if (sampler_started)
		pthread_join(sampler, NULL);
	if (bw_fp) {
		/* Final sample on the actual exit time (sampler may have just
		 * missed the very last interval).
		 */
		fprintf(bw_fp, "%.6f\t%llu\t%llu\t%lld\n", now_boot_s(),
			(unsigned long long)ios,
			(unsigned long long)ios * (unsigned long long)IO_ALIGN,
			sum_lat_ns);
		fclose(bw_fp);
	}

	{
		double wall_s = (double)(wall1 - wall0) / 1e9;

		if (wall_s <= 0.0)
			wall_s = 1e-9;
		print_summary(ios, sum_lat_ns, wall_s);
	}

	io_destroy(ctx);
	for (si = 0; si < AIO_DEPTH; si++)
		free(slots[si].buf);
	close(fd);
	return 0;
}
