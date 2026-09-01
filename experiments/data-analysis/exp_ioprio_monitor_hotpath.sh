#!/bin/bash
#
# CPU 监控热路径 ioprio_ov_cpu_work_fn（ftrace + dense ioprio_override + messaging）
#
# 用法（参数见下方「实验配置」）:
#   sudo -v
#   sudo ./exp_ioprio_monitor_hotpath.sh
#
# 产物:
#   sweep: results_ioprio_hotpath_sweep_<ts>/{sweep_summary.tsv,plot_sweep.csv,...}
#   single: results_ioprio_hotpath_<ts>/{monitor_off,monitor_on,...}

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
IOPRIO_MON_SYSCTL="/proc/sys/kernel/ioprio_override_cpu_monitor"
TRACE_DIR="/sys/kernel/tracing"
FTRACE_FUNC="ioprio_ov_cpu_work_fn"

# =============================================================================
# 实验配置（改这里即可；环境变量仍可临时覆盖）
# =============================================================================
# RUN_MODE:
#   sweep  — 多规模扫描（论文作图，默认）
#   single — 只跑 TARGET_PROCS 一档
#   repair — 只修复已有 sweep 的 override_peak / 汇总表（填 REPAIR_SWEEP_DIR）
_cfg_RUN_MODE=sweep
_cfg_TARGET_PROCS=100000
_cfg_PROC_SWEEP="10000,20000,40000,60000,80000,100000"
_cfg_SWEEP_REPS=3
_cfg_LOOPS=20
# 不绑核: 留空或 none；绑核示例: 0-15
_cfg_CPU_SET=
_cfg_USE_PIPE=1
_cfg_DENSE_REAPPLY_MS=50
_cfg_FTRACE_GRAPH=1
_cfg_MIN_TRACE_SEC=3
_cfg_AUTO_SCALE_LOOPS=1
_cfg_SWEEP_REF_PROCS=100000
_cfg_MAX_LOOPS=3000
_cfg_MIN_FN_CALLS_ON=15
_cfg_SWEEP_STRICT=0
_cfg_PERF_RECORD_CYCLES=0
_cfg_REPAIR_SWEEP_DIR=""   # repair 模式: 如 results_ioprio_hotpath_sweep_20260528_130145
_cfg_SWEEP_INTERLEAVE=1    # 1=每轮按进程数列表交错；0=一档跑完 SWEEP_REPS 再换下一档
_cfg_SUITE_GAP_SEC=3       # off→on 与每组（off+on）结束后等待秒数；0=不等待

RUN_MODE="${RUN_MODE:-${_cfg_RUN_MODE}}"
TARGET_PROCS="${TARGET_PROCS:-${_cfg_TARGET_PROCS}}"
PROC_SWEEP="${PROC_SWEEP:-${_cfg_PROC_SWEEP}}"
SWEEP_REPS="${SWEEP_REPS:-${_cfg_SWEEP_REPS}}"
LOOPS="${LOOPS:-${_cfg_LOOPS}}"
# 空/none 表示不 taskset；去掉首尾空白，避免 taskset -c " " 误失败
CPU_SET="${CPU_SET:-${_cfg_CPU_SET:-}}"
CPU_SET="${CPU_SET#"${CPU_SET%%[![:space:]]*}"}"
CPU_SET="${CPU_SET%"${CPU_SET##*[![:space:]]}"}"
[[ "$CPU_SET" == "none" ]] && CPU_SET=""
USE_PIPE="${USE_PIPE:-${_cfg_USE_PIPE}}"
DENSE_REAPPLY_MS="${DENSE_REAPPLY_MS:-${_cfg_DENSE_REAPPLY_MS}}"
FTRACE_GRAPH="${FTRACE_GRAPH:-${_cfg_FTRACE_GRAPH}}"
MIN_TRACE_SEC="${MIN_TRACE_SEC:-${_cfg_MIN_TRACE_SEC}}"
AUTO_SCALE_LOOPS="${AUTO_SCALE_LOOPS:-${_cfg_AUTO_SCALE_LOOPS}}"
SWEEP_REF_PROCS="${SWEEP_REF_PROCS:-${_cfg_SWEEP_REF_PROCS}}"
MAX_LOOPS="${MAX_LOOPS:-${_cfg_MAX_LOOPS}}"
MIN_FN_CALLS_ON="${MIN_FN_CALLS_ON:-${_cfg_MIN_FN_CALLS_ON}}"
SWEEP_STRICT="${SWEEP_STRICT:-${_cfg_SWEEP_STRICT}}"
PERF_RECORD_CYCLES="${PERF_RECORD_CYCLES:-${_cfg_PERF_RECORD_CYCLES}}"
REPAIR_SWEEP_DIR="${REPAIR_SWEEP_DIR:-${_cfg_REPAIR_SWEEP_DIR}}"
SWEEP_INTERLEAVE="${SWEEP_INTERLEAVE:-${_cfg_SWEEP_INTERLEAVE}}"
SUITE_GAP_SEC="${SUITE_GAP_SEC:-${_cfg_SUITE_GAP_SEC}}"

: "${MIN_OVERRIDE_RATIO_PCT:=10}"
: "${MIN_OVERRIDE_FLOOR:=500}"
: "${MIN_OVERRIDE_BIG_FLOOR:=5000}"

PROCS_PER_GROUP=40
ORIG_MONITOR=""
PERF_BIN=""
PERF_RUN=()
PERF_PRIV="sudo"

# 由 set_target_procs <n> 更新
MSG_GROUPS=0
ACTUAL_PROCS=0
RUNTIME_LOOPS=0
DENSE_REAPPLY_SEC=""
MIN_OVERRIDE_TARGETS=0

set_target_procs() {
	local n="$1"
	MSG_GROUPS=$(( (n + PROCS_PER_GROUP - 1) / PROCS_PER_GROUP ))
	ACTUAL_PROCS=$(( MSG_GROUPS * PROCS_PER_GROUP ))

	# override 门槛：10%×N；大规模仍要求>=5000；小规模用 MIN_OVERRIDE_FLOOR
	MIN_OVERRIDE_TARGETS=$(( ACTUAL_PROCS * MIN_OVERRIDE_RATIO_PCT / 100 ))
	if (( ACTUAL_PROCS >= MIN_OVERRIDE_BIG_FLOOR )); then
		(( MIN_OVERRIDE_TARGETS >= MIN_OVERRIDE_BIG_FLOOR )) || MIN_OVERRIDE_TARGETS=$MIN_OVERRIDE_BIG_FLOOR
	else
		(( MIN_OVERRIDE_TARGETS >= MIN_OVERRIDE_FLOOR )) || MIN_OVERRIDE_TARGETS=$MIN_OVERRIDE_FLOOR
	fi
	(( MIN_OVERRIDE_TARGETS > ACTUAL_PROCS )) && MIN_OVERRIDE_TARGETS=$ACTUAL_PROCS

	# 小规模 benchmark 极短 → 按 REF/ACTUAL 放大 LOOPS，便于采到多次 delayed work
	RUNTIME_LOOPS=$LOOPS
	if [[ "$AUTO_SCALE_LOOPS" == "1" && "$ACTUAL_PROCS" -lt "$SWEEP_REF_PROCS" ]]; then
		RUNTIME_LOOPS=$(( LOOPS * (SWEEP_REF_PROCS + ACTUAL_PROCS - 1) / ACTUAL_PROCS ))
		(( RUNTIME_LOOPS > MAX_LOOPS )) && RUNTIME_LOOPS=$MAX_LOOPS
		(( RUNTIME_LOOPS < LOOPS )) && RUNTIME_LOOPS=$LOOPS
	fi

	# 进程少时加快 dense 扫描（ms）
	local dense_ms=$DENSE_REAPPLY_MS
	if (( ACTUAL_PROCS < 20000 )); then
		dense_ms=20
	elif (( ACTUAL_PROCS < 50000 )); then
		dense_ms=30
	fi
	DENSE_REAPPLY_SEC="$(awk -v ms="$dense_ms" 'BEGIN { printf "%.3f", ms / 1000 }')"
}

# --- 与 manyproc 相同的 dense / perf 探测（精简）---
DENSE_PY() {
	local -a runner=(python3 - "$@")
	[[ "$PERF_PRIV" == "sudo" ]] && runner=(sudo -n env LC_ALL=C python3 - "$@")
	"${runner[@]}" <<'PY'
import ctypes, os, sys, time
from collections import defaultdict
from datetime import datetime, timezone

root_pid, interval, log_path, max_path, phase, run_id = (
    int(sys.argv[1]), float(sys.argv[2]), sys.argv[3], sys.argv[4], sys.argv[5], sys.argv[6])
libc = ctypes.CDLL(None, use_errno=True)
syscall_fn = libc.syscall
syscall_fn.argtypes = [ctypes.c_long, ctypes.c_long]
syscall_fn.restype = ctypes.c_long
NR = 468

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
            pass
    return ppid

def list_descendants(root):
    ppid = read_ppid_map()
    children = defaultdict(list)
    for pid, parent in ppid.items():
        children[parent].append(pid)
    out, queue = [], list(children.get(root, ()))
    while queue:
        p = queue.pop()
        out.append(p)
        queue.extend(children.get(p, ()))
    return out

def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False

peak = 0
while alive(root_pid):
    targets = list_descendants(root_pid)
    applied = sum(1 for p in targets if syscall_fn(NR, p) == 0)
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

read_override_peak() {
	local max_file="$1" log_file="$2" phase="$3" run_tag="$4"
	local peak="" i
	for i in 1 2 3 4 5 6 7 8 9 10; do
		if [[ -f "$max_file" ]]; then
			peak="$(tr -d ' \t\r\n' <"$max_file" 2>/dev/null || true)"
		fi
		[[ "$peak" =~ ^[0-9]+$ ]] && {
			echo "$peak"
			return 0
		}
		sleep 0.05
	done
	if [[ -f "$log_file" ]]; then
		peak="$(python3 - "$log_file" "$phase" "$run_tag" <<'PY'
import re, sys
log, phase, run_tag = sys.argv[1:4]
peak = 0
pat = re.compile(r"override_targets=(\d+)")
for line in open(log, encoding="utf-8", errors="ignore"):
    if f"phase={phase}" not in line or f"run={run_tag}" not in line:
        continue
    m = pat.search(line)
    if m:
        peak = max(peak, int(m.group(1)))
print(peak)
PY
)"
	fi
	[[ "$peak" =~ ^[0-9]+$ ]] || peak=0
	echo "$peak"
}

parse_ftrace() {
	python3 - "$1" "$2" "$FTRACE_FUNC" <<'PY'
import re, statistics, sys

path, graph_mode, func = sys.argv[1], int(sys.argv[2]), sys.argv[3]
lines = open(path, "r", encoding="utf-8", errors="ignore").read().splitlines()

durations_us = []
graph_done = re.compile(
    rf"^\s*\d+\)\s+[!#*]?\s*([0-9.]+)\s+us\s+\|.*{re.escape(func)}\(\);\s*$"
)
flat_hit = re.compile(rf"{re.escape(func)}\s+<")

for ln in lines:
    if graph_mode:
        m = graph_done.search(ln)
        if m:
            durations_us.append(float(m.group(1)))

if graph_mode:
    call_count = len(durations_us)
else:
    call_count = sum(1 for ln in lines if flat_hit.search(ln))

out = path + ".parsed.txt"
with open(out, "w", encoding="utf-8") as f:
    f.write(f"call_count\t{call_count}\n")
    if durations_us:
        f.write(f"work_samples\t{len(durations_us)}\n")
        f.write(f"work_us_sum\t{sum(durations_us):.3f}\n")
        f.write(f"work_us_mean\t{statistics.mean(durations_us):.3f}\n")
        f.write(f"work_us_median\t{statistics.median(durations_us):.3f}\n")
        f.write(f"work_us_max\t{max(durations_us):.3f}\n")
        f.write(f"work_total_ms\t{sum(durations_us)/1000:.3f}\n")
    f.write(f"trace_lines\t{len(lines)}\n")

# stdout: call_count, mean_us, max_us, total_ms, median_us (供 bash mapfile)
print(call_count)
if durations_us:
    print(statistics.mean(durations_us))
    print(max(durations_us))
    print(sum(durations_us) / 1000.0)
    print(statistics.median(durations_us))
else:
    print("nan")
    print("nan")
    print("nan")
    print("nan")
PY
}

ftrace_check() {
	[[ -d "$TRACE_DIR" ]] || {
		echo "ERROR: $TRACE_DIR 不存在，请确认 CONFIG_FTRACE=y" >&2
		exit 1
	}
	[[ -w "$TRACE_DIR/tracing_on" ]] || {
		echo "ERROR: 无法写 $TRACE_DIR，请用 sudo 运行" >&2
		exit 1
	}
}

ftrace_begin() {
	local trace_file="$1"
	echo 0 | sudo tee "$TRACE_DIR/tracing_on" >/dev/null
	echo nop | sudo tee "$TRACE_DIR/current_tracer" >/dev/null
	echo | sudo tee "$TRACE_DIR/trace" >/dev/null
	echo "$FTRACE_FUNC" | sudo tee "$TRACE_DIR/set_ftrace_filter" >/dev/null
	if [[ "$FTRACE_GRAPH" == "1" ]]; then
		echo "$FTRACE_FUNC" | sudo tee "$TRACE_DIR/set_graph_function" >/dev/null
		echo function_graph | sudo tee "$TRACE_DIR/current_tracer" >/dev/null
	else
		echo function | sudo tee "$TRACE_DIR/current_tracer" >/dev/null
	fi
	echo 1 | sudo tee "$TRACE_DIR/tracing_on" >/dev/null
	: >"$trace_file"
}

ftrace_end() {
	local trace_file="$1"
	echo 0 | sudo tee "$TRACE_DIR/tracing_on" >/dev/null
	sudo cp "$TRACE_DIR/trace" "$trace_file"
	echo nop | sudo tee "$TRACE_DIR/current_tracer" >/dev/null
}

append_taskset() {
	local -n _d="$1"
	[[ -n "${CPU_SET:-}" ]] || return 0
	_d+=(taskset -c "$CPU_SET")
}

build_bench_cmd() {
	local -n _c="$1"
	local -a bench=(bench sched messaging -g "$MSG_GROUPS" -l "$RUNTIME_LOOPS")
	[[ "$USE_PIPE" == "1" ]] && bench+=(-p)
	_c=("${PERF_RUN[@]}")
	append_taskset _c
	_c+=("$PERF_BIN" "${bench[@]}")
}

kill_pid_graceful() {
	local pid="${1:-}"
	[[ -z "$pid" ]] && return 0
	kill -TERM "$pid" 2>/dev/null || true
	sudo -n kill -TERM "$pid" 2>/dev/null || true
	sleep 0.2
	kill -KILL "$pid" 2>/dev/null || true
	sudo -n kill -KILL "$pid" 2>/dev/null || true
}

cleanup_all() {
	echo "$ORIG_MONITOR" | sudo tee "$IOPRIO_MON_SYSCTL" >/dev/null || true
	echo 0 | sudo tee "$TRACE_DIR/tracing_on" >/dev/null 2>&1 || true
}

# 每组 = monitor_off + monitor_on；首组前不等待
suite_gap_sleep() {
	local label="${1:-}"
	(( SUITE_GAP_SEC > 0 )) || return 0
	echo "  [组间间隔] 等待 ${SUITE_GAP_SEC}s${label:+ — $label}" >&2
	sleep "$SUITE_GAP_SEC"
}

run_phase() {
	local phase="$1" monitor_val="$2" run_outdir="$3" run_tag="$4"
	local pdir="$run_outdir/$phase"
	local trace="$pdir/ftrace.trace"
	local bench_out="$pdir/bench_out.txt"
	local max_file="$pdir/override_peak.max"
	local perf_data="$pdir/perf.data"
	mkdir -p "$pdir"

	echo "=== $phase (monitor=$monitor_val) [$run_tag] ==="
	echo "$monitor_val" | sudo tee "$IOPRIO_MON_SYSCTL" >/dev/null
	sudo -v -n 2>/dev/null || sudo -v

	local -a bench_cmd=()
	build_bench_cmd bench_cmd
	if [[ -n "${CPU_SET:-}" ]]; then
		echo "  perf: taskset -c $CPU_SET (${#bench_cmd[@]} 项命令)" >&2
	else
		echo "  perf: 未绑核，全 CPU 调度（10k+ 进程 fork 阶段可能 1–3 分钟无新输出，属正常）" >&2
	fi

	ftrace_begin "$trace"
	local wrap_pid dpid bench_rc=0 perf_pid=""
	if [[ "$PERF_RECORD_CYCLES" == "1" ]]; then
		sudo -n "$PERF_BIN" record -e cycles:k -a -o "$perf_data" -- sleep 3600 &
		perf_pid=$!
	fi
	local dense_log="$run_outdir/dense_override.log"
	(
		local phase_start=$SECONDS hold_remain=0
		"${bench_cmd[@]}" >"$bench_out" 2>&1 &
		wrap_pid=$!
		DENSE_PY "$wrap_pid" "$DENSE_REAPPLY_SEC" "$dense_log" "$max_file" \
			"$phase" "$run_tag" &
		dpid=$!
		trap 'kill_pid_graceful "$wrap_pid"' EXIT
		wait "$wrap_pid" || bench_rc=$?
		hold_remain=$(( MIN_TRACE_SEC - (SECONDS - phase_start) ))
		if (( hold_remain > 0 )); then
			echo "  观测窗口延长 ${hold_remain}s（benchmark 已结束，ftrace 继续采 delayed work）" >&2
			sleep "$hold_remain"
		fi
		kill_pid_graceful "$dpid"
		wait "$dpid" 2>/dev/null || true
		trap - EXIT
	) || bench_rc=$?

	if [[ -n "$perf_pid" ]]; then
		kill_pid_graceful "$perf_pid"
		wait "$perf_pid" 2>/dev/null || true
	fi
	ftrace_end "$trace"

	local peak override_ok=1 valid_note=""
	peak="$(read_override_peak "$max_file" "$dense_log" "$phase" "$run_tag")"
	echo "  override 峰值: $peak (门槛>=$MIN_OVERRIDE_TARGETS)"
	if [[ ! "$peak" =~ ^[0-9]+$ ]] || (( peak < MIN_OVERRIDE_TARGETS )); then
		valid_note+=" override未达标"
		override_ok=0
	fi

	local -a parsed
	mapfile -t parsed < <(parse_ftrace "$trace" "$FTRACE_GRAPH")
	local fn_calls="${parsed[0]:-0}"
	local work_us_mean="${parsed[1]:-nan}"
	local work_us_max="${parsed[2]:-nan}"
	local work_total_ms="${parsed[3]:-nan}"
	local work_us_median="${parsed[4]:-nan}"

	local bench_sec="nan"
	if [[ -f "$bench_out" ]] && grep -q 'Total time:' "$bench_out"; then
		bench_sec="$(sed -n 's/.*Total time:[[:space:]]*\([0-9.]*\).*/\1/p' "$bench_out" | head -1)"
	elif [[ -f "$bench_out" ]] && [[ -s "$bench_out" ]]; then
		echo "  WARN: benchmark 未正常结束，见 $bench_out" >&2
	fi

	if [[ "$phase" == "monitor_on" ]]; then
		if [[ "$fn_calls" =~ ^[0-9]+$ ]] && (( fn_calls < MIN_FN_CALLS_ON )); then
			valid_note+=" work调用${fn_calls}<${MIN_FN_CALLS_ON}"
			override_ok=0
		fi
		if [[ "$FTRACE_GRAPH" == "1" && "$work_us_mean" != "nan" ]] \
			&& awk -v w="$work_us_mean" 'BEGIN { exit !(w < 100) }'; then
			valid_note+=" 单次work<100us(链过短?)"
			override_ok=0
		fi
	fi
	if [[ -n "$valid_note" ]]; then
		echo "  WARN:${valid_note}" >&2
		if [[ "$SWEEP_STRICT" == "1" ]]; then
			echo "ERROR: SWEEP_STRICT=1，本轮回废" >&2
			exit 1
		fi
	fi

	echo "$phase" >"$pdir/phase.txt"
	{
		echo -e "phase\tmonitor\ttarget_procs\tactual_procs\truntime_loops\toverride_peak\toverride_ok\tfn_calls\twork_us_mean\twork_us_median\twork_us_max\twork_total_ms\tbench_sec"
		echo -e "$phase\t$monitor_val\t$TARGET_PROCS\t$ACTUAL_PROCS\t$RUNTIME_LOOPS\t$peak\t$override_ok\t$fn_calls\t$work_us_mean\t$work_us_median\t$work_us_max\t$work_total_ms\t$bench_sec"
	} >"$pdir/metrics.tsv"

	echo "  ftrace: ${FTRACE_FUNC} 完成次数≈$fn_calls"
	if [[ "$FTRACE_GRAPH" == "1" && "$fn_calls" != "0" ]]; then
		echo "  function_graph: 单次 work 平均≈${work_us_mean} us, 中位≈${work_us_median} us, 最大≈${work_us_max} us, 合计≈${work_total_ms} ms"
	fi
	[[ "$bench_sec" != "nan" ]] && echo "  benchmark 墙钟: ${bench_sec}s"
}

write_run_summary() {
	local run_outdir="$1"
	local OFF="$run_outdir/monitor_off/metrics.tsv"
	local ON="$run_outdir/monitor_on/metrics.tsv"
	{
		echo -e "metric\tmonitor_off\tmonitor_on\tdelta_on_minus_off"
		python3 - "$OFF" "$ON" <<'PY'
import sys

def read(path):
    d = {}
    with open(path, encoding="utf-8") as f:
        hdr = f.readline().strip().split("\t")
        row = f.readline().strip().split("\t")
        for k, v in zip(hdr, row):
            d[k] = v
    return d

off, on = read(sys.argv[1]), read(sys.argv[2])
keys = [
    "fn_calls", "work_us_mean", "work_us_median", "work_us_max",
    "work_total_ms", "bench_sec", "override_peak",
]
for k in keys:
    a, b = off.get(k, ""), on.get(k, "")
    try:
        da, db = float(a), float(b)
        print(f"{k}\t{a}\t{b}\t{db - da:+.6f}")
    except ValueError:
        print(f"{k}\t{a}\t{b}\t")
PY
	} >"$run_outdir/summary.tsv"

	python3 - "$run_outdir/summary.tsv" >"$run_outdir/delta.txt" <<'PY'
import sys

rows = {}
with open(sys.argv[1], encoding="utf-8") as f:
    next(f)
    for line in f:
        c = line.strip().split("\t")
        if len(c) >= 4:
            rows[c[0]] = c[1:]

print("CPU 监控热路径 (ioprio_ov_cpu_work_fn) 对照")
print("=" * 50)
for k, (off, on, delta) in rows.items():
    print(f"{k}: off={off}  on={on}  Δ(on-off)={delta}")

fn = rows.get("fn_calls", ["", "", ""])
if fn[0] and fn[1]:
    try:
        o, n = int(float(fn[0])), int(float(fn[1]))
        if o == 0 and n > 0:
            print("\n结论: monitor_off 几乎未进入监控 work；monitor_on 有稳定调用 — 符合设计。")
        elif n > o:
            print(f"\n结论: monitor_on 比 off 多约 {n - o} 次 work 调用。")
    except ValueError:
        pass

wm = rows.get("work_us_mean", ["", "", ""])
wt = rows.get("work_total_ms", ["", "", ""])
try:
    if wm[2] not in ("", "nan") and float(wm[2]) > 0:
        print(f"monitor_on 单次 work 平均耗时增加约 {wm[2]} us。")
    if wt[2] not in ("", "nan") and float(wt[2]) > 0:
        print(f"monitor_on 周期 work CPU 合计增加约 {wt[2]} ms（function_graph 各次之和）。")
except ValueError:
    pass
PY
}

run_single_suite() {
	local run_outdir="$1" run_tag="$2"
	mkdir -p "$run_outdir"
	: >"$run_outdir/dense_override.log"

	echo ""
	echo ">>> 运行套件: $run_tag"
	echo "    目录: $run_outdir"
	echo "    目标进程≈$TARGET_PROCS 实际=$ACTUAL_PROCS groups=$MSG_GROUPS loops=$RUNTIME_LOOPS (base=$LOOPS) dense=${DENSE_REAPPLY_SEC}s SUITE_GAP_SEC=$SUITE_GAP_SEC"

	run_phase monitor_off 0 "$run_outdir" "$run_tag"
	suite_gap_sleep "$run_tag: monitor_off → monitor_on"
	run_phase monitor_on 1 "$run_outdir" "$run_tag"
	write_run_summary "$run_outdir"
}

init_environment() {
	[[ -f "$IOPRIO_MON_SYSCTL" ]] || { echo "ERROR: 无 $IOPRIO_MON_SYSCTL" >&2; exit 1; }
	command -v perf >/dev/null 2>&1 || { echo "ERROR: 无 perf" >&2; exit 1; }
	[[ -x "$ROOT/ioprio_override" ]] || {
		echo "ERROR: 编译 ioprio_override: gcc -O2 -o $ROOT/ioprio_override $ROOT/ioprio_override.c" >&2
		exit 1
	}
	ftrace_check
	PERF_BIN="$(command -v perf)"
	PERF_RUN=(sudo -n env LC_ALL=C)
	PERF_PRIV="sudo"
	ORIG_MONITOR="$(cat "$IOPRIO_MON_SYSCTL" 2>/dev/null || echo 1)"
	trap cleanup_all EXIT
	sudo -v
	sudo -n true
}

parse_sweep_list() {
	# 输出规范化后的 TARGET 列表（每行一个）
	local raw="${1//,/ }"
	local t
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

aggregate_sweep() {
	local sweep_dir="$1" points_tsv="$2"
	python3 - "$sweep_dir" "$points_tsv" <<'PY'
import math
import statistics
import sys
from pathlib import Path

sweep_dir = Path(sys.argv[1])
points_path = Path(sys.argv[2])

rows = []
with points_path.open(encoding="utf-8") as f:
    hdr = f.readline().strip().split("\t")
    for line in f:
        if not line.strip():
            continue
        vals = line.strip().split("\t")
        rows.append(dict(zip(hdr, vals)))

def fvals(key):
    out = []
    for r in rows:
        try:
            v = float(r[key])
            if math.isfinite(v):
                out.append(v)
        except (KeyError, ValueError):
            pass
    return out

def ci95(vals):
    n = len(vals)
    if n == 0:
        return (float("nan"),) * 3
    if n == 1:
        return vals[0], vals[0], vals[0]
    m = statistics.mean(vals)
    if n >= 2:
        sd = statistics.stdev(vals)
        half = 1.96 * sd / math.sqrt(n)
        return m, m - half, m + half
    return m, m, m

# 按 target_procs 分组（仅 monitor_on 且 override_ok=1 优先，否则全用）
from collections import defaultdict

groups = defaultdict(list)
for r in rows:
    if r.get("phase") != "monitor_on":
        continue
    try:
        tp = int(float(r["target_procs"]))
    except ValueError:
        continue
    groups[tp].append(r)

summary_path = sweep_dir / "sweep_summary.tsv"
plot_path = sweep_dir / "plot_sweep.csv"

summary_hdr = [
    "target_procs", "actual_procs", "reps",
    "override_peak_mean", "override_peak_median",
    "work_ms_mean", "work_ms_mean_ci95_low", "work_ms_mean_ci95_high",
    "work_us_median_across_reps", "work_us_max_across_reps",
    "work_total_ms_mean", "work_total_ms_mean_ci95_low", "work_total_ms_mean_ci95_high",
    "fn_calls_mean", "fn_calls_median", "bench_sec_on_mean",
]
plot_hdr = [
    "target_procs", "actual_procs", "reps",
    "work_ms_mean", "work_ms_mean_ci95_low", "work_ms_mean_ci95_high",
    "work_total_ms_mean", "work_total_ms_mean_ci95_low", "work_total_ms_mean_ci95_high",
    "override_peak_mean", "fn_calls_mean",
]

with summary_path.open("w", encoding="utf-8") as sf, plot_path.open("w", encoding="utf-8") as pf:
    sf.write("\t".join(summary_hdr) + "\n")
    pf.write(",".join(plot_hdr) + "\n")
    for tp in sorted(groups):
        rs = groups[tp]
        ok_rows = [r for r in rs if r.get("override_ok") == "1"]
        use = ok_rows if ok_rows else rs
        actual = int(float(use[0].get("actual_procs", tp)))
        mean_ms = [float(r["work_us_mean"]) / 1000.0 for r in use if r.get("work_us_mean") not in ("", "nan")]
        med_ms = [float(r["work_us_median"]) / 1000.0 for r in use if r.get("work_us_median") not in ("", "nan")]
        max_ms = [float(r["work_us_max"]) / 1000.0 for r in use if r.get("work_us_max") not in ("", "nan")]
        tot = [float(r["work_total_ms"]) for r in use if r.get("work_total_ms") not in ("", "nan")]
        calls = [float(r["fn_calls"]) for r in use if r.get("fn_calls") not in ("", "nan")]
        peaks = [float(r["override_peak"]) for r in use if r.get("override_peak") not in ("", "nan")]
        bench = [float(r["bench_sec"]) for r in use if r.get("bench_sec") not in ("", "nan")]

        m_mean, c_lo, c_hi = ci95(mean_ms)
        m_tot, t_lo, t_hi = ci95(tot)

        def med(v):
            return statistics.median(v) if v else float("nan")

        def mean(v):
            return statistics.mean(v) if v else float("nan")

        line = [
            str(tp), str(actual), str(len(use)),
            f"{mean(peaks):.0f}" if peaks else "nan",
            f"{med(peaks):.0f}" if peaks else "nan",
            f"{m_mean:.6f}", f"{c_lo:.6f}", f"{c_hi:.6f}",
            f"{med(med_ms):.6f}", f"{med(max_ms):.6f}",
            f"{m_tot:.3f}", f"{t_lo:.3f}", f"{t_hi:.3f}",
            f"{mean(calls):.0f}" if calls else "nan",
            f"{med(calls):.0f}" if calls else "nan",
            f"{mean(bench):.3f}" if bench else "nan",
        ]
        sf.write("\t".join(line) + "\n")
        pf.write(",".join([
            str(tp), str(actual), str(len(use)),
            f"{m_mean:.6f}", f"{c_lo:.6f}", f"{c_hi:.6f}",
            f"{m_tot:.3f}", f"{t_lo:.3f}", f"{t_hi:.3f}",
            f"{mean(peaks):.0f}" if peaks else "nan",
            f"{mean(calls):.0f}" if calls else "nan",
        ]) + "\n")

print(f"Wrote {summary_path}")
print(f"Wrote {plot_path}")
PY
}

main_single() {
	local ts="$1" outdir="$2"
	set_target_procs "$TARGET_PROCS"
	mkdir -p "$outdir"

	echo "=== 输出目录: $outdir ==="
	echo "负载: messaging groups=$MSG_GROUPS loops=$RUNTIME_LOOPS 进程≈$ACTUAL_PROCS CPU_SET=${CPU_SET:-none} SUITE_GAP_SEC=$SUITE_GAP_SEC"
	echo "ftrace: $FTRACE_FUNC (GRAPH=$FTRACE_GRAPH)"

	run_single_suite "$outdir" "single"

	cat >"$outdir/README.txt" <<EOF
ioprio CPU 监控热路径测量（单次）

函数: $FTRACE_FUNC
目标进程: $TARGET_PROCS (实际 $ACTUAL_PROCS)

复现:
  脚本内置 RUN_MODE=single 后: sudo -v && sudo ./exp_ioprio_monitor_hotpath.sh
EOF

	echo ""
	echo "完成: $outdir"
	cat "$outdir/delta.txt"
}

main_sweep() {
	local ts="$1" sweep_dir="$2"
	local -a targets=()
	while IFS= read -r t; do
		targets+=("$t")
	done < <(parse_sweep_list "$PROC_SWEEP")

	(( ${#targets[@]} > 0 )) || {
		echo "ERROR: PROC_SWEEP 为空" >&2
		exit 1
	}
	(( SWEEP_REPS >= 1 )) || SWEEP_REPS=1

	if [[ "$FTRACE_GRAPH" != "1" ]]; then
		echo "WARN: 规模扫描建议 FTRACE_GRAPH=1 以解析单次 work 耗时" >&2
	fi

	mkdir -p "$sweep_dir/by_target"
	points_tsv="$sweep_dir/sweep_points.tsv"
	echo -e "target_procs\tactual_procs\trep\trun_dir\tphase\toverride_peak\toverride_ok\tfn_calls\twork_us_mean\twork_us_median\twork_us_max\twork_total_ms\tbench_sec" >"$points_tsv"

	: >"$sweep_dir/execution_order.log"
	echo "=== 规模扫描: $sweep_dir ==="
	echo "PROC_SWEEP=${targets[*]}  SWEEP_REPS=$SWEEP_REPS  LOOPS=$LOOPS  SWEEP_INTERLEAVE=$SWEEP_INTERLEAVE  SUITE_GAP_SEC=$SUITE_GAP_SEC"
	echo "ftrace: $FTRACE_FUNC (GRAPH=$FTRACE_GRAPH)"

	append_sweep_points() {
		local rep_dir="$1" tp="$2" actual="$3" rep="$4"
		python3 - "$points_tsv" "$rep_dir" "$tp" "$actual" "$rep" <<'PY'
import sys

points, rep_dir, tp, actual, rep = sys.argv[1:6]
for phase in ("monitor_off", "monitor_on"):
    path = f"{rep_dir}/{phase}/metrics.tsv"
    with open(path, encoding="utf-8") as f:
        hdr = f.readline().strip().split("\t")
        row = f.readline().strip().split("\t")
    d = dict(zip(hdr, row))
    with open(points, "a", encoding="utf-8") as out:
        out.write("\t".join([
            tp, actual, rep, rep_dir, phase,
            d.get("override_peak", ""),
            d.get("override_ok", ""),
            d.get("fn_calls", ""),
            d.get("work_us_mean", ""),
            d.get("work_us_median", ""),
            d.get("work_us_max", ""),
            d.get("work_total_ms", ""),
            d.get("bench_sec", ""),
        ]) + "\n")
PY
	}

	local tp rep rep_dir run_tag tdir _sweep_gap_prev=""
	if [[ "$SWEEP_INTERLEAVE" == "1" ]]; then
		echo "执行顺序: 重复 $SWEEP_REPS 轮，每轮依次 ${targets[*]}（各 off+on 一次）" >&2
		for (( rep = 1; rep <= SWEEP_REPS; rep++ )); do
			echo ""
			echo "=== 交错轮次 $rep/$SWEEP_REPS: ${targets[*]} ==="
			for tp in "${targets[@]}"; do
				[[ -n "$_sweep_gap_prev" ]] && suite_gap_sleep "$_sweep_gap_prev"
				TARGET_PROCS="$tp"
				set_target_procs "$tp"
				tdir="$sweep_dir/by_target/target_${tp}"
				mkdir -p "$tdir"
				echo "$TARGET_PROCS" >"$tdir/target_procs.txt"
				echo "$ACTUAL_PROCS" >"$tdir/actual_procs.txt"
				rep_dir="$tdir/rep_$(printf '%02d' "$rep")"
				run_tag="target_${tp}_rep_${rep}"
				echo -e "${rep}\t${tp}\t${ACTUAL_PROCS}\t${run_tag}" >>"$sweep_dir/execution_order.log"
				run_single_suite "$rep_dir" "$run_tag"
				append_sweep_points "$rep_dir" "$tp" "$ACTUAL_PROCS" "$rep"
				_sweep_gap_prev="周期 ${rep}/${SWEEP_REPS} target_${tp} 完成"
			done
		done
	else
		echo "执行顺序: 按规模分块（每档连续 $SWEEP_REPS 轮）" >&2
		for tp in "${targets[@]}"; do
			[[ -n "$_sweep_gap_prev" ]] && suite_gap_sleep "$_sweep_gap_prev"
			TARGET_PROCS="$tp"
			set_target_procs "$tp"
			tdir="$sweep_dir/by_target/target_${tp}"
			mkdir -p "$tdir"
			echo "$TARGET_PROCS" >"$tdir/target_procs.txt"
			echo "$ACTUAL_PROCS" >"$tdir/actual_procs.txt"
			for (( rep = 1; rep <= SWEEP_REPS; rep++ )); do
				rep_dir="$tdir/rep_$(printf '%02d' "$rep")"
				run_tag="target_${tp}_rep_${rep}"
				run_single_suite "$rep_dir" "$run_tag"
				append_sweep_points "$rep_dir" "$tp" "$ACTUAL_PROCS" "$rep"
				(( rep < SWEEP_REPS )) && suite_gap_sleep "target_${tp} rep ${rep}/${SWEEP_REPS} 完成"
			done
			_sweep_gap_prev="target_${tp} 全部 ${SWEEP_REPS} 轮完成"
		done
	fi

	aggregate_sweep "$sweep_dir" "$points_tsv"

	cat >"$sweep_dir/README.txt" <<EOF
ioprio CPU 监控热路径 — 多规模扫描

PROC_SWEEP=$PROC_SWEEP
SWEEP_REPS=$SWEEP_REPS
LOOPS=$LOOPS  CPU_SET=${CPU_SET:-none}
FTRACE_GRAPH=$FTRACE_GRAPH
SUITE_GAP_SEC=$SUITE_GAP_SEC

目录:
  by_target/target_<N>/rep_<RR>/  — 每次重复的 monitor_off/on
  sweep_points.tsv               — 各次原始点（作图/复查）
  sweep_summary.tsv              — 按规模聚合（中位、95% CI）
  plot_sweep.csv                 — 可直接 import 到 matplotlib

复现:
  sudo -v && sudo ./exp_ioprio_monitor_hotpath.sh
  （参数见脚本顶部「实验配置」）

作图示例 (Python):
  import pandas as pd, matplotlib.pyplot as plt
  df = pd.read_csv("plot_sweep.csv")
  plt.errorbar(df.target_procs, df.work_ms_mean_median,
               yerr=[df.work_ms_mean_median-df.work_ms_mean_ci_low,
                     df.work_ms_mean_ci_high-df.work_ms_mean_median],
               fmt="o-")
  plt.xscale("log"); plt.xlabel("Target processes"); plt.ylabel("One work round (ms)")
  plt.savefig("work_cost_vs_procs.pdf")
EOF

	echo ""
	echo "完成规模扫描: $sweep_dir"
	echo "--- sweep_summary.tsv ---"
	column -t "$sweep_dir/sweep_summary.tsv" 2>/dev/null || cat "$sweep_dir/sweep_summary.tsv"
}

repair_sweep_dir() {
	local sweep_dir="$1"
	[[ -d "$sweep_dir/by_target" ]] || {
		echo "ERROR: 非 sweep 目录: $sweep_dir" >&2
		exit 1
	}
	echo "=== 修复 override_peak / metrics: $sweep_dir ==="
	while IFS= read -r maxf; do
		local pdir phase rep_dir tp rep_num run_tag dense_log peak
		pdir="$(dirname "$maxf")"
		phase="$(basename "$pdir")"
		rep_dir="$(cd "$(dirname "$pdir")" && pwd)"
		tp="$(basename "$(dirname "$rep_dir")")"
		tp="${tp#target_}"
		rep_num=$((10#$(basename "$rep_dir" | sed 's/^rep_0*//')))
		run_tag="target_${tp}_rep_${rep_num}"
		dense_log="$rep_dir/dense_override.log"
		peak="$(read_override_peak "$maxf" "$dense_log" "$phase" "$run_tag")"
		metrics="$pdir/metrics.tsv"
		[[ -f "$metrics" ]] || continue
		python3 - "$metrics" "$peak" <<'PY'
import sys
path, peak = sys.argv[1], sys.argv[2]
lines = open(path, encoding="utf-8").read().splitlines()
hdr = lines[0].split("\t")
row = lines[1].split("\t")
d = dict(zip(hdr, row))
d["override_peak"] = peak
ok = 1
try:
    need = int(d.get("actual_procs", 0)) * 10 // 100
    if need < 500:
        need = min(500, int(d.get("actual_procs", 0)))
    if int(d.get("actual_procs", 0)) >= 5000:
        need = max(need, 5000)
    if int(peak) < need:
        ok = 0
except ValueError:
    ok = 0
d["override_ok"] = str(ok)
with open(path, "w", encoding="utf-8") as f:
    f.write("\t".join(hdr) + "\n")
    f.write("\t".join(d[k] for k in hdr) + "\n")
PY
	done < <(find "$sweep_dir/by_target" -name override_peak.max 2>/dev/null)

	points_tsv="$sweep_dir/sweep_points.tsv"
	: >"$points_tsv"
	echo -e "target_procs\tactual_procs\trep\trun_dir\tphase\toverride_peak\toverride_ok\tfn_calls\twork_us_mean\twork_us_median\twork_us_max\twork_total_ms\tbench_sec" >"$points_tsv"
	find "$sweep_dir/by_target" -path '*/monitor_on/metrics.tsv' | while read -r m; do
		rep_dir="$(dirname "$(dirname "$m")")"
		tp="$(basename "$(dirname "$rep_dir")")"
		tp="${tp#target_}"
		rep="$(basename "$rep_dir")"
		rep="${rep#rep_}"
		actual="$(cat "$(dirname "$rep_dir")/actual_procs.txt" 2>/dev/null || echo "$tp")"
		for phase in monitor_off monitor_on; do
			mp="${rep_dir}/${phase}/metrics.tsv"
			[[ -f "$mp" ]] || continue
			python3 - "$points_tsv" "$mp" "$tp" "$actual" "$rep" "$rep_dir" "$phase" <<'PY'
import sys
points, mp, tp, actual, rep, rep_dir, phase = sys.argv[1:8]
hdr = open(mp, encoding="utf-8").readline().strip().split("\t")
row = open(mp, encoding="utf-8").readlines()[1].strip().split("\t")
d = dict(zip(hdr, row))
with open(points, "a", encoding="utf-8") as out:
    out.write("\t".join([
        tp, actual, str(int(rep)), rep_dir, phase,
        d.get("override_peak", ""), d.get("override_ok", ""),
        d.get("fn_calls", ""), d.get("work_us_mean", ""),
        d.get("work_us_median", ""), d.get("work_us_max", ""),
        d.get("work_total_ms", ""), d.get("bench_sec", ""),
    ]) + "\n")
PY
		done
	done
	aggregate_sweep "$sweep_dir" "$points_tsv"
	echo "已重写 sweep_summary.tsv / plot_sweep.csv"
}

# --- main ---
case "$RUN_MODE" in
repair)
	if [[ -z "${REPAIR_SWEEP_DIR// }" ]]; then
		echo "ERROR: RUN_MODE=repair 请在脚本中设置 _cfg_REPAIR_SWEEP_DIR" >&2
		exit 1
	fi
	repair_dir="$REPAIR_SWEEP_DIR"
	[[ "$repair_dir" != /* ]] && repair_dir="$ROOT/$repair_dir"
	repair_sweep_dir "$repair_dir"
	;;
single)
	init_environment
	TS="$(date +%Y%m%d_%H%M%S)"
	echo "模式: 单次  TARGET_PROCS=$TARGET_PROCS  FTRACE_GRAPH=$FTRACE_GRAPH"
	main_single "$TS" "$ROOT/results_ioprio_hotpath_${TS}"
	;;
sweep)
	init_environment
	TS="$(date +%Y%m%d_%H%M%S)"
	echo "模式: 规模扫描  PROC_SWEEP=$PROC_SWEEP  SWEEP_REPS=$SWEEP_REPS  FTRACE_GRAPH=$FTRACE_GRAPH"
	main_sweep "$TS" "$ROOT/results_ioprio_hotpath_sweep_${TS}"
	;;
*)
	echo "ERROR: 未知 RUN_MODE=$RUN_MODE（应为 sweep|single|repair）" >&2
	exit 1
	;;
esac
