#!/bin/bash
# Shared helpers for ioprio_override CPU-monitor experiments.
# Source from other scripts:  source "$(dirname "$0")/exp_common.sh"
#
# burst_task：仓库中 burst_task.c 保持 /dev/nvme0n1；exp_build_tools 用 sed
# 将副本里的该路径替换为 TEST_DEV 后再编译 ./burst_task。

: "${TEST_DEV:=/dev/nvme0n1}"
# 默认 4MiB/4MiB（duet_same 典型门限）；exp_a/exp_b 会 export 强制此值
: "${BFQ_HIGH_BYTES:=4194304}"
: "${BFQ_LOW_BYTES:=4194304}"
: "${FIO_BG_COUNT:=8}"
: "${FIO_BS:=1M}"
# 与 lowthreshold_clean.sh 中 generate_sustained_fio 一致：ramp 3s、runtime 30s
: "${FIO_RAMP_TIME:=3}"
: "${FIO_RUNTIME:=30}"
# 瞬时带宽采样间隔（ms）：fio --write_bw_log + log_avg_msec、malicious_sustained MAL_BW_LOG 同步使用。
# 设 0 关闭 fio 的 bw log（仅写聚合 json）。malicious 是否写 log 由调用方设 MAL_BW_LOG 环境变量决定。
: "${BW_LOG_INTERVAL_MS:=200}"

export EXP_COMMON_LOADED=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
BLK_SVC="$(basename "$TEST_DEV")"
IOPRIO_MON_SYSCTL="/proc/sys/kernel/ioprio_override_cpu_monitor"

exp_check_sysctl() {
	if [[ ! -f "$IOPRIO_MON_SYSCTL" ]]; then
		echo "ERROR: $IOPRIO_MON_SYSCTL missing." >&2
		echo "  当前内核: $(uname -r)" >&2
		echo "  请在本仓库编译并安装/启动包含 sched/core.c 中 ioprio_override_cpu_monitor sysctl 的内核后重试。" >&2
		return 1
	fi
	return 0
}

exp_set_cpu_monitor() {
	local v="${1:?}"
	exp_check_sysctl || return 1
	echo "$v" | sudo tee "$IOPRIO_MON_SYSCTL" >/dev/null
	# 写到 stderr：run_phase 的 stdout 被 tee 进 summary.tsv，避免污染
	echo "kernel.ioprio_override_cpu_monitor=$(cat "$IOPRIO_MON_SYSCTL")" >&2
}

exp_setup_bfq_bdev() {
	echo "bfq" | sudo tee "/sys/block/$BLK_SVC/queue/scheduler" >/dev/null
	if [[ ! -x "$SCRIPT_DIR/bdev_set_bytes" ]]; then
		echo "ERROR: build $SCRIPT_DIR/bdev_set_bytes first (e.g. make in tree)." >&2
		return 1
	fi
	sudo "$SCRIPT_DIR/bdev_set_bytes" "$TEST_DEV" 1 "$BFQ_HIGH_BYTES" "$BFQ_LOW_BYTES"
	echo "BFQ + bdev_set_bytes on $TEST_DEV high=$BFQ_HIGH_BYTES low=$BFQ_LOW_BYTES" >&2
}

# 运行时动态切换 bdev_set_bytes 状态（不重设调度器，假设已是 bfq）。
# 用于 G4：enable=0 关闭字节限流，让 BFQ 退化为纯优先级调度。
exp_set_bdev_bytes() {
	local enable="${1:?}"
	local high="${2:-0}"
	local low="${3:-0}"
	if [[ ! -x "$SCRIPT_DIR/bdev_set_bytes" ]]; then
		echo "ERROR: bdev_set_bytes 未编译" >&2
		return 1
	fi
	sudo "$SCRIPT_DIR/bdev_set_bytes" "$TEST_DEV" "$enable" "$high" "$low"
	echo "bdev_set_bytes on $TEST_DEV enable=$enable high=$high low=$low" >&2
}

exp_drop_caches() {
	sync
	echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null 2>&1 || true
}

# 在 phase 开始处写入对齐基准：CLOCK_BOOTTIME (与 dmesg printk 时戳同源) + wall time。
# 文件格式: 单行  t_boot_s<TAB>t_wall_s
# malicious_sustained 与 fio bw log 都按 boot 时间序列采样，plotter 用 t_boot_s 做 t=0。
exp_record_phase_t0() {
	local out="${1:?}"
	python3 - "$out" <<'PY'
import sys, time
out = sys.argv[1]
t_boot = time.clock_gettime(time.CLOCK_BOOTTIME)
t_wall = time.time()
with open(out, "w") as f:
    f.write(f"{t_boot:.6f}\t{t_wall:.6f}\n")
PY
}

# 把当前 CLOCK_BOOTTIME 秒数附加到日志（用于 ionice 触发时点对齐到 dmesg 时戳域）
exp_now_boot_s() {
	python3 -c 'import time; print(f"{time.clock_gettime(time.CLOCK_BOOTTIME):.6f}")'
}

exp_build_tools() {
	(
		cd "$SCRIPT_DIR" || exit 1
		gcc -O2 -o bdev_set_bytes bdev_set_bytes.c
		gcc -O2 -o bdev_get_bytes bdev_get_bytes.c
		# burst_task.c 保持仓库原样；按 TEST_DEV 生成临时 .c 再编译
		local dev="${TEST_DEV:-/dev/nvme0n1}"
		local tmp
		tmp="$(mktemp "$SCRIPT_DIR/.burst_task_build.XXXXXX.c")"
		sed "s#/dev/nvme0n1#${dev}#g" burst_task.c >"$tmp"
		gcc -O2 -o burst_task "$tmp" -laio
		rm -f "$tmp"
		gcc -O2 -o malicious_sustained malicious_sustained.c -laio -lpthread
		gcc -O2 -o ioprio_override ioprio_override.c
	)
}

# 队列字节数后台观察：每 QUEUE_WATCH_INTERVAL_SEC 秒打印一次 bdev_get_bytes 读到的 io_bytes，
# 仅用于人工观测，**写到 stderr**，避免污染 run_phase 的 stdout（后者被 tee 进 summary.tsv）。
# 设 QUEUE_WATCH_INTERVAL_SEC=0 禁用。
: "${QUEUE_WATCH_INTERVAL_SEC:=1}"
QUEUE_WATCH_PID=""

exp_start_queue_watch() {
	local label="${1:-?}"
	local interval="${QUEUE_WATCH_INTERVAL_SEC:-1}"
	QUEUE_WATCH_PID=""
	[[ "$interval" == "0" ]] && return 0
	if [[ ! -x "$SCRIPT_DIR/bdev_get_bytes" ]]; then
		echo "[queue-watch] bdev_get_bytes not built; skipping" >&2
		return 0
	fi
	(
		while :; do
			local raw mib
			raw=$("$SCRIPT_DIR/bdev_get_bytes" "$TEST_DEV" 2>/dev/null || true)
			if [[ "$raw" =~ ^-?[0-9]+$ ]]; then
				mib=$(awk -v b="$raw" 'BEGIN { printf "%.2f", b / 1048576 }')
				printf '  [queue] %s phase=%s io_bytes=%s (%s MiB)\n' \
					"$(date '+%H:%M:%S')" "$label" "$raw" "$mib" >&2
			fi
			sleep "$interval"
		done
	) &
	QUEUE_WATCH_PID=$!
}

exp_stop_queue_watch() {
	if [[ -n "${QUEUE_WATCH_PID:-}" ]]; then
		kill "$QUEUE_WATCH_PID" 2>/dev/null || true
		wait "$QUEUE_WATCH_PID" 2>/dev/null || true
		QUEUE_WATCH_PID=""
	fi
}

exp_write_sustained_fio() {
	local out="$1"
	local bw_log_prefix="${2:-}"
	local bg="$FIO_BG_COUNT"
	local bs="$FIO_BS"
	local ramp="$FIO_RAMP_TIME"
	local rt="$FIO_RUNTIME"
	local iv="${BW_LOG_INTERVAL_MS:-200}"

	cat >"$out" <<EOF
[global]
filename=$TEST_DEV
ioengine=libaio
direct=1
time_based
ramp_time=${ramp}s
runtime=${rt}s
rw=read
iodepth=4
group_reporting=1
EOF
	if [[ -n "$bw_log_prefix" && "$iv" != 0 ]]; then
		cat >>"$out" <<EOF
write_bw_log=${bw_log_prefix}
log_avg_msec=${iv}
per_job_logs=0
log_unix_epoch=1
EOF
	fi
	cat >>"$out" <<EOF

EOF
	local i
	for ((i = 1; i <= bg; i++)); do
		cat >>"$out" <<EOF
[background_$i]
prioclass=1
prio=7
bs=$bs
numjobs=1

EOF
	done
}

# 运行 sustained fio：JSON 写入 json_out；stdout+stderr 合并到 merged_log
exp_run_fio_sustained() {
	local jobfile="$1"
	local json_out="$2"
	local merged_log="$3"
	if command -v stdbuf >/dev/null 2>&1; then
		stdbuf -oL -eL sudo fio --eta=never --output="$json_out" --output-format=json \
			"$jobfile" >"$merged_log" 2>&1
	else
		sudo fio --eta=never --output="$json_out" --output-format=json \
			"$jobfile" >"$merged_log" 2>&1
	fi
}

# 打印 sustained 读带宽（MiB/s）：优先解析 fio「Run status group」汇总行；再 per-job read 行求和；
# JSON 在 group_reporting 各 job 带宽相同时只取一条，避免 N 倍累加。
exp_fio_read_bw_mibs() {
	local jf="$1"
	local log="${2:-}"
	python3 - "$jf" "$log" <<'PY'
import json, re, sys

def mib_from_kibs(kibs):
    return float(kibs) / 1024.0

def mib_from_bps(bps):
    return float(bps) / (1024.0 * 1024.0)


def mibs_from_bw_match(m):
    val = float(m.group(1))
    u = (m.group(2) or "").upper()
    mult = {"K": 1.0 / 1024.0, "M": 1.0, "G": 1024.0, "T": 1024.0 * 1024.0}.get(
        u, 1.0 / 1024.0
    )
    if u == "":
        mult = 1.0 / 1024.0
    return val * mult


def parse_read_line_mibs(ln):
    """fio 3.x: READ: bw=…  或  read: IOPS=…, BW=…MiB/s"""
    m = re.search(
        r"(?:READ|read)\s*:\s*bw\s*=\s*([0-9.]+)\s*([KMGT]?)i?B/s",
        ln,
        re.I,
    )
    if m:
        return mibs_from_bw_match(m)
    m = re.search(
        r"(?:READ|read)\s*:.*?\bBW\s*=\s*([0-9.]+)\s*([KMGT]?)i?B/s",
        ln,
        re.I,
    )
    if m:
        return mibs_from_bw_match(m)
    return None


def from_human_run_status(txt):
    """group_reporting=1 时整组一行：紧跟 Run status group … (all jobs): 的 READ: bw=…"""
    lines = txt.splitlines()
    for i, ln in enumerate(lines):
        if "Run status group" not in ln and "(all jobs)" not in ln:
            continue
        for j in range(i + 1, min(i + 6, len(lines))):
            ln2 = lines[j].strip()
            if not ln2:
                break
            if re.match(r"WRITE\s*:", ln2, re.I):
                break
            if re.search(r"(?:READ|read)\s*:", ln2, re.I) and "bw=" in ln2.lower():
                v = parse_read_line_mibs(lines[j])
                if v is not None:
                    return v
    return None


def from_human_sum_per_job(txt):
    """无 Run status 块时：对各 job 的 read: IOPS=…, BW=… 求和（避免与组汇总混计）"""
    s = 0.0
    n = 0
    for ln in txt.splitlines():
        if "bw=" not in ln.lower():
            continue
        if not re.search(r"(?:READ|read)\s*:\s*IOPS\s*=", ln, re.I):
            continue
        v = parse_read_line_mibs(ln)
        if v is not None:
            s += v
            n += 1
    return s if n else None


def from_human_last(txt):
    """最后一条含 read:/READ: 与 bw/BW 的行（旧逻辑，略放宽大小写）"""
    last = None
    for ln in txt.splitlines():
        if "bw=" not in ln.lower():
            continue
        if not re.search(r"(?:^|\s)(?:READ|read)\s*:", ln, re.I):
            continue
        v = parse_read_line_mibs(ln)
        if v is not None:
            last = v
    return last


def from_json(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            raw = f.read().strip()
    except OSError:
        return None
    if not raw:
        return None
    j = None
    try:
        j = json.loads(raw)
    except json.JSONDecodeError:
        for part in reversed(raw.split("\n}\n")):
            part = part.strip()
            if not part:
                continue
            if not part.endswith("}"):
                part = part + "}"
            if not part.startswith("{"):
                part = "{" + part
            try:
                j = json.loads(part)
                break
            except json.JSONDecodeError:
                continue
    if j is None:
        return None
    jobs = j.get("jobs")
    if not isinstance(jobs, list) or not jobs:
        return None
    mibs = []
    for job in jobs:
        r = job.get("read")
        if not isinstance(r, dict):
            continue
        mib = None
        bb = r.get("bw_bytes")
        if bb is not None:
            try:
                mib = mib_from_bps(float(bb))
            except (TypeError, ValueError):
                mib = None
        if mib is None:
            bw = r.get("bw")
            if bw is not None:
                try:
                    mib = mib_from_kibs(float(bw))
                except (TypeError, ValueError):
                    mib = None
        if mib is not None:
            mibs.append(mib)
    if not mibs:
        return None
    lo, hi = min(mibs), max(mibs)
    # group_reporting 下各 job 常带相同「组总带宽」：再 sum 会放大 N 倍
    if hi > 0 and lo > 0 and (hi - lo) / hi <= 1e-5:
        return mibs[0]
    return sum(mibs)


def from_human(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            txt = f.read()
    except OSError:
        return None
    for fn in (from_human_run_status, from_human_sum_per_job, from_human_last):
        v = fn(txt)
        if v is not None:
            return v
    return None


jf = sys.argv[1]
lg = sys.argv[2] if len(sys.argv) > 2 else ""
v = from_human(lg) if lg else None
if v is None:
    v = from_json(jf)
if v is None:
    print("nan")
else:
    print(f"{v:.6f}")
PY
}

# 仅统计 burst_task「每轮汇总」行，避免误计 AIO #n latency=… 单行延迟
exp_burst_avg_latency_us() {
	local log="$1"
	awk '/^Average latency:/ {
		for (i = 1; i <= NF; i++)
			if ($i == "latency:" && $(i+1) ~ /^[0-9.]+/) {
				sub(/μs/, "", $(i+1))
				s += $(i+1)
				n++
			}
	}
	END { if (n > 0) printf "%.2f\n", s/n; else print "nan" }' "$log" 2>/dev/null || echo "nan"
}

# One line per burst round: round<TAB>avg_latency_us (from burst_task Summary + Average latency)
exp_burst_latency_rounds_tsv() {
	local log="$1"
	local out="$2"
	{
		printf 'round\tlatency_us\n'
		awk '
		/Burst Round #/ && /Summary/ {
			round = 0
			if (match($0, /#([0-9]+)/)) {
				round = substr($0, RSTART + 1, RLENGTH - 1) + 0
			}
		}
		/^Average latency:/ {
			for (i = 1; i <= NF; i++)
				if ($i == "latency:" && $(i+1) ~ /^[0-9.]+/) {
					v = $(i+1)
					sub(/μs/, "", v)
					if (round > 0)
						print round "\t" v
				}
		}
		' "$log" 2>/dev/null
	} >"$out"
}

# 由 burst_latency_by_round.tsv 计算 p50 / p95 / mean（μs）
# 另写 min/max、10%–90% 截尾均值、tail 说明：算术均值可被少数极大轮次拉高，而 p95 仍落在主体分布内。
exp_burst_latency_quantiles() {
	local tsv="$1"
	local out_p50="$2"
	local out_p95="$3"
	local out_mean="$4"
	python3 - "$tsv" "$out_p50" "$out_p95" "$out_mean" <<'PY'
import math
import os
import sys

path, p50f, p95f, meanf = sys.argv[1:5]
outdir = os.path.dirname(meanf)
vals = []
try:
    with open(path, encoding="utf-8", errors="replace") as f:
        hdr = f.readline()
        for ln in f:
            ln = ln.strip()
            if not ln:
                continue
            parts = ln.split("\t")
            if len(parts) >= 2:
                vals.append(float(parts[1]))
except OSError:
    pass
if not vals:
    for p in (p50f, p95f, meanf):
        with open(p, "w") as f:
            f.write("nan\n")
    for name in (
        "burst_latency_min_us.txt",
        "burst_latency_max_us.txt",
        "burst_latency_trimmed_mean_10_90_us.txt",
        "burst_latency_tail_note.txt",
    ):
        with open(os.path.join(outdir, name), "w") as f:
            f.write("nan\n" if name != "burst_latency_tail_note.txt" else "(none)\n")
    raise SystemExit(0)
vals.sort()


def lin_quantile(data, q):
    """q in [0,1], linear interpolation between closest ranks (like numpy)."""
    if not data:
        return float("nan")
    if len(data) == 1:
        return data[0]
    pos = (len(data) - 1) * q
    lo = int(math.floor(pos))
    hi = int(math.ceil(pos))
    if lo == hi:
        return data[lo]
    return data[lo] * (hi - pos) + data[hi] * (pos - lo)


n = len(vals)
mean = sum(vals) / n
p50 = lin_quantile(vals, 0.50)
p95 = lin_quantile(vals, 0.95)
vmin, vmax = vals[0], vals[-1]
k = n // 10
if n > 2 * k and k > 0:
    mid = vals[k : n - k]
    tmean = sum(mid) / len(mid)
else:
    tmean = mean

note = "(none)\n"
if n >= 5 and mean > p95 * 1.5 and vmax > p95 * 2:
    note = (
        "mean >> p95: 少数极大轮次拉高算术均值；p50/p95 仍反映主体分布。"
        " 见 burst_latency_max_us.txt、burst_latency_trimmed_mean_10_90_us.txt。\n"
    )

with open(p50f, "w") as f:
    f.write(f"{p50:.2f}\n")
with open(p95f, "w") as f:
    f.write(f"{p95:.2f}\n")
with open(meanf, "w") as f:
    f.write(f"{mean:.2f}\n")
with open(os.path.join(outdir, "burst_latency_min_us.txt"), "w") as f:
    f.write(f"{vmin:.2f}\n")
with open(os.path.join(outdir, "burst_latency_max_us.txt"), "w") as f:
    f.write(f"{vmax:.2f}\n")
with open(os.path.join(outdir, "burst_latency_trimmed_mean_10_90_us.txt"), "w") as f:
    f.write(f"{tmean:.2f}\n")
with open(os.path.join(outdir, "burst_latency_tail_note.txt"), "w") as f:
    f.write(note)
PY
}

# malicious_sustained 退出时打印: MAL_SUMMARY ios=... avg_latency_us=... throughput_MiB_s=...
exp_malicious_stats_from_log() {
	local log="$1"
	local out_ios="$2"
	local out_lat="$3"
	local out_bw="$4"
	python3 - "$log" "$out_ios" "$out_lat" "$out_bw" <<'PY'
import re, sys
path, p_ios, p_lat, p_bw = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
line = ""
try:
    with open(path, encoding="utf-8", errors="replace") as f:
        for ln in f:
            if "MAL_SUMMARY" in ln:
                line = ln.strip()
except OSError:
    pass

def grab(pat):
    if not line:
        return "nan"
    m = re.search(pat, line)
    return m.group(1) if m else "nan"

ios = grab(r"ios=(\d+)")
lat = grab(r"avg_latency_us=([0-9.eE+-]+)")
bw = grab(r"throughput_MiB_s=([0-9.eE+-]+)")
for p, v in ((p_ios, ios), (p_lat, lat), (p_bw, bw)):
    with open(p, "w") as f:
        f.write(v + "\n")
PY
}

exp_kill_children() {
	sudo pkill -f malicious_sustained 2>/dev/null || true
	sudo pkill -f burst_task 2>/dev/null || true
	sleep 1
}
