#!/bin/bash
#
# 大量进程上下文切换开销实验（不触发 revoke）
# 基于: perf bench sched messaging (multi-process)
#
# 用法:
#   sudo -v
#   sudo ./exp_cs_monitor_overhead_manyproc.sh
#   （参数见脚本「实验配置」）
#
# 说明:
# - perf bench sched messaging 固定每组 40 个进程
# - 实际进程数 = MSG_GROUPS * 40
# - dense 对 benchmark 子进程树持续 ioprio_override

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
IOPRIO_MON_SYSCTL="/proc/sys/kernel/ioprio_override_cpu_monitor"

# =============================================================================
# 实验配置（改这里即可；环境变量仍可临时覆盖）
# =============================================================================
# RUN_MODE: sweep=按进程数列表依次跑 | single=只跑 TARGET_PROCS 一档
_cfg_RUN_MODE=sweep
_cfg_TARGET_PROCS=100000
_cfg_PROC_SWEEP="10000,20000,40000,60000,80000,100000"
_cfg_RUNS=20
_cfg_LOOPS=20
_cfg_CPU_SET=""
_cfg_USE_PIPE=1
_cfg_DENSE_REAPPLY_MS=50
_cfg_MIN_OVERRIDE_RATIO_PCT=10
_cfg_MIN_OVERRIDE_SMALL_PCT=3       # ACTUAL_PROCS<10000 时用更低比例
_cfg_MIN_OVERRIDE_FLOOR=500
_cfg_MIN_OVERRIDE_SMALL_FLOOR=50
_cfg_MIN_OVERRIDE_BIG_FLOOR=5000
_cfg_AUTO_SCALE_LOOPS=1
_cfg_SWEEP_REF_PROCS=100000
_cfg_MAX_LOOPS=3000
_cfg_SMALL_SCALE_EXTRA_LOOPS=8      # 小规模再放大 loops，拉长 benchmark
_cfg_PREMARK_SPAWN=1                # 1=小规模每轮前先 -l1 预热打标
_cfg_PREMARK_MAX_PROCS=8000         # 仅 ACTUAL_PROCS < 此值时 premark
_cfg_SWEEP_INTERLEAVE=1             # 1=每周期按 2k→10k→50k→100k 交错；0=整档跑完再换规模
_cfg_SUITE_GAP_SEC=3                # off→on 与每组结束后等待秒数；0=不等待

RUN_MODE="${RUN_MODE:-${_cfg_RUN_MODE}}"
TARGET_PROCS="${TARGET_PROCS:-${_cfg_TARGET_PROCS}}"
PROC_SWEEP="${PROC_SWEEP:-${_cfg_PROC_SWEEP}}"
RUNS="${RUNS:-${_cfg_RUNS}}"
LOOPS="${LOOPS:-${_cfg_LOOPS}}"
CPU_SET="${CPU_SET:-${_cfg_CPU_SET}}"
USE_PIPE="${USE_PIPE:-${_cfg_USE_PIPE}}"
DENSE_REAPPLY_MS="${DENSE_REAPPLY_MS:-${_cfg_DENSE_REAPPLY_MS}}"
MIN_OVERRIDE_RATIO_PCT="${MIN_OVERRIDE_RATIO_PCT:-${_cfg_MIN_OVERRIDE_RATIO_PCT}}"
MIN_OVERRIDE_SMALL_PCT="${MIN_OVERRIDE_SMALL_PCT:-${_cfg_MIN_OVERRIDE_SMALL_PCT}}"
MIN_OVERRIDE_FLOOR="${MIN_OVERRIDE_FLOOR:-${_cfg_MIN_OVERRIDE_FLOOR}}"
MIN_OVERRIDE_SMALL_FLOOR="${MIN_OVERRIDE_SMALL_FLOOR:-${_cfg_MIN_OVERRIDE_SMALL_FLOOR}}"
MIN_OVERRIDE_BIG_FLOOR="${MIN_OVERRIDE_BIG_FLOOR:-${_cfg_MIN_OVERRIDE_BIG_FLOOR}}"
AUTO_SCALE_LOOPS="${AUTO_SCALE_LOOPS:-${_cfg_AUTO_SCALE_LOOPS}}"
SWEEP_REF_PROCS="${SWEEP_REF_PROCS:-${_cfg_SWEEP_REF_PROCS}}"
MAX_LOOPS="${MAX_LOOPS:-${_cfg_MAX_LOOPS}}"
SMALL_SCALE_EXTRA_LOOPS="${SMALL_SCALE_EXTRA_LOOPS:-${_cfg_SMALL_SCALE_EXTRA_LOOPS}}"
PREMARK_SPAWN="${PREMARK_SPAWN:-${_cfg_PREMARK_SPAWN}}"
PREMARK_MAX_PROCS="${PREMARK_MAX_PROCS:-${_cfg_PREMARK_MAX_PROCS}}"
SWEEP_INTERLEAVE="${SWEEP_INTERLEAVE:-${_cfg_SWEEP_INTERLEAVE}}"
SUITE_GAP_SEC="${SUITE_GAP_SEC:-${_cfg_SUITE_GAP_SEC}}"

PROCS_PER_GROUP=40
ORIG_MONITOR=""
PERF_BIN=""
PERF_RUN=()
PERF_PRIV="none"

# 由 set_target_procs 更新
MSG_GROUPS=0
ACTUAL_PROCS=0
RUNTIME_LOOPS=0
DENSE_REAPPLY_SEC=""
MIN_OVERRIDE_TARGETS=0
OUTDIR=""
DENSE_OVERRIDE_LOG=""

set_target_procs() {
	local n="$1"
	MSG_GROUPS=$(( (n + PROCS_PER_GROUP - 1) / PROCS_PER_GROUP ))
	ACTUAL_PROCS=$(( MSG_GROUPS * PROCS_PER_GROUP ))

	if (( ACTUAL_PROCS < 10000 )); then
		MIN_OVERRIDE_TARGETS=$(( ACTUAL_PROCS * MIN_OVERRIDE_SMALL_PCT / 100 ))
		(( MIN_OVERRIDE_TARGETS >= MIN_OVERRIDE_SMALL_FLOOR )) || MIN_OVERRIDE_TARGETS=$MIN_OVERRIDE_SMALL_FLOOR
	else
		MIN_OVERRIDE_TARGETS=$(( ACTUAL_PROCS * MIN_OVERRIDE_RATIO_PCT / 100 ))
		if (( ACTUAL_PROCS >= MIN_OVERRIDE_BIG_FLOOR )); then
			(( MIN_OVERRIDE_TARGETS >= MIN_OVERRIDE_BIG_FLOOR )) || MIN_OVERRIDE_TARGETS=$MIN_OVERRIDE_BIG_FLOOR
		else
			(( MIN_OVERRIDE_TARGETS >= MIN_OVERRIDE_FLOOR )) || MIN_OVERRIDE_TARGETS=$MIN_OVERRIDE_FLOOR
		fi
	fi
	(( MIN_OVERRIDE_TARGETS > ACTUAL_PROCS )) && MIN_OVERRIDE_TARGETS=$ACTUAL_PROCS

	RUNTIME_LOOPS=$LOOPS
	if [[ "$AUTO_SCALE_LOOPS" == "1" && "$ACTUAL_PROCS" -lt "$SWEEP_REF_PROCS" ]]; then
		RUNTIME_LOOPS=$(( LOOPS * (SWEEP_REF_PROCS + ACTUAL_PROCS - 1) / ACTUAL_PROCS ))
		(( RUNTIME_LOOPS < LOOPS )) && RUNTIME_LOOPS=$LOOPS
	fi
	if (( ACTUAL_PROCS < 20000 && SMALL_SCALE_EXTRA_LOOPS > 1 )); then
		RUNTIME_LOOPS=$(( RUNTIME_LOOPS * SMALL_SCALE_EXTRA_LOOPS ))
	fi
	(( RUNTIME_LOOPS > MAX_LOOPS )) && RUNTIME_LOOPS=$MAX_LOOPS

	local dense_ms=$DENSE_REAPPLY_MS
	if (( ACTUAL_PROCS < 5000 )); then
		dense_ms=10
	elif (( ACTUAL_PROCS < 20000 )); then
		dense_ms=20
	elif (( ACTUAL_PROCS < 50000 )); then
		dense_ms=30
	fi
	DENSE_REAPPLY_SEC="$(awk -v ms="$dense_ms" 'BEGIN { printf "%.3f", ms / 1000 }')"
}

parse_sweep_list() {
	local raw="${1//,/ }" t
	for t in $raw; do
		t="${t//[[:space:]]/}"
		[[ -n "$t" ]] || continue
		[[ "$t" =~ ^[0-9]+$ ]] || {
			echo "ERROR: PROC_SWEEP 含非法项: $t" >&2
			exit 1
		}
		echo "$t"
	done
}

PERF_PY() { python3 - "$@" <<'PY'
import math
import re
import statistics
import sys
from pathlib import Path


def parse_perf_raw(path):
    task = cs = None
    with open(path, "r", encoding="utf-8", errors="ignore") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            parts = [p.strip() for p in line.split(",")]
            if len(parts) < 3:
                continue
            value, event = parts[0], parts[2]
            if value in ("<not counted>", "<not supported>"):
                continue
            try:
                num = float(value.replace(" ", ""))
            except ValueError:
                continue
            base = event.split(":", 1)[0]
            if base == "task-clock":
                task = num
            elif base == "context-switches":
                cs = num
    return task, cs


def p95(values):
    y = sorted(values)
    if len(y) == 1:
        return y[0]
    k = 0.95 * (len(y) - 1)
    f, c = math.floor(k), math.ceil(k)
    if f == c:
        return y[int(k)]
    return y[f] + (y[c] - y[f]) * (k - f)


def read_summary(path):
    rows = {}
    with open(path, encoding="utf-8") as f:
        hdr = f.readline().strip().split("\t")
        for line in f:
            c = line.strip().split("\t")
            rows[c[0]] = dict(zip(hdr, c))
    return rows


cmd = sys.argv[1]
if cmd == "probe_cs":
    _, cs = parse_perf_raw(sys.argv[2])
    if cs is None:
        sys.exit(2)
    if cs <= 0:
        sys.exit(3)
    print(int(cs))

elif cmd == "append_run":
    raw, bout, out_tsv, run_id = sys.argv[2:6]
    task, cs = parse_perf_raw(raw)
    if task is None or cs is None:
        print("ERROR: 未从 perf 输出解析到 task-clock/context-switches", file=sys.stderr)
        sys.exit(1)
    if cs <= 0:
        print(
            "ERROR: context-switches <= 0（无 root 时 perf 常报 0）。"
            "请 sudo -v 后重跑，确认开头为 perf 执行方式: sudo",
            file=sys.stderr,
        )
        sys.exit(1)
    bench_sec = float("nan")
    with open(bout, "r", encoding="utf-8", errors="ignore") as f:
        m = re.search(r"Total time:\s*([0-9.]+)\s*\[sec\]", f.read())
    if m:
        bench_sec = float(m.group(1))
    avg_ns = task * 1_000_000.0 / cs
    with open(out_tsv, "a", encoding="utf-8") as wf:
        wf.write(f"{run_id}\t{task:.6f}\t{int(cs)}\t{avg_ns:.3f}\t{bench_sec:.6f}\n")

elif cmd == "summarize":
    phase, path = sys.argv[2], sys.argv[3]
    task, cs, avg, bench = [], [], [], []
    with open(path, "r", encoding="utf-8") as f:
        next(f)
        for line in f:
            _, task_ms, cs_cnt, avg_ns, sec = line.strip().split("\t")
            task.append(float(task_ms))
            cs.append(float(cs_cnt))
            avg.append(float(avg_ns))
            bench.append(float(sec))
    n = len(avg)
    std_avg = statistics.stdev(avg) if n >= 2 else 0.0
    ci95 = 1.96 * std_avg / math.sqrt(n) if n >= 2 else 0.0
    print(
        f"{phase}\t{n}\t{statistics.fmean(task):.3f}\t{statistics.fmean(cs):.1f}\t"
        f"{statistics.fmean(avg):.3f}\t{statistics.median(avg):.3f}\t{p95(avg):.3f}\t"
        f"{std_avg:.3f}\t{ci95:.3f}\t{statistics.fmean(bench):.6f}"
    )

elif cmd == "delta":
    path = sys.argv[2]
    rows = read_summary(path)
    off, on = rows["monitor_off"], rows["monitor_on"]
    delta = float(on["avg_cs_ns_mean"]) - float(off["avg_cs_ns_mean"])
    pct = (delta / float(off["avg_cs_ns_mean"]) * 100.0) if float(off["avg_cs_ns_mean"]) else float("nan")
    cs_delta = float(on["context_switches_mean"]) - float(off["context_switches_mean"])
    cs_pct = (cs_delta / float(off["context_switches_mean"]) * 100.0) if float(off["context_switches_mean"]) else float("nan")
    bench_delta = float(on["bench_total_sec_mean"]) - float(off["bench_total_sec_mean"])
    bench_pct = (bench_delta / float(off["bench_total_sec_mean"]) * 100.0) if float(off["bench_total_sec_mean"]) else float("nan")
    print(f"avg_cs_ns_mean (monitor_on - monitor_off): {delta:.3f} ns")
    print(f"relative_overhead(avg_cs_ns): {pct:.3f}%")
    print(f"context_switches_mean (monitor_on - monitor_off): {cs_delta:.1f}")
    print(f"relative_change(context_switches): {cs_pct:.3f}%")
    print(f"bench_total_sec_mean (monitor_on - monitor_off): {bench_delta:.6f} sec")
    print(f"relative_overhead(bench_total_sec): {bench_pct:.3f}%")
    print(f"monitor_off_mean_ci95: {float(off['avg_cs_ns_mean']):.3f} +/- {float(off['avg_cs_ns_ci95']):.3f} ns")
    print(f"monitor_on_mean_ci95: {float(on['avg_cs_ns_mean']):.3f} +/- {float(on['avg_cs_ns_ci95']):.3f} ns")

elif cmd == "sweep_aggregate":
    sweep_dir = Path(sys.argv[2])
    hdr = [
        "target_procs", "actual_procs", "runs",
        "avg_cs_ns_off", "avg_cs_ns_on", "delta_avg_cs_ns", "overhead_pct_avg_cs_ns",
        "context_switches_off", "context_switches_on", "delta_context_switches", "delta_cs_pct",
        "bench_sec_off", "bench_sec_on", "delta_bench_sec", "delta_bench_pct",
    ]
    lines = ["\t".join(hdr)]
    plot_hdr = [
        "target_procs", "actual_procs",
        "delta_avg_cs_ns", "overhead_pct_avg_cs_ns", "delta_cs_pct",
    ]
    plot_lines = [",".join(plot_hdr)]

    for tdir in sorted(sweep_dir.glob("by_target/target_*")):
        summary = tdir / "summary.tsv"
        if not summary.is_file():
            continue
        tp = tdir.name.replace("target_", "")
        rows = read_summary(summary)
        off, on = rows["monitor_off"], rows["monitor_on"]
        try:
            actual_procs = int(float((tdir / "actual_procs.txt").read_text().strip()))
        except OSError:
            actual_procs = int(tp)

        avg_off = float(off["avg_cs_ns_mean"])
        avg_on = float(on["avg_cs_ns_mean"])
        d_avg = avg_on - avg_off
        pct_avg = (d_avg / avg_off * 100.0) if avg_off else float("nan")

        cs_off = float(off["context_switches_mean"])
        cs_on = float(on["context_switches_mean"])
        d_cs = cs_on - cs_off
        pct_cs = (d_cs / cs_off * 100.0) if cs_off else float("nan")

        b_off = float(off["bench_total_sec_mean"])
        b_on = float(on["bench_total_sec_mean"])
        d_b = b_on - b_off
        pct_b = (d_b / b_off * 100.0) if b_off else float("nan")

        lines.append("\t".join([
            tp, str(actual_procs), off["runs"],
            f"{avg_off:.3f}", f"{avg_on:.3f}", f"{d_avg:+.3f}", f"{pct_avg:+.3f}",
            f"{cs_off:.1f}", f"{cs_on:.1f}", f"{d_cs:+.1f}", f"{pct_cs:+.3f}",
            f"{b_off:.6f}", f"{b_on:.6f}", f"{d_b:+.6f}", f"{pct_b:+.3f}",
        ]))
        plot_lines.append(",".join([
            tp, str(actual_procs), f"{d_avg:.3f}", f"{pct_avg:.3f}", f"{pct_cs:.3f}",
        ]))

    out_summary = sweep_dir / "sweep_summary.tsv"
    out_plot = sweep_dir / "plot_sweep.csv"
    out_summary.write_text("\n".join(lines) + "\n", encoding="utf-8")
    out_plot.write_text("\n".join(plot_lines) + "\n", encoding="utf-8")
    print(f"Wrote {out_summary}")
    print(f"Wrote {out_plot}")

else:
    print(f"unknown cmd: {cmd}", file=sys.stderr)
    sys.exit(2)
PY
}

DENSE_PY() {
	local -a runner=(python3 - "$@")
	[[ "$PERF_PRIV" == "sudo" ]] && runner=(sudo -n env LC_ALL=C python3 - "$@")
	"${runner[@]}" <<'PY'
import ctypes
import os
import sys
import time
from collections import defaultdict
from datetime import datetime, timezone

root_pid = int(sys.argv[1])
interval = float(sys.argv[2])
log_path = sys.argv[3]
max_path = sys.argv[4]
phase = sys.argv[5]
run_id = sys.argv[6]

libc = ctypes.CDLL(None, use_errno=True)
syscall_fn = libc.syscall
syscall_fn.argtypes = [ctypes.c_long, ctypes.c_long]
syscall_fn.restype = ctypes.c_long
IOPRIO_OVERRIDE_NR = 468


def read_ppid_map():
    ppid = {}
    for name in os.listdir("/proc"):
        if not name.isdigit():
            continue
        pid = int(name)
        try:
            with open(f"/proc/{pid}/status", encoding="utf-8") as f:
                for line in f:
                    if line.startswith("PPid:"):
                        ppid[pid] = int(line.split()[1])
                        break
        except OSError:
            continue
    return ppid


def list_descendants(root):
    ppid = read_ppid_map()
    children = defaultdict(list)
    for pid, parent in ppid.items():
        children[parent].append(pid)
    out = []
    queue = list(children.get(root, ()))
    while queue:
        pid = queue.pop()
        out.append(pid)
        queue.extend(children.get(pid, ()))
    return out


def apply_override(pid):
    return syscall_fn(IOPRIO_OVERRIDE_NR, pid) == 0


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


peak = 0
while alive(root_pid):
    targets = list_descendants(root_pid)
    applied = sum(1 for pid in targets if apply_override(pid))
    peak = max(peak, applied)
    ts = datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds")
    with open(log_path, "a", encoding="utf-8") as lf:
        lf.write(f"{ts} phase={phase} run={run_id} override_targets={applied}\n")
    with open(max_path, "w", encoding="utf-8") as mf:
        mf.write(str(peak))
    time.sleep(interval)

with open(max_path, "w", encoding="utf-8") as mf:
    mf.write(str(peak))
PY
}

append_taskset_prefix() {
	local -n _dst="$1"
	[[ -n "${CPU_SET:-}" ]] && _dst+=(taskset -c "$CPU_SET")
}

perf_prefix_for_mode() {
	local priv="$2"
	local -n _pfx="$1"
	if [[ "$priv" == "sudo" ]]; then
		_pfx=(sudo -n env LC_ALL=C)
	else
		_pfx=(env LC_ALL=C)
	fi
}

build_perf_stat_cmd() {
	local -n _cmd="$1"
	local priv="$2" groups="$3" loops="$4"
	local -a prefix bench=(bench sched messaging -g "$groups" -l "$loops")
	perf_prefix_for_mode prefix "$priv"
	[[ "$USE_PIPE" == "1" ]] && bench+=(-p)
	_cmd=("${prefix[@]}")
	append_taskset_prefix _cmd
	_cmd+=("$PERF_BIN" stat -x, -r 1 -e task-clock,context-switches
		-- "$PERF_BIN" "${bench[@]}")
}

probe_perf_privileges() {
	local probe cs priv
	probe="$(mktemp)"

	for priv in none sudo; do
		local -a cmd=()
		build_perf_stat_cmd cmd "$priv" 1 1
		if "${cmd[@]}" >"$probe" 2>&1 && cs="$(PERF_PY probe_cs "$probe")"; then
			perf_prefix_for_mode PERF_RUN "$priv"
			PERF_PRIV="$priv"
			echo "perf 探测: $priv 可统计 context-switches (probe_cs=$cs)" >&2
			rm -f "$probe"
			return 0
		fi
	done

	local paranoid
	paranoid="$(cat /proc/sys/kernel/perf_event_paranoid 2>/dev/null || echo '?')"
	echo "ERROR: context-switches 为 0 或不可解析（perf_event_paranoid=$paranoid）。" >&2
	echo "  请先执行: sudo -v" >&2
	tail -5 "$probe" >&2
	rm -f "$probe"
	return 1
}

ensure_perf_privileges() {
	probe_perf_privileges && return 0
	echo "提示: 若 sudoers 仅对 sysctl 免密，请在本终端执行 sudo -v。" >&2
	sudo -v || exit 1
	sudo -n true 2>/dev/null || {
		echo "ERROR: sudo -v 后 sudo -n 仍不可用。" >&2
		exit 1
	}
	probe_perf_privileges || exit 1
}

maybe_refresh_sudo() {
	[[ "$PERF_PRIV" == "sudo" ]] || return 0
	sudo -v -n 2>/dev/null || sudo -v
}

kill_pid_graceful() {
	local pid="${1:-}"
	[[ -z "$pid" ]] && return 0
	kill -0 "$pid" 2>/dev/null || return 0
	kill -TERM "$pid" 2>/dev/null || true
	sudo -n kill -TERM "$pid" 2>/dev/null || true
	sleep 0.2
	kill -0 "$pid" 2>/dev/null || return 0
	kill -KILL "$pid" 2>/dev/null || true
	sudo -n kill -KILL "$pid" 2>/dev/null || true
}

# 每组测试 = 一次 monitor_off + monitor_on 完成后调用（首组前不等待）
suite_gap_sleep() {
	local label="${1:-}"
	(( SUITE_GAP_SEC > 0 )) || return 0
	echo "  [组间间隔] 等待 ${SUITE_GAP_SEC}s${label:+ — $label}" >&2
	sleep "$SUITE_GAP_SEC"
}

cleanup_all() {
	echo "$ORIG_MONITOR" | sudo tee "$IOPRIO_MON_SYSCTL" >/dev/null || true
}

check_override_peak() {
	local phase="$1" idx="$2" max_file="$3"
	local peak
	[[ -f "$max_file" ]] || {
		echo "ERROR: 缺少 override 统计 $max_file（dense 未写入）" >&2
		return 1
	}
	peak="$(tr -d ' \t\r\n' <"$max_file" 2>/dev/null || echo 0)"
	[[ "$peak" =~ ^[0-9]+$ ]] || peak=0
	echo "    override 峰值: $peak / 期望≈$ACTUAL_PROCS（门槛>=$MIN_OVERRIDE_TARGETS）"
	if (( peak < MIN_OVERRIDE_TARGETS )); then
		echo "ERROR: $phase run=$idx override_targets 峰值=$peak < 门槛=$MIN_OVERRIDE_TARGETS" >&2
		echo "  未对足够 benchmark 进程打上 ioprio_override，本轮 off/on 不可解读。" >&2
		echo "  请检查 dense_override.log；perf 在 sudo 下运行时应由 root 扫描 /proc。" >&2
		return 1
	fi
}

init_phase_dir() {
	local phase="$1" cdir="$OUTDIR/$phase"
	mkdir -p "$cdir/perf_raw" "$cdir/bench_out" "$cdir/override_stats"
	echo -e "run\ttask_clock_ms\tcontext_switches\tavg_cs_ns\tbench_total_sec" >"$cdir/perf_runs.tsv"
}

# 小规模：先 -l1 拉起全进程树并 dense 打标，再跑正式 perf stat
premark_spawn_override() {
	local phase="$1" idx="$2" max_file="$3"
	[[ "$PREMARK_SPAWN" == "1" && "$ACTUAL_PROCS" -lt "$PREMARK_MAX_PROCS" ]] || return 0

	local -a spawn_cmd=()
	build_perf_stat_cmd spawn_cmd "$PERF_PRIV" "$MSG_GROUPS" 1
	local spawn_out="$OUTDIR/.premark_bench.txt"
	local deadline=$((SECONDS + 20)) peak=0

	echo "    [premark] 先 -l1 拉起进程树并打 override（目标>=$MIN_OVERRIDE_TARGETS）" >&2
	(
		local wrap_pid dpid
		"${spawn_cmd[@]}" >"$spawn_out" 2>/dev/null &
		wrap_pid=$!
		DENSE_PY "$wrap_pid" "$DENSE_REAPPLY_SEC" "$DENSE_OVERRIDE_LOG" "$max_file" \
			"$phase" "${idx}_premark" &
		dpid=$!
		trap 'kill_pid_graceful "$wrap_pid"' EXIT
		while (( SECONDS < deadline )); do
			if [[ -f "$max_file" ]]; then
				peak="$(tr -d ' \t\r\n' <"$max_file" 2>/dev/null || echo 0)"
				[[ "$peak" =~ ^[0-9]+$ ]] && (( peak >= MIN_OVERRIDE_TARGETS )) && break
			fi
			sleep 0.05
		done
		kill_pid_graceful "$dpid"
		wait "$dpid" 2>/dev/null || true
		kill_pid_graceful "$wrap_pid"
		wait "$wrap_pid" 2>/dev/null || true
		trap - EXIT
	) || true

	peak="$(tr -d ' \t\r\n' <"$max_file" 2>/dev/null || echo 0)"
	echo "    [premark] override 峰值: ${peak:-0}" >&2
	[[ "$peak" =~ ^[0-9]+$ ]] && (( peak >= MIN_OVERRIDE_TARGETS ))
}

run_one_iteration() {
	local phase="$1" monitor_val="$2" idx="$3"
	local cdir="$OUTDIR/$phase" raw bout tsv bench_rc=0
	raw="$cdir/perf_raw/run_${idx}.txt"
	bout="$cdir/bench_out/run_${idx}.txt"
	tsv="$cdir/perf_runs.tsv"

	echo "$monitor_val" | sudo tee "$IOPRIO_MON_SYSCTL" >/dev/null
	echo "  [run $idx/$RUNS] $phase monitor=$(cat "$IOPRIO_MON_SYSCTL")"
	maybe_refresh_sudo

	local -a cmd=()
	local max_file="$cdir/override_stats/run_${idx}.max"
	premark_spawn_override "$phase" "$idx" "$max_file" || {
		echo "WARN: premark 未达 override 门槛，继续正式 run（可能仍失败）" >&2
	}
	build_perf_stat_cmd cmd "$PERF_PRIV" "$MSG_GROUPS" "$RUNTIME_LOOPS"

	(
		local wrap_pid dpid
		"${cmd[@]}" >"$bout" 2>"$raw" &
		wrap_pid=$!
		DENSE_PY "$wrap_pid" "$DENSE_REAPPLY_SEC" "$DENSE_OVERRIDE_LOG" "$max_file" \
			"$phase" "$idx" &
		dpid=$!
		trap 'kill_pid_graceful "$wrap_pid"' EXIT
		wait "$wrap_pid" || bench_rc=$?
		kill_pid_graceful "$dpid"
		wait "$dpid" 2>/dev/null || true
		trap - EXIT
	) || bench_rc=$?

	if [[ "$bench_rc" != "0" ]]; then
		echo "ERROR: benchmark failed (phase=$phase run=$idx rc=$bench_rc)" >&2
		[[ -s "$raw" ]] && sed -n '1,5p' "$raw" >&2
		return "$bench_rc"
	fi
	check_override_peak "$phase" "$idx" "$max_file" || return 1
	PERF_PY append_run "$raw" "$bout" "$tsv" "$idx"
}

finalize_target_results() {
	{
		echo -e "phase\truns\ttask_clock_ms_mean\tcontext_switches_mean\tavg_cs_ns_mean\tavg_cs_ns_median\tavg_cs_ns_p95\tavg_cs_ns_stddev\tavg_cs_ns_ci95\tbench_total_sec_mean"
		PERF_PY summarize monitor_off "$OUTDIR/monitor_off/perf_runs.tsv"
		PERF_PY summarize monitor_on "$OUTDIR/monitor_on/perf_runs.tsv"
	} | tee "$OUTDIR/summary.tsv"

	PERF_PY delta "$OUTDIR/summary.tsv" | tee "$OUTDIR/delta.txt"
}

run_single_suite() {
	local outdir="$1"
	OUTDIR="$outdir"
	mkdir -p "$OUTDIR"
	DENSE_OVERRIDE_LOG="$OUTDIR/dense_override.log"

	local pid_max
	pid_max="$(cat /proc/sys/kernel/pid_max 2>/dev/null || echo 32768)"
	(( ACTUAL_PROCS <= pid_max )) || {
		echo "ERROR: 实际进程数=$ACTUAL_PROCS 超过 pid_max=$pid_max" >&2
		echo "  可先执行: sudo sysctl -w kernel.pid_max=131072" >&2
		exit 1
	}

	echo ""
	echo ">>> 规模 target_procs=$TARGET_PROCS 实际=$ACTUAL_PROCS groups=$MSG_GROUPS loops=$RUNTIME_LOOPS"
	echo "    override 门槛>=$MIN_OVERRIDE_TARGETS  premark=${PREMARK_SPAWN}(<${PREMARK_MAX_PROCS})  dense=${DENSE_REAPPLY_SEC}s"
	echo "    目录: $OUTDIR"

	: >"$DENSE_OVERRIDE_LOG"
	for phase in monitor_off monitor_on; do init_phase_dir "$phase"; done

	for ((i = 1; i <= RUNS; i++)); do
		run_one_iteration monitor_off 0 "$i" || return 1
		suite_gap_sleep "target_${TARGET_PROCS} rep ${i}/${RUNS}: monitor_off → monitor_on"
		run_one_iteration monitor_on 1 "$i" || return 1
		(( i < RUNS )) && suite_gap_sleep "target_${TARGET_PROCS} rep ${i}/${RUNS} 完成"
	done

	finalize_target_results

	pipe_note="(socketpair)"
	[[ "$USE_PIPE" == "1" ]] && pipe_note="-p(pipe)"

	cat >"$OUTDIR/README.txt" <<EOF
大量进程 CS 开销实验

进程: target=$TARGET_PROCS actual=$ACTUAL_PROCS groups=$MSG_GROUPS loops=$RUNTIME_LOOPS $pipe_note
override 间隔 ${DENSE_REAPPLY_MS}ms，门槛>=$MIN_OVERRIDE_TARGETS

指标: avg_cs_ns = task_clock_ms * 1e6 / context_switches
产物: summary.tsv, delta.txt, monitor_*/perf_runs.tsv
EOF
}

init_target_dirs() {
	local tdir="$1"
	OUTDIR="$tdir"
	mkdir -p "$OUTDIR"
	DENSE_OVERRIDE_LOG="$OUTDIR/dense_override.log"
	: >"$DENSE_OVERRIDE_LOG"
	for phase in monitor_off monitor_on; do init_phase_dir "$phase"; done
}

init_environment() {
	[[ -f "$IOPRIO_MON_SYSCTL" ]] || {
		echo "ERROR: $IOPRIO_MON_SYSCTL 不存在" >&2
		exit 1
	}
	command -v perf >/dev/null 2>&1 || {
		echo "ERROR: 无 perf" >&2
		exit 1
	}
	[[ -x "$ROOT/ioprio_override" ]] || {
		echo "ERROR: 缺少 $ROOT/ioprio_override" >&2
		exit 1
	}
	PERF_BIN="$(command -v perf)"
	ORIG_MONITOR="$(cat "$IOPRIO_MON_SYSCTL" 2>/dev/null || echo 1)"
	trap cleanup_all EXIT
	sudo -v
	ensure_perf_privileges
}

main_single() {
	local ts="$1"
	set_target_procs "$TARGET_PROCS"
	init_environment
	echo "=== 模式: 单次 ==="
	echo "perf: $PERF_PRIV  RUNS=$RUNS  CPU_SET=${CPU_SET:-none}"
	run_single_suite "$ROOT/results_cs_manyproc_overhead_${ts}"
	echo "完成: $OUTDIR"
	cat "$OUTDIR/delta.txt"
}

main_sweep() {
	local ts="$1" sweep_dir="$2"
	local -a targets=()
	local tp tdir cycle
	while IFS= read -r t; do
		targets+=("$t")
	done < <(parse_sweep_list "$PROC_SWEEP")

	(( ${#targets[@]} > 0 )) || {
		echo "ERROR: PROC_SWEEP 为空" >&2
		exit 1
	}

	init_environment
	mkdir -p "$sweep_dir/by_target"
	: >"$sweep_dir/execution_order.log"

	echo "=== 模式: 规模扫描 ==="
	echo "PROC_SWEEP=${targets[*]}  RUNS=$RUNS  LOOPS=$LOOPS  SWEEP_INTERLEAVE=$SWEEP_INTERLEAVE  SUITE_GAP_SEC=$SUITE_GAP_SEC"
	echo "输出: $sweep_dir"

	if [[ "$SWEEP_INTERLEAVE" == "1" ]]; then
		echo "执行顺序: 重复 $RUNS 个周期，每周期依次 ${targets[*]}（各 1 次 off+on）" >&2
		for tp in "${targets[@]}"; do
			TARGET_PROCS="$tp"
			set_target_procs "$tp"
			tdir="$sweep_dir/by_target/target_${tp}"
			mkdir -p "$tdir"
			echo "$TARGET_PROCS" >"$tdir/target_procs.txt"
			echo "$ACTUAL_PROCS" >"$tdir/actual_procs.txt"
			init_target_dirs "$tdir"
		done
		_sweep_gap_prev=""
		for ((cycle = 1; cycle <= RUNS; cycle++)); do
			echo ""
			echo "=== 交错周期 $cycle/$RUNS: ${targets[*]} ==="
			for tp in "${targets[@]}"; do
				[[ -n "$_sweep_gap_prev" ]] && suite_gap_sleep "$_sweep_gap_prev"
				TARGET_PROCS="$tp"
				set_target_procs "$tp"
				tdir="$sweep_dir/by_target/target_${tp}"
				OUTDIR="$tdir"
				DENSE_OVERRIDE_LOG="$OUTDIR/dense_override.log"
				echo ""
				echo ">>> [周期 $cycle/$RUNS] target_procs=$tp 实际=$ACTUAL_PROCS loops=$RUNTIME_LOOPS"
				{
					echo -e "cycle\ttarget_procs\tactual_procs\tphase\tidx"
					echo -e "${cycle}\t${tp}\t${ACTUAL_PROCS}\tmonitor_off\t${cycle}"
				} >>"$sweep_dir/execution_order.log"
				run_one_iteration monitor_off 0 "$cycle" || exit 1
				suite_gap_sleep "周期 ${cycle}/${RUNS} target_${tp}: monitor_off → monitor_on"
				echo -e "${cycle}\t${tp}\t${ACTUAL_PROCS}\tmonitor_on\t${cycle}" >>"$sweep_dir/execution_order.log"
				run_one_iteration monitor_on 1 "$cycle" || exit 1
				_sweep_gap_prev="周期 ${cycle}/${RUNS} target_${tp} 完成"
			done
		done
		for tp in "${targets[@]}"; do
			tdir="$sweep_dir/by_target/target_${tp}"
			OUTDIR="$tdir"
			TARGET_PROCS="$tp"
			set_target_procs "$tp"
			finalize_target_results
		done
	else
		echo "执行顺序: 按规模分块（先跑完一档的全部 $RUNS 次）" >&2
		_sweep_gap_prev=""
		for tp in "${targets[@]}"; do
			[[ -n "$_sweep_gap_prev" ]] && suite_gap_sleep "$_sweep_gap_prev"
			TARGET_PROCS="$tp"
			set_target_procs "$tp"
			tdir="$sweep_dir/by_target/target_${tp}"
			mkdir -p "$tdir"
			echo "$TARGET_PROCS" >"$tdir/target_procs.txt"
			echo "$ACTUAL_PROCS" >"$tdir/actual_procs.txt"
			run_single_suite "$tdir" || exit 1
			_sweep_gap_prev="target_${tp} 全部 ${RUNS} 轮完成"
		done
	fi

	PERF_PY sweep_aggregate "$sweep_dir"
	echo ""
	echo "完成规模扫描: $sweep_dir"
	echo "--- sweep_summary.tsv ---"
	column -t "$sweep_dir/sweep_summary.tsv" 2>/dev/null || cat "$sweep_dir/sweep_summary.tsv"

	cat >"$sweep_dir/README.txt" <<EOF
多规模 CS 开销扫描

PROC_SWEEP=$PROC_SWEEP
RUNS=$RUNS LOOPS=$LOOPS  SWEEP_INTERLEAVE=$SWEEP_INTERLEAVE

交错模式: 每周期 2000→10000→50000→100000 各 1 次 off/on，共 RUNS 周期
execution_order.log 记录实际顺序

每档: by_target/target_<N>/{summary.tsv,delta.txt,...}
汇总: sweep_summary.tsv, plot_sweep.csv

运行: sudo ./exp_cs_monitor_overhead_manyproc.sh
（脚本内 RUN_MODE=sweep）
EOF
}

case "$RUN_MODE" in
single)
	TS="$(date +%Y%m%d_%H%M%S)"
	main_single "$TS"
	;;
sweep)
	TS="$(date +%Y%m%d_%H%M%S)"
	main_sweep "$TS" "$ROOT/results_cs_manyproc_sweep_${TS}"
	;;
*)
	echo "ERROR: 未知 RUN_MODE=$RUN_MODE（应为 single|sweep）" >&2
	exit 1
	;;
esac
