#!/bin/bash

# =========================
# fio(后台) + RocksDB(前台) 联合测试脚本
# 目标:
# 1) 对比 none / bfq / bfq_limit(same) / bfq_limit(dual)
# 2) 统计 fio 后台吞吐量
# 3) 统计 RocksDB 平均延迟(μs)
# =========================

set -u

# ---------- 中断处理 ----------
INTERRUPTED=0
CURRENT_FIO_PID=""
CURRENT_ROCKSDB_PID=""
QUEUE_MONITOR_PID=""
DBBENCH_MONITOR_PID=""
POSTFLIGHT_DONE=0

cleanup_running_jobs() {
	if [ -n "$QUEUE_MONITOR_PID" ] && kill -0 "$QUEUE_MONITOR_PID" >/dev/null 2>&1; then
		kill "$QUEUE_MONITOR_PID" >/dev/null 2>&1 || true
		wait "$QUEUE_MONITOR_PID" 2>/dev/null || true
	fi
	QUEUE_MONITOR_PID=""

	if [ -n "$DBBENCH_MONITOR_PID" ] && kill -0 "$DBBENCH_MONITOR_PID" >/dev/null 2>&1; then
		kill "$DBBENCH_MONITOR_PID" >/dev/null 2>&1 || true
		wait "$DBBENCH_MONITOR_PID" 2>/dev/null || true
	fi
	DBBENCH_MONITOR_PID=""

	if [ -n "$CURRENT_ROCKSDB_PID" ] && kill -0 "$CURRENT_ROCKSDB_PID" >/dev/null 2>&1; then
		kill -INT "$CURRENT_ROCKSDB_PID" >/dev/null 2>&1 || true
		wait "$CURRENT_ROCKSDB_PID" 2>/dev/null || true
	fi
	CURRENT_ROCKSDB_PID=""

	if [ -n "$CURRENT_FIO_PID" ] && kill -0 "$CURRENT_FIO_PID" >/dev/null 2>&1; then
		sudo kill -INT "$CURRENT_FIO_PID" >/dev/null 2>&1 || true
		wait "$CURRENT_FIO_PID" 2>/dev/null || true
	fi
	CURRENT_FIO_PID=""
}

postflight_restore() {
	if [ "$POSTFLIGHT_DONE" -eq 1 ]; then
		return
	fi
	POSTFLIGHT_DONE=1

	local dev_name
	dev_name=$(basename "$DEVICE")
	echo "执行脚本收尾重置..."

	# 防止脚本退出后残留任务影响后续独立测试
	cleanup_running_jobs
	sudo pkill -f "/home/str508/rocksdb/db_bench" 2>/dev/null || true
	sudo pkill -f "fio" 2>/dev/null || true

	# 强制回到默认可复现状态：none -> bfq，并显式关闭 bdev 限制
	echo none | sudo tee "/sys/block/$dev_name/queue/scheduler" > /dev/null || true
	sleep 1
	echo bfq | sudo tee "/sys/block/$dev_name/queue/scheduler" > /dev/null || true
	if [ -x "./bdev_set_bytes" ]; then
		./bdev_set_bytes "$DEVICE" 0 2147483647 2147483647 > /dev/null || true
	fi

	# 收尾也做一次 cache 清理，减少跨脚本漂移
	cleanup_system_cache
	echo "收尾重置完成。"
}

on_interrupt() {
	if [ "$INTERRUPTED" -eq 1 ]; then
		return
	fi
	INTERRUPTED=1
	echo ""
	echo "收到 Ctrl+C，正在停止当前测试并退出..."
	cleanup_running_jobs
	postflight_restore
	exit 130
}

trap on_interrupt INT TERM
trap postflight_restore EXIT

# ---------- 基础配置 ----------
DEVICE="/dev/nvme0n1"
RESULT_ROOT="results_rocksdb"
GLOBAL_CONSOLE_LOG=""

BACKGROUND_COUNTS=(8)
BLOCK_SIZES=("1M")

# bfq_limit(same): high = low
# 默认做 high 梯度: 4MB -> 2MB -> 1MB
BFQ_LIMIT_SAME_THRESHOLDS=(4194304)

# bfq_limit(dual): high:low 配对（便于多 high 梯度扫描）
BFQ_LIMIT_DUAL_PAIRS=(
	"4194304:3145728"
	"4194304:2097152"
	"4194304:1048576"
)

REPEAT_COUNT=3

# 缩短单次观测时间，便于快速迭代
FIO_RUNTIME_SECONDS=600
ROCKSDB_START_DELAY_SECONDS=3

AUTO_CLEAN_INTERMEDIATE=true
CLEAN_SYSTEM_CACHE=true
ENABLE_FOREGROUND_IOPRIO_OVERRIDE=true
OLD_RESULTS_ACTION=${OLD_RESULTS_ACTION:-"keep"}  # keep|delete|ask
STRICT_BDEV_VERIFY=${STRICT_BDEV_VERIFY:-"false"}

# 文件系统准备（db_bench 需要文件系统，不可直接对裸设备目录路径工作）
ROCKSDB_MOUNT_POINT=${ROCKSDB_MOUNT_POINT:-"/mnt/nvme"}
ROCKSDB_FS_TYPE=${ROCKSDB_FS_TYPE:-"ext4"}
AUTO_MOUNT_FS=${AUTO_MOUNT_FS:-"true"}
FORCE_REMOUNT=${FORCE_REMOUNT:-"false"}
AUTO_FORMAT_IF_NO_FS=${AUTO_FORMAT_IF_NO_FS:-"false"}

# RocksDB 缓存与IO路径控制（更贴近块设备延迟）
DROP_CACHES_AFTER_PREP=${DROP_CACHES_AFTER_PREP:-"true"}
ROCKSDB_COMMON_OPTS=${ROCKSDB_COMMON_OPTS:-"--use_direct_reads=1 --use_direct_io_for_flush_and_compaction=1 --cache_size=0 --compressed_cache_size=0 --cache_index_and_filter_blocks=0 --pin_l0_filter_and_index_blocks_in_cache=0 --read_cache_size=0"}

# RocksDB 前台命令模板:
# - 使用 {DB_PATH} 作为数据库目录占位符
# - 默认使用 db_bench，不依赖 YCSB
# - 可通过环境变量覆盖
#   例如:
#   export ROCKSDB_BIN='/home/str508/rocksdb/db_bench'
#   export ROCKSDB_PREP_CMD_TEMPLATE='${ROCKSDB_BIN} --db={DB_PATH} --benchmarks=fillrandom --num=2000000 --threads=4 --statistics=0'
#   export ROCKSDB_CMD_TEMPLATE='${ROCKSDB_BIN} --db={DB_PATH} --benchmarks=readrandom --use_existing_db=1 --reads=500000 --threads=1 --statistics=0'
ROCKSDB_BIN=${ROCKSDB_BIN:-"/home/str508/rocksdb/db_bench"}
ROCKSDB_DURATION_SECONDS=${ROCKSDB_DURATION_SECONDS:-60}
ROCKSDB_READS=${ROCKSDB_READS:-500}
ROCKSDB_PREP_CMD_TEMPLATE=${ROCKSDB_PREP_CMD_TEMPLATE:-"${ROCKSDB_BIN} --db={DB_PATH} --benchmarks=fillrandom --num=1000000 --threads=4 --statistics=0 ${ROCKSDB_COMMON_OPTS}"}
ROCKSDB_CMD_TEMPLATE=${ROCKSDB_CMD_TEMPLATE:-"${ROCKSDB_BIN} --db={DB_PATH} --benchmarks=readrandom --use_existing_db=1 --reads=${ROCKSDB_READS} --threads=1 --statistics=0 ${ROCKSDB_COMMON_OPTS}"}
ROCKSDB_DB_BASE=${ROCKSDB_DB_BASE:-"/mnt/nvme/rocksdb_bench"}

# ---------- 全局统计 ----------
TOTAL_CONFIGS=0
TOTAL_TESTS=0
REALTIME_REPORT=""
REALTIME_CSV=""
BATCH_SUMMARY_DIR=""

declare -A SUM_FIO_KBPS
declare -A SUM_LAT_US
declare -A CNT_TOTAL
declare -A CNT_LAT

calculate_total_tests() {
	local scheduler_configs=$((2 + ${#BFQ_LIMIT_SAME_THRESHOLDS[@]} + ${#BFQ_LIMIT_DUAL_PAIRS[@]}))
	TOTAL_CONFIGS=$(( ${#BACKGROUND_COUNTS[@]} * ${#BLOCK_SIZES[@]} * scheduler_configs ))
	TOTAL_TESTS=$(( TOTAL_CONFIGS * REPEAT_COUNT ))
}

calculate_total_tests

init_console_log_capture() {
	mkdir -p "$RESULT_ROOT"
	local ts
	ts=$(date +%Y%m%d_%H%M%S)
	GLOBAL_CONSOLE_LOG="$RESULT_ROOT/console_${ts}.log"
	# 终端继续输出，同时完整落盘，方便复盘分析
	exec > >(tee -a "$GLOBAL_CONSOLE_LOG") 2>&1
	echo "控制台日志镜像: $GLOBAL_CONSOLE_LOG"
}

init_console_log_capture

echo "=========================================="
echo "   fio后台 + RocksDB前台 批量测试脚本"
echo "=========================================="
echo "设备: $DEVICE"
echo "Background数量: ${BACKGROUND_COUNTS[*]}"
echo "块大小: ${BLOCK_SIZES[*]}"
echo "重复次数: $REPEAT_COUNT"
echo "调度器模式: bfq bfq_limit(same) bfq_limit(dual)"
echo "bfq_limit(same): ${BFQ_LIMIT_SAME_THRESHOLDS[*]}"
echo "bfq_limit(dual) pairs: ${BFQ_LIMIT_DUAL_PAIRS[*]}"
echo "fio runtime: ${FIO_RUNTIME_SECONDS}s"
echo "RocksDB target reads: ${ROCKSDB_READS}"
echo "RocksDB二进制: $ROCKSDB_BIN"
echo "RocksDB挂载点: $ROCKSDB_MOUNT_POINT"
echo "文件系统类型: $ROCKSDB_FS_TYPE"
echo "自动挂载: $AUTO_MOUNT_FS"
echo "旧结果处理策略: $OLD_RESULTS_ACTION"
echo "bdev状态严格校验: $STRICT_BDEV_VERIFY"
echo "Prep后失效系统缓存: $DROP_CACHES_AFTER_PREP"
echo "RocksDB通用参数: $ROCKSDB_COMMON_OPTS"
echo "前台优先级覆盖: $ENABLE_FOREGROUND_IOPRIO_OVERRIDE"
echo "RocksDB预置命令: ${ROCKSDB_PREP_CMD_TEMPLATE:-<none>}"
echo "RocksDB命令模板: $ROCKSDB_CMD_TEMPLATE"
echo "总配置组合: $TOTAL_CONFIGS"
echo "总测试次数: $TOTAL_TESTS"
echo "=========================================="

setup_scheduler() {
	local mode=$1
	local high=${2:-""}
	local low=${3:-""}

	echo "设置调度器: $mode"
	case "$mode" in
		"none")
			echo none | sudo tee /sys/block/$(basename "$DEVICE")/queue/scheduler > /dev/null
			;;
		"bfq")
			echo bfq | sudo tee /sys/block/$(basename "$DEVICE")/queue/scheduler > /dev/null
			./bdev_set_bytes "$DEVICE" 0 2147483647 2147483647 > /dev/null
			;;
		"bfq_limit_same"|"bfq_limit_dual")
			echo bfq | sudo tee /sys/block/$(basename "$DEVICE")/queue/scheduler > /dev/null
			if [[ -z "$high" || -z "$low" ]]; then
				echo "错误: $mode 需要 high/low threshold"
				exit 1
			fi
			./bdev_set_bytes "$DEVICE" 1 "$high" "$low" > /dev/null
			;;
		*)
			echo "错误: 未知调度器模式: $mode"
			exit 1
			;;
	esac

	local current_scheduler
	current_scheduler=$(cat /sys/block/$(basename "$DEVICE")/queue/scheduler | grep -o '\[.*\]' | tr -d '[]')
	echo "当前调度器: $current_scheduler"

	report_bdev_status "$mode" "$low"
}

get_bdev_queue_bytes() {
	if [ -x "./bdev_get_bytes" ]; then
		./bdev_get_bytes "$DEVICE" 2>/dev/null || echo "-1"
	else
		echo "-1"
	fi
}

report_bdev_status() {
	local mode=$1
	local actual_low
	actual_low=$(get_bdev_queue_bytes)

	if ! [[ "$actual_low" =~ ^[0-9]+$ ]]; then
		echo "警告: 无法读取bdev队列字节状态，跳过状态报告"
		return 0
	fi

	echo "bdev当前队列字节: $actual_low"
	echo "注意: bdev_get_bytes 返回的是瞬时队列字节，不是已配置的阈值"

	if [ "$STRICT_BDEV_VERIFY" = "true" ]; then
		echo "提示: 当前没有可靠的syscall用于直接读取bfq/bfq_limit阈值，已仅输出队列字节状态"
	fi
}

start_queue_bytes_monitor() {
	local mode=$1
	local out_log=$2
	QUEUE_MONITOR_PID=""

	# none 模式不需要观测队列字节
	if [ "$mode" = "none" ]; then
		return
	fi

	(
		while true; do
			local bytes ts mb
			bytes=$(get_bdev_queue_bytes)
			ts=$(date '+%H:%M:%S')
			if [[ "$bytes" =~ ^[0-9]+$ ]]; then
				mb=$(awk -v b="$bytes" 'BEGIN{printf "%.2f", b/1024/1024}')
				echo "[$ts] queue_MB=$mb (bytes=$bytes)"
			else
				echo "[$ts] queue_MB=ERR($bytes)"
			fi
			sleep 1
		done
	) | tee -a "$out_log" &
	QUEUE_MONITOR_PID=$!
}

stop_queue_bytes_monitor() {
	local monitor_pid=$1
	if [ -n "$monitor_pid" ] && kill -0 "$monitor_pid" >/dev/null 2>&1; then
		kill "$monitor_pid" >/dev/null 2>&1 || true
		wait "$monitor_pid" 2>/dev/null || true
	fi
}

start_dbbench_progress_monitor() {
	local dbbench_pid=$1
	local rocksdb_log=$2
	DBBENCH_MONITOR_PID=""

	(
		local last_ops=""
		while kill -0 "$dbbench_pid" >/dev/null 2>&1; do
			local current_ops delta ts
			current_ops=$(grep -Eo '\.\.\. finished[[:space:]]+[0-9]+[[:space:]]+ops' "$rocksdb_log" 2>/dev/null | awk '{print $3}' | tail -n1)
			if [[ "$current_ops" =~ ^[0-9]+$ ]]; then
				if [[ "$last_ops" =~ ^[0-9]+$ ]]; then
					delta=$((current_ops - last_ops))
				else
					delta="N/A"
				fi
				last_ops="$current_ops"
			else
				current_ops="N/A"
				delta="N/A"
			fi
			ts=$(date '+%H:%M:%S')
			echo "[$ts] dbbench_progress ops=$current_ops ops_delta/s=$delta"
			sleep 1
		done
	) | tee -a "$rocksdb_log" &

	DBBENCH_MONITOR_PID=$!
}

stop_dbbench_progress_monitor() {
	if [ -n "$DBBENCH_MONITOR_PID" ] && kill -0 "$DBBENCH_MONITOR_PID" >/dev/null 2>&1; then
		kill "$DBBENCH_MONITOR_PID" >/dev/null 2>&1 || true
		wait "$DBBENCH_MONITOR_PID" 2>/dev/null || true
	fi
	DBBENCH_MONITOR_PID=""
}

get_all_scheduler_configs() {
	local configs=()
	configs+=("none::")
	configs+=("bfq::")

	local t
	for t in "${BFQ_LIMIT_SAME_THRESHOLDS[@]}"; do
		configs+=("bfq_limit_same:${t}:${t}")
	done

	local pair
	for pair in "${BFQ_LIMIT_DUAL_PAIRS[@]}"; do
		local high low
		IFS=':' read -r high low <<< "$pair"
		configs+=("bfq_limit_dual:${high}:${low}")
	done

	echo "${configs[@]}"
}

get_config_description() {
	local mode=$1
	local high=${2:-""}
	local low=${3:-""}

	case "$mode" in
		"none"|"bfq")
			echo "$mode"
			;;
		"bfq_limit_same")
			echo "bfq_limit(same:${high})"
			;;
		"bfq_limit_dual")
			echo "bfq_limit(dual:${high}/${low})"
			;;
		*)
			echo "$mode"
			;;
	esac
}

generate_sustained_fio() {
	local bg_count=$1
	local block_size=$2
	local fio_file=$3

	cat > "$fio_file" << EOF
[global]
filename=$DEVICE
ioengine=libaio
direct=1
time_based=1
ramp_time=3s
runtime=${FIO_RUNTIME_SECONDS}s
rw=read
iodepth=4
group_reporting=1

EOF

	local i
	for ((i=1; i<=bg_count; i++)); do
		cat >> "$fio_file" << EOF
[background_$i]
prioclass=1
prio=7
bs=$block_size
numjobs=1

EOF
	done
}

cleanup_old_results() {
	echo "========== 清理旧结果 =========="
	local old_dirs=""

	if [ -d "$RESULT_ROOT" ]; then
		old_dirs="$RESULT_ROOT"
	fi

	local legacy
	legacy=$(find . -maxdepth 1 -type d -name "results_rocksdb_*" 2>/dev/null)
	for d in $legacy; do
		old_dirs="$old_dirs $d"
	done

	if [ -n "${old_dirs// /}" ]; then
		echo "发现旧目录:"
		local total=0
		local d
		for d in $old_dirs; do
			[ -d "$d" ] || continue
			local size
			size=$(du -sm "$d" 2>/dev/null | awk '{print $1}')
			size=${size:-0}
			echo "  $d (${size}MB)"
			total=$((total + size))
		done

		echo "总计: ${total}MB"

		case "$OLD_RESULTS_ACTION" in
			"delete")
				for d in $old_dirs; do
					[ -d "$d" ] && rm -rf "$d" && echo "  ✓ 已删除: $d"
				done
				;;
			"ask")
				echo -n "是否删除？(y/N): "
				read -r answer
				case "$answer" in
					[yY]|[yY][eE][sS])
						for d in $old_dirs; do
							[ -d "$d" ] && rm -rf "$d" && echo "  ✓ 已删除: $d"
						done
						;;
					*)
						echo "保留旧目录，继续。"
						;;
				esac
				;;
			*)
				echo "按策略保留旧目录并继续。"
				;;
		esac
	else
		echo "✓ 未发现旧结果目录"
	fi
	echo "================================"
}

cleanup_system_cache() {
	if [ "$CLEAN_SYSTEM_CACHE" = "true" ]; then
		echo "  清理系统缓存..."
		sync
		echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null 2>&1
		echo "  ✓ 缓存清理完成"
	fi
}

preflight_reset() {
	local mode=$1
	local high=${2:-""}
	local low=${3:-""}
	local dev_name
	dev_name=$(basename "$DEVICE")

	echo "执行预检软重置..."

	# 先清理脚本已跟踪的后台任务
	cleanup_running_jobs

	# 再清理可能的历史残留进程（忽略不存在错误）
	sudo pkill -f "/home/str508/rocksdb/db_bench" 2>/dev/null || true
	sudo pkill -f "fio" 2>/dev/null || true
	sleep 1

	# 通过调度器回切刷新运行态，再由 setup_scheduler 应用目标模式
	echo none | sudo tee "/sys/block/$dev_name/queue/scheduler" > /dev/null || true
	sleep 1
	echo bfq | sudo tee "/sys/block/$dev_name/queue/scheduler" > /dev/null || true

	# 将 bdev 限制先恢复为关闭态，避免上轮阈值残留影响本轮
	if [ -x "./bdev_set_bytes" ]; then
		./bdev_set_bytes "$DEVICE" 0 2147483647 2147483647 > /dev/null || true
	fi

	# 软重置阶段也做一次缓存清理，缩小轮间漂移
	cleanup_system_cache
	sleep 2

	echo "预检软重置完成 -> 目标模式: ${mode} ${high}/${low}"
}

prepare_filesystem_for_rocksdb() {
	if [ "$AUTO_MOUNT_FS" != "true" ]; then
		echo "跳过自动挂载检查 (AUTO_MOUNT_FS=$AUTO_MOUNT_FS)"
		return 0
	fi

	echo "检查RocksDB文件系统挂载..."
	sudo mkdir -p "$ROCKSDB_MOUNT_POINT"

	if mountpoint -q "$ROCKSDB_MOUNT_POINT"; then
		local mounted_src
		mounted_src=$(findmnt -n -o SOURCE --target "$ROCKSDB_MOUNT_POINT" 2>/dev/null || true)
		if [ "$mounted_src" = "$DEVICE" ]; then
			echo "✓ 挂载已就绪: $DEVICE -> $ROCKSDB_MOUNT_POINT"
			sudo chown "$USER:$USER" "$ROCKSDB_MOUNT_POINT" 2>/dev/null || true
			return 0
		fi

		if [ "$FORCE_REMOUNT" = "true" ]; then
			echo "挂载点被占用($mounted_src)，执行重挂载..."
			sudo umount "$ROCKSDB_MOUNT_POINT"
		else
			echo "错误: 挂载点 $ROCKSDB_MOUNT_POINT 当前来自 $mounted_src (非 $DEVICE)"
			echo "请手动卸载或设置 FORCE_REMOUNT=true"
			exit 1
		fi
	fi

	local fs_type
	fs_type=$(sudo blkid -o value -s TYPE "$DEVICE" 2>/dev/null || true)
	if [ -z "$fs_type" ]; then
		if [ "$AUTO_FORMAT_IF_NO_FS" = "true" ]; then
			echo "设备无文件系统，正在格式化为 $ROCKSDB_FS_TYPE..."
			sudo mkfs -t "$ROCKSDB_FS_TYPE" -F "$DEVICE"
		else
			echo "错误: $DEVICE 未检测到文件系统。"
			echo "请先手动格式化并挂载，或设置 AUTO_FORMAT_IF_NO_FS=true"
			exit 1
		fi
	fi

	echo "挂载 $DEVICE -> $ROCKSDB_MOUNT_POINT"
	sudo mount -t "$ROCKSDB_FS_TYPE" "$DEVICE" "$ROCKSDB_MOUNT_POINT"

	if ! mountpoint -q "$ROCKSDB_MOUNT_POINT"; then
		echo "错误: 挂载失败"
		exit 1
	fi

	local mounted_src
	mounted_src=$(findmnt -n -o SOURCE --target "$ROCKSDB_MOUNT_POINT" 2>/dev/null || true)
	if [ "$mounted_src" != "$DEVICE" ]; then
		echo "错误: 挂载源异常，期望 $DEVICE，实际 $mounted_src"
		exit 1
	fi

	sudo chown "$USER:$USER" "$ROCKSDB_MOUNT_POINT" 2>/dev/null || true
	echo "✓ 文件系统挂载完成: $DEVICE -> $ROCKSDB_MOUNT_POINT"
}

strip_unsupported_rocksdb_flags() {
	local help_out
	help_out=$("$ROCKSDB_BIN" --help 2>&1 || true)

	if ! echo "$help_out" | grep -q -- '--allow_mmap_reads'; then
		ROCKSDB_PREP_CMD_TEMPLATE=${ROCKSDB_PREP_CMD_TEMPLATE// --allow_mmap_reads=0/}
		ROCKSDB_CMD_TEMPLATE=${ROCKSDB_CMD_TEMPLATE// --allow_mmap_reads=0/}
	fi

	if ! echo "$help_out" | grep -q -- '--allow_mmap_writes'; then
		ROCKSDB_PREP_CMD_TEMPLATE=${ROCKSDB_PREP_CMD_TEMPLATE// --allow_mmap_writes=0/}
		ROCKSDB_CMD_TEMPLATE=${ROCKSDB_CMD_TEMPLATE// --allow_mmap_writes=0/}
	fi

}

initialize_summary_files() {
	local ts
	ts=$(date +%Y%m%d_%H%M%S)
	BATCH_SUMMARY_DIR="$RESULT_ROOT/summary_${ts}"
	mkdir -p "$BATCH_SUMMARY_DIR"

	REALTIME_REPORT="$BATCH_SUMMARY_DIR/realtime_report.txt"
	REALTIME_CSV="$BATCH_SUMMARY_DIR/realtime_data.csv"

	cat > "$REALTIME_REPORT" << EOF
===== fio后台 + RocksDB前台 实时报告 =====
开始时间: $(date)
设备: $DEVICE

Background数量: ${BACKGROUND_COUNTS[*]}
块大小: ${BLOCK_SIZES[*]}
重复次数: $REPEAT_COUNT
bfq_limit(same): ${BFQ_LIMIT_SAME_THRESHOLDS[*]}
bfq_limit(dual) pairs: ${BFQ_LIMIT_DUAL_PAIRS[*]}
总配置: $TOTAL_CONFIGS
总测试: $TOTAL_TESTS

RocksDB命令模板:
$ROCKSDB_CMD_TEMPLATE

RocksDB预置命令:
${ROCKSDB_PREP_CMD_TEMPLATE:-<none>}

=== 实时结果 ===
EOF

	echo "配置编号,Background数量,块大小,调度器模式,配置描述,high_threshold,low_threshold,运行次数,fio吞吐量(KB/s),fio吞吐量(MB/s),RocksDB平均延迟(μs),RocksDB真实Get平均延迟(μs),DeviceRead平均延迟(μs),DeviceReadP50(μs),DeviceReadP95(μs),DeviceReadP99(μs),DeviceRead样本数,RocksDB统计项,dbbench_elapsed_s,dbbench_ops_per_sec,完成时间" > "$REALTIME_CSV"

	echo "汇总目录: $BATCH_SUMMARY_DIR"
}

run_rocksdb_prep() {
	local db_path=$1
	local rocksdb_log=$2
	local db_path_quoted
	db_path_quoted=$(printf '%q' "$db_path")
	local prep_cmd=${ROCKSDB_PREP_CMD_TEMPLATE//\{DB_PATH\}/$db_path_quoted}

	mkdir -p "$db_path"
	if [ -n "${ROCKSDB_PREP_CMD_TEMPLATE}" ]; then
		echo "执行RocksDB预置命令: $prep_cmd" | tee -a "$rocksdb_log"
		bash -lc "$prep_cmd" >> "$rocksdb_log" 2>&1
		if [ "$DROP_CACHES_AFTER_PREP" = "true" ]; then
			echo "prep后清理系统缓存(drop_caches)" | tee -a "$rocksdb_log"
			sync
			echo 3 | sudo tee /proc/sys/vm/drop_caches >> "$rocksdb_log" 2>&1
		fi
	fi
}

run_rocksdb_foreground() {
	local db_path=$1
	local rocksdb_log=$2
	local mode=${3:-""}
	local db_path_quoted
	db_path_quoted=$(printf '%q' "$db_path")
	local cmd=${ROCKSDB_CMD_TEMPLATE//\{DB_PATH\}/$db_path_quoted}

	echo "执行RocksDB: $cmd" | tee -a "$rocksdb_log"
	bash -lc "exec $cmd" >> "$rocksdb_log" 2>&1 &
	local rocksdb_pid=$!
	CURRENT_ROCKSDB_PID=$rocksdb_pid

	sudo ionice -c1 -n0 -p "$rocksdb_pid" >> "$rocksdb_log" 2>&1 || true
	start_dbbench_progress_monitor "$rocksdb_pid" "$rocksdb_log"

	local should_override="false"
	if [ "$ENABLE_FOREGROUND_IOPRIO_OVERRIDE" = "true" ] && [[ "$mode" == bfq* ]]; then
		# bfq 与 bfq_limit* 都启用前台全线程 ioprio 覆盖，保证口径一致
		should_override="true"
	fi

	local target_pid="$rocksdb_pid"
	local target_name=""
	local target_cmdline=""
	log_override_target_snapshot() {
		local phase=$1
		local pid=$2
		echo "[override-$phase] pid=$pid" | tee -a "$rocksdb_log"
		ps -fp "$pid" 2>&1 | tee -a "$rocksdb_log" || echo "[override-$phase] ps: pid not found" | tee -a "$rocksdb_log"
		if [ -r "/proc/$pid/cmdline" ]; then
			local cmdline
			cmdline=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)
			echo "[override-$phase] cmdline=${cmdline:-<empty>}" | tee -a "$rocksdb_log"
		else
			echo "[override-$phase] /proc/$pid/cmdline unavailable" | tee -a "$rocksdb_log"
		fi
		if [ -L "/proc/$pid/exe" ]; then
			echo "[override-$phase] exe=$(readlink -f "/proc/$pid/exe" 2>/dev/null)" | tee -a "$rocksdb_log"
		else
			echo "[override-$phase] /proc/$pid/exe unavailable" | tee -a "$rocksdb_log"
		fi
	}
	resolve_override_target_pid() {
		local pid=$1
		local p c current child
		local -a queue
		local qidx=0
		queue=("$pid")

		# 递归遍历后代进程，兼容 "sudo ionice db_bench" 这类多层包装启动
		while [ "$qidx" -lt "${#queue[@]}" ]; do
			current=${queue[$qidx]}
			qidx=$((qidx + 1))

			p=$(ps -p "$current" -o comm= 2>/dev/null | awk '{print $1}')
			c=""
			if [ -r "/proc/$current/cmdline" ]; then
				c=$(tr '\0' ' ' < "/proc/$current/cmdline" 2>/dev/null || true)
			fi
			if { [ -n "$p" ] && [[ "$p" == *db_bench* ]]; } || [[ "$c" == *db_bench* ]]; then
				echo "$current"
				return
			fi

			while IFS= read -r child; do
				[ -n "$child" ] || continue
				queue+=("$child")
			done < <(ps --ppid "$current" -o pid= 2>/dev/null)
		done

		# 保底回退: 未找到时仍返回原pid，保持脚本行为可解释
		echo "$pid"
	}
	apply_override_to_all_threads() {
		local pid=$1
		local pass=$2
		local task_dir="/proc/$pid/task"
		local tid rc ok fail
		ok=0
		fail=0

		if [ ! -d "$task_dir" ]; then
			echo "[override-pass$pass] task目录不存在: $task_dir" | tee -a "$rocksdb_log"
			return 1
		fi

		echo "[override-pass$pass] 开始覆盖所有线程 ioprio (pid=$pid)" | tee -a "$rocksdb_log"
		for t in "$task_dir"/*; do
			[ -e "$t" ] || continue
			tid=${t##*/}
			./ioprio_override "$tid" >> "$rocksdb_log" 2>&1
			rc=$?
			if [ "$rc" -eq 0 ]; then
				ok=$((ok + 1))
				echo "[override-pass$pass] tid=$tid rc=0" | tee -a "$rocksdb_log"
			else
				fail=$((fail + 1))
				echo "[override-pass$pass] tid=$tid rc=$rc" | tee -a "$rocksdb_log"
			fi
		done
		echo "[override-pass$pass] 线程覆盖完成: ok=$ok fail=$fail" | tee -a "$rocksdb_log"
		if [ "$ok" -gt 0 ] && [ "$fail" -eq 0 ]; then
			return 0
		fi
		return 1
	}

	# timeout 包装场景下，子进程可能稍后出现；重试短窗口确保命中真实 db_bench
	local try
	for try in $(seq 1 20); do
		target_pid=$(resolve_override_target_pid "$rocksdb_pid")
		target_name=$(ps -p "$target_pid" -o comm= 2>/dev/null | awk '{print $1}')
		target_cmdline=""
		if [ -r "/proc/$target_pid/cmdline" ]; then
			target_cmdline=$(tr '\0' ' ' < "/proc/$target_pid/cmdline" 2>/dev/null || true)
		fi
		if [[ "$target_name" == *db_bench* ]] || [[ "$target_cmdline" == *db_bench* ]]; then
			break
		fi
		sleep 0.1
	done
	log_override_target_snapshot "resolved" "$target_pid"

	if [ "$should_override" = "true" ] && [ -x "./ioprio_override" ]; then
		sleep 1
		if kill -0 "$target_pid" >/dev/null 2>&1; then
			if [[ "$target_name" == *db_bench* ]] || [[ "$target_cmdline" == *db_bench* ]]; then
				echo "调用优先级覆盖接口(全线程): target_pid=$target_pid (comm=$target_name)" | tee -a "$rocksdb_log"
				apply_override_to_all_threads "$target_pid" 1 || true
				# 二次覆盖，尽量覆盖刚创建的工作线程
				sleep 0.2
				apply_override_to_all_threads "$target_pid" 2 || true
				log_override_target_snapshot "after_call" "$target_pid"
			else
				echo "警告: override目标并非db_bench(pid=$target_pid, comm=${target_name:-unknown})，跳过覆盖" | tee -a "$rocksdb_log"
			fi
		else
			echo "警告: 前台进程已退出，未执行优先级覆盖" | tee -a "$rocksdb_log"
		fi
	elif [ "$should_override" = "true" ]; then
		echo "警告: 未找到可执行 ./ioprio_override，跳过优先级覆盖" | tee -a "$rocksdb_log"
	elif [ "$ENABLE_FOREGROUND_IOPRIO_OVERRIDE" = "true" ]; then
		echo "当前模式($mode)不启用前台优先级覆盖" | tee -a "$rocksdb_log"
	fi

	wait "$rocksdb_pid"
	local rc=$?
	stop_dbbench_progress_monitor
	CURRENT_ROCKSDB_PID=""
	return $rc
}

extract_fio_total_kbps() {
	local json_file=$1
	local total=0
	local clean_json

	if [ -f "$json_file" ]; then
		# fio 在被信号中断时，文件首行可能是: "fio: terminating on signal ..."
		# 这会导致 jq 直接解析失败。这里从首个 '{' 开始提取纯 JSON。
		clean_json=$(sed -n '/^{/,$p' "$json_file")

		if command -v jq >/dev/null 2>&1; then
			total=$(printf '%s\n' "$clean_json" | jq -r '[.jobs[] | ((.read.bw // 0) + (.write.bw // 0))] | add // 0 | floor' 2>/dev/null)
			total=${total:-0}
		else
			total=$(printf '%s\n' "$clean_json" | grep -Eo '"bw"[[:space:]]*:[[:space:]]*[0-9.]+' | awk -F: '{gsub(/[[:space:]]/,"",$2); s+=$2} END{printf "%.0f", s+0}')
			total=${total:-0}
		fi
	fi

	echo "$total"
}

extract_rocksdb_latency_us() {
	local rocksdb_log=$1
	local latency

	# db_bench 优先读取前台 readrandom 汇总，避免误取 prep(fillrandom) 的统计
	latency=$(grep -E 'readrandom[[:space:]]*:' "$rocksdb_log" 2>/dev/null | tail -n1 | grep -Eo '[0-9]+(\.[0-9]+)?[[:space:]]+micros/op' | awk '{print $1}')

	# YCSB 输出: [READ], AverageLatency(us), 123.45
	if [ -z "$latency" ]; then
		latency=$(grep -E 'AverageLatency\(us\)' "$rocksdb_log" 2>/dev/null | tail -n1 | awk -F',' '{gsub(/^[ \t]+|[ \t]+$/, "", $3); print $3}')
	fi

	if [ -z "$latency" ]; then
		latency="N/A"
	fi
	echo "$latency"
}

extract_real_get_latency_us() {
	local rocksdb_log=$1
	local latency

	# 解析 db_bench 自定义输出:
	# Real DB::Get latency: avg 123.456 us min 10 us max 999 us count 1000
	latency=$(grep -E 'Real DB::Get latency:' "$rocksdb_log" 2>/dev/null |
		tail -n1 |
		sed -n 's/.*avg[[:space:]]\{1,\}\([0-9.]\{1,\}\)[[:space:]]\{1,\}us.*/\1/p')

	if [ -z "$latency" ]; then
		latency="N/A"
	fi
	echo "$latency"
}

extract_device_read_field() {
	local rocksdb_log=$1
	local field=$2
	local line value

	line=$(grep -E 'Device read latency:' "$rocksdb_log" 2>/dev/null | tail -n1)
	if [ -z "$line" ]; then
		echo "N/A"
		return
	fi

	case "$field" in
		avg)
			value=$(printf '%s\n' "$line" | sed -n 's/.*avg[[:space:]]\{1,\}\([0-9.]\{1,\}\)[[:space:]]\{1,\}us.*/\1/p')
			;;
		p50)
			value=$(printf '%s\n' "$line" | sed -n 's/.*p50[[:space:]]\{1,\}\([0-9]\{1,\}\)[[:space:]]\{1,\}us.*/\1/p')
			;;
		p95)
			value=$(printf '%s\n' "$line" | sed -n 's/.*p95[[:space:]]\{1,\}\([0-9]\{1,\}\)[[:space:]]\{1,\}us.*/\1/p')
			;;
		p99)
			value=$(printf '%s\n' "$line" | sed -n 's/.*p99[[:space:]]\{1,\}\([0-9]\{1,\}\)[[:space:]]\{1,\}us.*/\1/p')
			;;
		count)
			value=$(printf '%s\n' "$line" | sed -n 's/.*count[[:space:]]\{1,\}\([0-9]\{1,\}\).*/\1/p')
			;;
		*)
			value=""
			;;
	esac

	if [ -z "$value" ]; then
		echo "N/A"
	else
		echo "$value"
	fi
}

extract_rocksdb_stat_label() {
	local rocksdb_log=$1
	local label

	# db_bench: 优先使用 readrandom 标签
	label=$(grep -E '^readrandom[[:space:]]*:.*micros/op' "$rocksdb_log" 2>/dev/null | tail -n1 | awk -F':' '{print $1}' | xargs)
	if [ -z "$label" ]; then
		# 回退：任意 db_bench 指标
		label=$(grep -E '^[A-Za-z0-9_,.-]+[[:space:]]*:.*micros/op' "$rocksdb_log" 2>/dev/null | tail -n1 | awk -F':' '{print $1}' | xargs)
	fi

	# YCSB: [READ], AverageLatency(us), xxx
	if [ -z "$label" ]; then
		label=$(grep -E 'AverageLatency\(us\)' "$rocksdb_log" 2>/dev/null | tail -n1 | awk -F',' '{gsub(/^[ \t]+|[ \t]+$/, "", $1); print $1" AverageLatency(us)"}')
	fi

	if [ -z "$label" ]; then
		label="unknown"
	fi
	echo "$label"
}

extract_rocksdb_ops_per_sec() {
	local rocksdb_log=$1
	local ops

	# db_bench 优先读取 readrandom 的 ops/sec，避免误取 prep(fillrandom)
	ops=$(grep -E 'readrandom[[:space:]]*:' "$rocksdb_log" 2>/dev/null | tail -n1 | grep -Eo '[0-9]+(\.[0-9]+)?[[:space:]]+ops/sec' | awk '{print $1}')
	if [ -z "$ops" ]; then
		# 回退：任意 ops/sec
		ops=$(grep -Eo '[0-9]+(\.[0-9]+)?[[:space:]]+ops/sec' "$rocksdb_log" 2>/dev/null | tail -n1 | awk '{print $1}')
	fi

	if [ -z "$ops" ]; then
		ops="N/A"
	fi
	echo "$ops"
}

update_aggregate() {
	local key=$1
	local fio_kbps=$2
	local lat_us=$3

	CNT_TOTAL[$key]=$(( ${CNT_TOTAL[$key]:-0} + 1 ))
	SUM_FIO_KBPS[$key]=$(( ${SUM_FIO_KBPS[$key]:-0} + fio_kbps ))

	if [[ "$lat_us" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
		CNT_LAT[$key]=$(( ${CNT_LAT[$key]:-0} + 1 ))
		SUM_LAT_US[$key]=$(awk -v a="${SUM_LAT_US[$key]:-0}" -v b="$lat_us" 'BEGIN{printf "%.6f", a+b}')
	fi
}

run_single_test() {
	local mode=$1
	local bg_count=$2
	local block_size=$3
	local run_number=$4
	local config_number=$5
	local high=${6:-""}
	local low=${7:-""}

	local timestamp
	timestamp=$(date +%H%M%S)

	local config_desc
	config_desc=$(get_config_description "$mode" "$high" "$low")

	local test_dir="$RESULT_ROOT/bg${bg_count}_${block_size}/${config_desc}_r${run_number}_${timestamp}"
	mkdir -p "$test_dir"

	local fio_cfg="$test_dir/sustained.fio"
	local fio_json="$test_dir/fio.json"
	local fio_log="$test_dir/fio.log"
	local rocksdb_log="$test_dir/rocksdb.log"
	local db_path="$ROCKSDB_DB_BASE/${config_desc}_r${run_number}_${timestamp}"

	echo ""
	echo "=========================================="
	echo "配置 $config_number / 第 $run_number 次"
	echo "模式: $config_desc"
	echo "Background: $bg_count, 块大小: $block_size"
	echo "=========================================="

	preflight_reset "$mode" "$high" "$low"
	setup_scheduler "$mode" "$high" "$low"
	cleanup_system_cache

	rm -rf "$db_path"
	mkdir -p "$db_path"
	: > "$rocksdb_log"

	echo "执行RocksDB预置阶段..."
	run_rocksdb_prep "$db_path" "$rocksdb_log"

	generate_sustained_fio "$bg_count" "$block_size" "$fio_cfg"

	echo "启动fio后台负载..."
	sudo fio "$fio_cfg" --output="$fio_json" --output-format=json > "$fio_log" 2>&1 &
	local fio_pid=$!
	CURRENT_FIO_PID=$fio_pid
	start_queue_bytes_monitor "$mode" "$rocksdb_log"

	sleep "$ROCKSDB_START_DELAY_SECONDS"

	echo "启动RocksDB前台负载..."
	local dbbench_start_ts dbbench_end_ts dbbench_elapsed_s dbbench_ops_per_sec
	dbbench_start_ts=$(date +%s.%N)
	if ! run_rocksdb_foreground "$db_path" "$rocksdb_log" "$mode"; then
		echo "警告: RocksDB命令退出码非0，详见: $rocksdb_log"
	fi
	dbbench_end_ts=$(date +%s.%N)
	dbbench_elapsed_s=$(awk -v s="$dbbench_start_ts" -v e="$dbbench_end_ts" 'BEGIN{d=e-s; if (d<0) d=0; printf "%.3f", d}')
	dbbench_ops_per_sec=$(extract_rocksdb_ops_per_sec "$rocksdb_log")
	if [ "$dbbench_ops_per_sec" = "N/A" ] && awk -v d="$dbbench_elapsed_s" 'BEGIN{exit !(d>0)}'; then
		if awk -v r="$ROCKSDB_READS" 'BEGIN{exit !(r>0)}'; then
			dbbench_ops_per_sec=$(awk -v reads="$ROCKSDB_READS" -v d="$dbbench_elapsed_s" 'BEGIN{printf "%.2f", reads/d}')
		fi
	fi

	if kill -0 "$fio_pid" >/dev/null 2>&1; then
		sudo kill -INT "$fio_pid" >/dev/null 2>&1 || true
	fi
	wait "$fio_pid" 2>/dev/null || true
	CURRENT_FIO_PID=""
	stop_queue_bytes_monitor "${QUEUE_MONITOR_PID:-}"

	local fio_kbps
	fio_kbps=$(extract_fio_total_kbps "$fio_json")
	local fio_mbps
	fio_mbps=$(awk -v v="$fio_kbps" 'BEGIN{printf "%.2f", v/1024}')

	local rocksdb_lat
	rocksdb_lat=$(extract_rocksdb_latency_us "$rocksdb_log")
	local rocksdb_real_get_lat
	rocksdb_real_get_lat=$(extract_real_get_latency_us "$rocksdb_log")
	local device_read_avg_us device_read_p50_us device_read_p95_us device_read_p99_us device_read_count
	device_read_avg_us=$(extract_device_read_field "$rocksdb_log" avg)
	device_read_p50_us=$(extract_device_read_field "$rocksdb_log" p50)
	device_read_p95_us=$(extract_device_read_field "$rocksdb_log" p95)
	device_read_p99_us=$(extract_device_read_field "$rocksdb_log" p99)
	device_read_count=$(extract_device_read_field "$rocksdb_log" count)
	local rocksdb_label
	rocksdb_label=$(extract_rocksdb_stat_label "$rocksdb_log")

	local complete_time
	complete_time=$(date)

	echo "$config_number,$bg_count,$block_size,$mode,$config_desc,${high:-N/A},${low:-N/A},$run_number,$fio_kbps,$fio_mbps,$rocksdb_lat,$rocksdb_real_get_lat,$device_read_avg_us,$device_read_p50_us,$device_read_p95_us,$device_read_p99_us,$device_read_count,$rocksdb_label,$dbbench_elapsed_s,$dbbench_ops_per_sec,$complete_time" >> "$REALTIME_CSV"

	cat >> "$REALTIME_REPORT" << EOF

--- 测试完成 ---
配置编号: $config_number
模式: $config_desc (run=$run_number)
fio吞吐量: ${fio_kbps} KB/s (${fio_mbps} MB/s)
RocksDB平均延迟: ${rocksdb_lat} μs (统计项: $rocksdb_label)
RocksDB真实Get延迟: ${rocksdb_real_get_lat} μs
DeviceRead延迟: avg=${device_read_avg_us} μs p50=${device_read_p50_us} μs p95=${device_read_p95_us} μs p99=${device_read_p99_us} μs count=${device_read_count}
db_bench耗时: ${dbbench_elapsed_s} s
db_bench吞吐: ${dbbench_ops_per_sec} ops/s
完成时间: $complete_time
目录: $test_dir
EOF

	local key="bg${bg_count}|bs${block_size}|${mode}|${high:-N}|${low:-N}"
	update_aggregate "$key" "$fio_kbps" "$rocksdb_real_get_lat"

	if [ "$AUTO_CLEAN_INTERMEDIATE" = "true" ]; then
		rm -f "$fio_cfg" "$fio_log" 2>/dev/null
	fi

	echo "✓ 完成: fio=${fio_mbps} MB/s, RocksDB_avg=${rocksdb_lat} μs, Real_Get_avg=${rocksdb_real_get_lat} μs, DeviceRead_avg=${device_read_avg_us} μs(p95=${device_read_p95_us},p99=${device_read_p99_us},n=${device_read_count}), dbbench_elapsed=${dbbench_elapsed_s}s, dbbench_ops=${dbbench_ops_per_sec} ops/s"
}

write_final_summary() {
	local out_csv="$BATCH_SUMMARY_DIR/final_summary.csv"
	echo "Background数量,块大小,调度器模式,high_threshold,low_threshold,样本数,fio平均吞吐量(KB/s),fio平均吞吐量(MB/s),RocksDB平均延迟(μs)" > "$out_csv"

	local key
	for key in "${!CNT_TOTAL[@]}"; do
		local bg bs mode high low
		IFS='|' read -r bg bs mode high low <<< "$key"

		local n=${CNT_TOTAL[$key]:-0}
		[ "$n" -gt 0 ] || continue

		local avg_fio_kbps=$(( ${SUM_FIO_KBPS[$key]:-0} / n ))
		local avg_fio_mbps
		avg_fio_mbps=$(awk -v v="$avg_fio_kbps" 'BEGIN{printf "%.2f", v/1024}')

		local avg_lat="N/A"
		local n_lat=${CNT_LAT[$key]:-0}
		if [ "$n_lat" -gt 0 ]; then
			avg_lat=$(awk -v s="${SUM_LAT_US[$key]:-0}" -v n="$n_lat" 'BEGIN{printf "%.2f", s/n}')
		fi

		echo "${bg#bg},${bs#bs},$mode,${high/N/N/A},${low/N/N/A},$n,$avg_fio_kbps,$avg_fio_mbps,$avg_lat" >> "$out_csv"
	done

	echo ""
	echo "=========================================="
	echo "测试完成，汇总文件:"
	echo "- 实时报告: $REALTIME_REPORT"
	echo "- 实时CSV: $REALTIME_CSV"
	echo "- 最终汇总: $out_csv"
	echo "=========================================="
}

main() {
	if [ ! -x "$ROCKSDB_BIN" ]; then
		echo "错误: RocksDB二进制不存在或不可执行: $ROCKSDB_BIN"
		echo "请设置环境变量 ROCKSDB_BIN 指向可执行的 db_bench"
		exit 1
	fi

	strip_unsupported_rocksdb_flags

	if [[ "$ROCKSDB_DB_BASE" != "$ROCKSDB_MOUNT_POINT"* ]]; then
		echo "警告: ROCKSDB_DB_BASE($ROCKSDB_DB_BASE) 不在挂载点($ROCKSDB_MOUNT_POINT)下"
		echo "建议将 ROCKSDB_DB_BASE 放在挂载点目录内。"
	fi

	prepare_filesystem_for_rocksdb

	cleanup_old_results
	initialize_summary_files

	mkdir -p "$RESULT_ROOT"

	local config_idx=0
	local run=0
	local bg
	local bs
	local scheduler
	local scheduler_configs=()
	read -r -a scheduler_configs <<< "$(get_all_scheduler_configs)"

	# 轮次优先：每轮跑完所有组合，再进入下一轮
	for ((run=1; run<=REPEAT_COUNT; run++)); do
		config_idx=0
		for bg in "${BACKGROUND_COUNTS[@]}"; do
			for bs in "${BLOCK_SIZES[@]}"; do
				for scheduler in "${scheduler_configs[@]}"; do
					IFS=':' read -r mode high low <<< "$scheduler"
					config_idx=$((config_idx + 1))
					run_single_test "$mode" "$bg" "$bs" "$run" "$config_idx" "$high" "$low"
				done
			done
		done
	done

	write_final_summary
}

main "$@"

