#!/bin/bash
#
# 实验 A（三组）— 统一优先级版
#
# 所有 phase 中：fio 与 malicious 的 base ionice 都是 RT class 1 level 7。
# 唯一变量：是否调 ioprio_override / 是否开 CPU 监控 / 字节限流是否开启。
# 防御只剩"内核 revoke"一步——不再对 malicious 做任何用户态 ionice 后续动作。
#
# G1: fio + malicious 公平基线（4MiB/4MiB 限流开、无 override）— **对照 baseline**
# G2: 同上 + ioprio_override，监控关 — 攻击成功
# G3: 同上 + ioprio_override，监控开 — 内核 revoke 撤销 burst 豁免（无用户态后续步骤）
#
# 指标：fio 吞吐；含恶意时另报告恶意进程平均 I/O 延迟与吞吐（MAL_SUMMARY）
#
# 环境变量：TEST_DEV FIO_BG_COUNT FIO_BS FIO_RAMP_TIME FIO_RUNTIME REPS
#         BW_LOG_INTERVAL_MS QUEUE_WATCH_INTERVAL_SEC
#
ROOT="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=exp_common.sh
source "$ROOT/exp_common.sh"

# 限流：bdev_set_bytes enable=1，high_bytes = low_bytes = 4MiB
export BFQ_HIGH_BYTES=4194304
export BFQ_LOW_BYTES=4194304

SKIP_BUILD=0
[[ "${1:-}" == "--skip-build" ]] && SKIP_BUILD=1

# 重复次数（每次跑完 G1/G2/G3 算一个 rep；时间序列图与误差棒均依赖 REPS>=3）
: "${REPS:=3}"

TS="$(date +%Y%m%d_%H%M%S)"
OUTDIR="$ROOT/results_exp_a_$TS"
mkdir -p "$OUTDIR"

echo "=== 实验 A 输出目录: $OUTDIR ==="
echo "限流: 三组均 bdev_set_bytes enable=1 high=low=${BFQ_HIGH_BYTES} (4MiB)；仅 G2/G3 调 ioprio_override"
echo "重复次数 REPS=$REPS；瞬时带宽采样 BW_LOG_INTERVAL_MS=${BW_LOG_INTERVAL_MS:-200}"

exp_check_sysctl || exit 1
[[ "$SKIP_BUILD" == 0 ]] && exp_build_tools
exp_setup_bfq_bdev || exit 1

FIO_PID=""
M_PID=""

cleanup_exp_a() {
	exp_stop_queue_watch
	[[ -n "${FIO_PID:-}" ]] && kill "$FIO_PID" 2>/dev/null || true
	wait "$FIO_PID" 2>/dev/null || true
	[[ -n "${M_PID:-}" ]] && sudo kill -TERM "$M_PID" 2>/dev/null || true
	wait "$M_PID" 2>/dev/null || true
	exp_kill_children
}
trap cleanup_exp_a EXIT

write_na_malicious() {
	local d="$1"
	echo nan >"$d/malicious_ios.txt"
	echo nan >"$d/malicious_avg_latency_us.txt"
	echo nan >"$d/malicious_throughput_MiB_s.txt"
}

run_phase() {
	local rep="$1"
	local phase_id="$2"
	local group_desc="$3"
	local want_malicious="$4"
	local monitor_val="$5"
	# 以下为可选参数：
	local want_override="${6:-1}"         # 1=调 ./ioprio_override $M_PID；0=不调（G1 基线）
	local bfq_enable="${7:-1}"            # bdev_set_bytes 的 enable（三组均为 1）
	local bfq_high="${8:-$BFQ_HIGH_BYTES}"
	local bfq_low="${9:-$BFQ_LOW_BYTES}"
	# malicious 的 base ionice 全实验统一 RT-7（与 fio prioclass=1 prio=7 完全对称）。
	# 攻击者的"不当优势"只来自 ioprio_override 的 burst 豁免，base 优先级不再有差异。
	local mal_class=1
	local mal_level=7
	local cdir="$OUTDIR/rep_$(printf '%02d' "$rep")/$phase_id"

	mkdir -p "$cdir"
	exp_set_cpu_monitor "$monitor_val" || return 1

	# 每 phase 都重新应用 bdev_set_bytes（参数因组而异，见 run_phase 调用）。
	exp_set_bdev_bytes "$bfq_enable" "$bfq_high" "$bfq_low" || return 1

	exp_drop_caches

	# 对齐基准：CLOCK_BOOTTIME 与 dmesg printk 时戳同源；同时记录 wall epoch 用于 fio log_unix_epoch=1
	exp_record_phase_t0 "$cdir/phase_t0.tsv"

	local fj="$cdir/fio.json"
	# fio bw log 前缀：fio 会写出 ${prefix}_bw.log（per_job_logs=0 合并）
	local fio_bw_prefix="$cdir/fio_bw"
	exp_write_sustained_fio "$cdir/sustained.fio" "$fio_bw_prefix"

	# 记录本 phase 的关键设置到 phase_config.tsv，方便 plotter 与人工 review
	{
		printf 'key\tvalue\n'
		printf 'phase\t%s\n' "$phase_id"
		printf 'want_malicious\t%s\n' "$want_malicious"
		printf 'cpu_monitor\t%s\n' "$monitor_val"
		printf 'want_override\t%s\n' "$want_override"
		printf 'bfq_enable\t%s\n' "$bfq_enable"
		printf 'bfq_high_bytes\t%s\n' "$bfq_high"
		printf 'bfq_low_bytes\t%s\n' "$bfq_low"
		printf 'mal_ionice_class\t%s\n' "$mal_class"
		printf 'mal_ionice_level\t%s\n' "$mal_level"
		printf 'fio_bs\t%s\n' "$FIO_BS"
		printf 'fio_iodepth\t4\n'
		printf 'fio_bg_count\t%s\n' "$FIO_BG_COUNT"
		printf 'mal_bs\t1048576\n'
		printf 'mal_iodepth\t4\n'
	} >"$cdir/phase_config.tsv"

	echo "--- rep=$rep $phase_id: $group_desc | malicious=$want_malicious monitor=$monitor_val override=$want_override bfq_enable=$bfq_enable mal_ionice=-c${mal_class} -n${mal_level} ---" >&2

	# 队列观察（仅终端打印，不存盘；输出走 stderr 以避免污染下游 tee）
	exp_start_queue_watch "$phase_id"

	# fio：JSON 用命令行 --output；stdout+stderr 合并到 fio.stdout（带宽行多在 stderr）
	exp_run_fio_sustained "$cdir/sustained.fio" "$fj" "$cdir/fio.stdout" &
	FIO_PID=$!
	sleep 2

	M_PID=""
	if [[ "$want_malicious" == "1" ]]; then
		# $! 是外层 sudo 的 PID，子进程 malicious_sustained 不继承 ioprio_override（fork 清零）
		# MAL_BW_LOG 让 malicious_sustained 周期性写瞬时带宽（CLOCK_BOOTTIME 时戳）。
		# 用 env(1) 注入而非 sudo VAR=val 形式，避免被 sudoers env_reset 吃掉。
		# ionice 全实验统一 RT-7（与 fio prioclass=1 prio=7 对称）。
		sudo env "MAL_BW_LOG=$cdir/malicious_bw.tsv" \
			"MAL_BW_LOG_INTERVAL_MS=${BW_LOG_INTERVAL_MS:-200}" \
			ionice -c"$mal_class" -n"$mal_level" "$ROOT/malicious_sustained" "$TEST_DEV" \
			>>"$cdir/malicious.log" 2>&1 &
		sleep 1
		# comm 最长 15 字节，默认 pgrep 按 comm 会零匹配；用 -f 匹配 cmdline。
		# 勿加 -x：与 -f 组合时要求「整条命令行」与模式完全一致，会永远匹配不到带参数 argv。
		M_PID="$(pgrep -n -f malicious_sustained || true)"
		if [[ -z "$M_PID" ]]; then
			echo "ERROR: malicious_sustained not found (pgrep)" >&2
			return 1
		fi
		echo "$M_PID" >"$cdir/malicious.pid"
		if [[ "$want_override" == "1" ]]; then
			"$ROOT/ioprio_override" "$M_PID"
		else
			echo "[$phase_id] ioprio_override skipped (want_override=0, baseline group)" >>"$cdir/malicious.log"
		fi
		# G3 防御现在只剩"内核 revoke"一步；不再做任何用户态 ionice 后续动作。
	fi

	wait "$FIO_PID" || true
	FIO_PID=""

	if [[ -n "$M_PID" ]]; then
		sudo kill -TERM "$M_PID" 2>/dev/null || true
		wait "$M_PID" 2>/dev/null || true
		M_PID=""
	fi

	exp_stop_queue_watch
	exp_kill_children

	if [[ -f "$fj" ]]; then
		exp_fio_read_bw_mibs "$fj" "$cdir/fio.stdout" >"$cdir/sustained_bw_MiB_s.txt"
	else
		echo nan >"$cdir/sustained_bw_MiB_s.txt"
	fi

	if [[ "$want_malicious" == "1" ]]; then
		exp_malicious_stats_from_log "$cdir/malicious.log" \
			"$cdir/malicious_ios.txt" \
			"$cdir/malicious_avg_latency_us.txt" \
			"$cdir/malicious_throughput_MiB_s.txt"
	else
		write_na_malicious "$cdir"
	fi

	# 完整 dmesg + 抽取 revoke 事件（保留原始 printk 时戳，单位秒，CLOCK_MONOTONIC 域）
	dmesg -T >"$cdir/dmesg_tail.txt" 2>/dev/null || true
	{
		printf 'kind\tt_boot_s\tpid\tcomm\tdetail\n'
		# 原始 dmesg（不带 -T）的方括号时戳是 seconds.usec since boot
		sudo dmesg 2>/dev/null | tail -800 | \
			awk -v pid="${M_PID:-0}" -v phase="$phase_id" '
			/ioprio_override: revoked burst pid=/ {
				ts="" ; if (match($0,/^\[[ 0-9.]+\]/)) { ts=substr($0,2,RLENGTH-2); gsub(/ /,"",ts) }
				p=""; if (match($0,/pid=[0-9]+/)) p=substr($0,RSTART+4,RLENGTH-4)
				if (pid != "0" && p != pid) next
				cm=""; if (match($0,/comm=[^ ]+/)) cm=substr($0,RSTART+5,RLENGTH-5)
				dt=$0; sub(/^\[[ 0-9.]+\] /,"",dt)
				print "revoke\t" ts "\t" p "\t" cm "\t" dt
			}'
	} >"$cdir/revoke_events.tsv" 2>/dev/null || true

	printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
		"$rep" "$phase_id" "$group_desc" "$monitor_val" \
		"$(cat "$cdir/sustained_bw_MiB_s.txt")" \
		"$(cat "$cdir/malicious_avg_latency_us.txt")" \
		"$(cat "$cdir/malicious_throughput_MiB_s.txt")" \
		"$(cat "$cdir/malicious_ios.txt")"
}

printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
	'rep' 'phase' 'group' 'cpu_monitor' \
	'fio_MiB_s' \
	'malicious_avg_latency_us' 'malicious_throughput_MiB_s' 'malicious_ios' \
	| tee "$OUTDIR/summary.tsv"

for ((rep = 1; rep <= REPS; rep++)); do
	echo "================ REP $rep / $REPS ================"

	echo "=== G1：公平基线（fio+malicious 同级 RT-7；4MiB 限流开、无 override、无监控）==="
	# want_malicious=1 monitor=0 want_override=0 bfq_enable=1（与 G2/G3 相同门限，仅差 override）
	run_phase "$rep" "G1_no_mechanism" \
		"fio+malicious limiter baseline (4MiB/4MiB, no override, no monitor)" \
		1 0 0 1 | tee -a "$OUTDIR/summary.tsv"
	sleep 5

	echo "=== G2：攻击（ioprio_override；CPU 监控关）==="
	run_phase "$rep" "G2_malicious_monitor_off" "fio+malicious no monitor" 1 0 | tee -a "$OUTDIR/summary.tsv"
	sleep 5

	echo "=== G3：防御（ioprio_override + CPU 监控 → 内核 revoke；无用户态后续）==="
	run_phase "$rep" "G3_malicious_monitor_on" "fio+malicious+cpu monitor" 1 1 | tee -a "$OUTDIR/summary.tsv"
	sleep 5
done

exp_set_cpu_monitor 1
# 脚本结束保持限流 enable=1（与实验默认一致）
exp_set_bdev_bytes 1 "$BFQ_HIGH_BYTES" "$BFQ_LOW_BYTES" || true

cat >"$OUTDIR/README.txt" <<EOF
实验 A（三组 × REPS=${REPS}）— 统一优先级版；G1 为公平基线

负载（fio 与 malicious 对齐：1 MiB O_DIRECT read、libaio、iodepth=4）：
- fio: ${FIO_BG_COUNT} 个 background job，bs=${FIO_BS}，iodepth=4，prioclass=1 prio=7，ramp ${FIO_RAMP_TIME}s，runtime ${FIO_RUNTIME}s
- malicious_sustained（G1/G2/G3）：sudo ionice -c1 -n7 ./malicious_sustained ...
  bs=1 MiB，libaio pipeline iodepth=4（与 fio 相同）
  **所有 phase 中 malicious 与 fio 的 base ionice 都是 RT-7**——攻击者的不当优势
  只能来自 ioprio_override 的 burst 豁免，与 base 优先级无关。

三组矩阵（每 rep 顺序：G1 → G2 → G3；**三组限流参数相同**）：
+----+----------------------------+----------------+-----------+-------+--------+
| 组 | 设计角色                    | bdev_set_bytes  | override  | mon   | 防御后续 |
+----+----------------------------+----------------+-----------+-------+--------+
| G1 | **公平基线（baseline）**   | enable=1 4M/4M | **no**     | off   | —        |
| G2 | 攻击 + 无防御                | enable=1 4M/4M  | yes        | off   | —        |
| G3 | 攻击 + 内核 revoke 防御      | enable=1 4M/4M  | yes        | on    | **无**   |
+----+----------------------------+----------------+-----------+-------+--------+
G1 与 G2/G3 的唯一差别：**不调用 ioprio_override**（限流门限一致）。

预期数值（以 G1 为「同限流、无 override」参照）：
  G1：fio 与 malicious 在字节门限下由 BFQ 分配（实测比例以跑数为准）
  G2：相对 G1，fio 极低、malicious 极高（burst 豁免）
  G3：revoke 后 fio 恢复，应趋近 G1；30s 聚合含 ~3s 攻击段

对比意义：
  - G2 vs G1：isolate ioprio_override 攻击效果（限流相同）
  - G2 vs G3：内核 revoke 是否能把系统从攻击态拉回
  - G3 vs G1：revoke 后是否回到「同限流、无 override」基线

目录布局：
  results_exp_a_<TS>/
    summary.tsv                # 聚合表（rep × phase）
    rep_NN/
      G1_no_mechanism/ G2_*/ G3_*/
        phase_config.tsv       # 实际生效参数
        phase_t0.tsv           # 时间序列对齐基准（boot + wall）
        fio_bw_bw.log          # fio 瞬时带宽
        malicious_bw.tsv       # malicious 瞬时带宽（pthread 采样线程）
        revoke_events.tsv      # G3 才有：dmesg 抽取的 revoked burst 时戳
        sustained_bw_MiB_s.txt malicious_*.txt
        fio.json fio.stdout sustained.fio dmesg_tail.txt

环境变量：
- REPS（默认 1）：重复次数；REPS≥3 才能在时间序列图上画 IQR 带、聚合柱状图上画 CI。
- BW_LOG_INTERVAL_MS（默认 200）：fio + malicious 的瞬时带宽采样周期。
- QUEUE_WATCH_INTERVAL_SEC（默认 1）：每 N 秒在 stderr 打印 bdev_get_bytes 读到的 io_bytes；
  设 0 禁用。仅供人工观察，不进 summary.tsv 也不进任何图。
EOF

# 防呆：本脚本内部已自带 sudo，**不需要**外层 sudo 启动。
# 若用户依然用 sudo 跑了，OUTDIR 会变成 root 拥有，后续以普通用户跑 plot_exp_a_timeline.py 会写不进 figures_timeline/。
# 这里把 OUTDIR 归还给 $SUDO_USER，让两种调用方式都可用。
if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
	chown -R "$SUDO_USER":"$(id -gn "$SUDO_USER" 2>/dev/null || echo "$SUDO_USER")" "$OUTDIR" 2>/dev/null || true
fi

echo "完成。见 $OUTDIR/README.txt 与 summary.tsv"
