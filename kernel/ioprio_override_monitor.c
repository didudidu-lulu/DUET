// SPDX-License-Identifier: GPL-2.0-only
/*
 * Revoke ioprio_override (BFQ burst scheduling hint) when a thread's CPU use
 * exceeds a small fraction of wall time over a sampling window.
 */

#include <linux/sched.h>
#include <linux/sched/cputime.h>
#include <linux/sched/task.h>
#include <linux/ktime.h>
#include <linux/workqueue.h>
#include <linux/mutex.h>
#include <linux/jiffies.h>
#include <linux/init.h>
#include <linux/moduleparam.h>
#include <linux/sysctl.h>

/* Minimum wall interval before applying the CPU ratio (reduces tick noise). */
#define IOPRIO_MON_MIN_WINDOW_NS	(100 * NSEC_PER_MSEC)

/* Reschedule interval for the monitor worker. */
#define IOPRIO_MON_TICK_MS		250

/*
 * Revoke when (delta_cpu / delta_wall) > 1/100 — i.e. sustained use of more
 * than one percent of a single CPU over the sample window.
 */
#define IOPRIO_MON_CPU_PCT_NUM		1
#define IOPRIO_MON_CPU_PCT_DEN		100

static LIST_HEAD(ioprio_override_tasks);
static DEFINE_MUTEX(ioprio_override_tasks_lock);
static struct delayed_work ioprio_override_work;
static bool ioprio_override_work_scheduled;
static int ioprio_override_cpu_monitor;
module_param_named(ioprio_override_monitor, ioprio_override_cpu_monitor, int, 0644);
MODULE_PARM_DESC(ioprio_override_monitor,
		 "Enable CPU-based revocation for ioprio_override tasks");

static const struct ctl_table ioprio_override_sysctls[] = {
	{
		.procname	= "ioprio_override_cpu_monitor",
		.data		= &ioprio_override_cpu_monitor,
		.maxlen		= sizeof(ioprio_override_cpu_monitor),
		.mode		= 0644,
		.proc_handler	= proc_dointvec_minmax,
		.extra1		= SYSCTL_ZERO,
		.extra2		= SYSCTL_ONE,
	},
};

static void ioprio_override_revoke_unlist(struct task_struct *p)
{
	bool had = READ_ONCE(p->ioprio_override);

	ioprio_override_revoke(p);

	mutex_lock(&ioprio_override_tasks_lock);
	if (!list_empty(&p->ioprio_override_link))
		list_del_init(&p->ioprio_override_link);
	mutex_unlock(&ioprio_override_tasks_lock);

	if (had)
		pr_info_ratelimited("ioprio_override: revoked burst pid=%d comm=%s (cpu > %d%% over window)\n",
				    task_pid_nr(p), p->comm,
				    (100 * IOPRIO_MON_CPU_PCT_NUM) / IOPRIO_MON_CPU_PCT_DEN);
}

static void ioprio_override_sample_task(struct task_struct *p)
{
	u64 ut, st, wall, cpu_total, d_cpu, d_wall;
	bool revoke = false;

	task_lock(p);
	if (!READ_ONCE(p->ioprio_override)) {
		task_unlock(p);
		return;
	}

	task_cputime_adjusted(p, &ut, &st);
	cpu_total = ut + st;
	wall = ktime_get_ns();

	if (p->ioprio_mon_last_wall_ns) {
		d_wall = wall - p->ioprio_mon_last_wall_ns;
		d_cpu = cpu_total - p->ioprio_mon_last_cpu_ns;
		if (d_wall >= IOPRIO_MON_MIN_WINDOW_NS &&
		    d_cpu * IOPRIO_MON_CPU_PCT_DEN > d_wall * IOPRIO_MON_CPU_PCT_NUM)
			revoke = true;
	}

	if (!revoke) {
		p->ioprio_mon_last_cpu_ns = cpu_total;
		p->ioprio_mon_last_wall_ns = wall;
	}
	task_unlock(p);

	if (revoke)
		ioprio_override_revoke_unlist(p);
}

static void ioprio_ov_cpu_work_fn(struct work_struct *work)
{
#if IS_ENABLED(CONFIG_BLOCK)
	struct task_struct *snap[64];
	struct task_struct *p;
	int i, n;

	mutex_lock(&ioprio_override_tasks_lock);
	if (!READ_ONCE(ioprio_override_cpu_monitor)) {
		ioprio_override_work_scheduled = false;
		mutex_unlock(&ioprio_override_tasks_lock);
		return;
	}

	n = 0;
	list_for_each_entry(p, &ioprio_override_tasks, ioprio_override_link) {
		if (n >= ARRAY_SIZE(snap))
			break;
		get_task_struct(p);
		snap[n++] = p;
	}

	if (!n) {
		ioprio_override_work_scheduled = false;
		mutex_unlock(&ioprio_override_tasks_lock);
		return;
	}
	mutex_unlock(&ioprio_override_tasks_lock);

	for (i = 0; i < n; i++) {
		ioprio_override_sample_task(snap[i]);
		put_task_struct(snap[i]);
	}

	mutex_lock(&ioprio_override_tasks_lock);
	if (READ_ONCE(ioprio_override_cpu_monitor) &&
	    !list_empty(&ioprio_override_tasks)) {
		queue_delayed_work(system_wq, to_delayed_work(work),
				   msecs_to_jiffies(IOPRIO_MON_TICK_MS));
		ioprio_override_work_scheduled = true;
	} else {
		ioprio_override_work_scheduled = false;
	}
	mutex_unlock(&ioprio_override_tasks_lock);
#else
	(void)work;
#endif
}

void ioprio_override_fork_init(struct task_struct *p)
{
	INIT_LIST_HEAD(&p->ioprio_override_link);
	p->ioprio_mon_last_cpu_ns = 0;
	p->ioprio_mon_last_wall_ns = 0;
	p->ioprio_override = false;
}

void ioprio_override_exit_detach(struct task_struct *p)
{
#if IS_ENABLED(CONFIG_BLOCK)
	mutex_lock(&ioprio_override_tasks_lock);
	if (!list_empty(&p->ioprio_override_link))
		list_del_init(&p->ioprio_override_link);
	mutex_unlock(&ioprio_override_tasks_lock);
#endif
}

void ioprio_override_monitor_enqueue(struct task_struct *p)
{
#if IS_ENABLED(CONFIG_BLOCK)
	u64 ut, st, wall;

	if (!READ_ONCE(ioprio_override_cpu_monitor))
		return;

	mutex_lock(&ioprio_override_tasks_lock);
	task_lock(p);
	if (READ_ONCE(p->ioprio_override)) {
		task_cputime_adjusted(p, &ut, &st);
		wall = ktime_get_ns();
		p->ioprio_mon_last_cpu_ns = ut + st;
		p->ioprio_mon_last_wall_ns = wall;
		if (list_empty(&p->ioprio_override_link)) {
			list_add_tail(&p->ioprio_override_link, &ioprio_override_tasks);
			if (!ioprio_override_work_scheduled) {
				queue_delayed_work(system_wq, &ioprio_override_work, 0);
				ioprio_override_work_scheduled = true;
			}
		}
	}
	task_unlock(p);
	mutex_unlock(&ioprio_override_tasks_lock);
#endif
}

static int __init ioprio_override_monitor_init(void)
{
#if IS_ENABLED(CONFIG_BLOCK)
	INIT_DELAYED_WORK(&ioprio_override_work, ioprio_ov_cpu_work_fn);
	ioprio_override_work_scheduled = false;
	register_sysctl_init("kernel", ioprio_override_sysctls);
#endif
	return 0;
}
subsys_initcall(ioprio_override_monitor_init);
