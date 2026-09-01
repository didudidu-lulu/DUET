#!/bin/bash

# 配置参数
BACKGROUND_COUNTS=(8)
BLOCK_SIZES=("1M")

# 调度器配置 - 将duet分为两种模式
SCHEDULERS=("none" "bfq" "duet_same")

# 清理配置
AUTO_CLEAN_INTERMEDIATE=true  # 自动清理中间文件
KEEP_DETAILED_LOGS=false     # 是否保留详细日志
CLEAN_SYSTEM_CACHE=true      # 是否清理系统缓存

# duet_same模式：high_threshold和low_threshold相同值
DUET_SAME_THRESHOLDS=(4194304)

# duet_dual模式：固定high_threshold，变化low_threshold  
DUET_FIXED_HIGH=4194304
DUET_LOW_THRESHOLDS=(3145728 2097152 1048576)

# 重复次数
REPEAT_COUNT=3

# 动态计算总测试次数
calculate_total_tests() {
    local bg_count=${#BACKGROUND_COUNTS[@]}
    local block_count=${#BLOCK_SIZES[@]}
    local basic_schedulers=2  # 改为0，因为删除了none和bfq
    local duet_same_configs=${#DUET_SAME_THRESHOLDS[@]}
    local duet_dual_configs=${#DUET_LOW_THRESHOLDS[@]}
    
    TOTAL_CONFIGS=$(( bg_count * block_count * (basic_schedulers + duet_same_configs + duet_dual_configs) ))
    TOTAL_TESTS=$(( TOTAL_CONFIGS * REPEAT_COUNT ))
}

calculate_total_tests

echo "=========================================="
echo "        BFQ低延迟批量测试脚本"
echo "=========================================="
echo "调度器配置: ${SCHEDULERS[*]}"
echo "Background数量配置: ${BACKGROUND_COUNTS[*]}"
echo "块大小配置: ${BLOCK_SIZES[*]}"
echo "每个配置重复次数: $REPEAT_COUNT"
echo ""
echo "=== 调度器详细配置 ==="
echo "- none: 无调度器"
echo "- bfq: BFQ调度器 (无threshold限制)"
echo "- duet_same: BFQ + 相同threshold值"
echo "  └── threshold配置: ${DUET_SAME_THRESHOLDS[*]}"
echo "- duet_dual: BFQ + 固定high + 可变low"
echo "  └── 固定high_threshold: $DUET_FIXED_HIGH"
echo "  └── 可变low_threshold: ${DUET_LOW_THRESHOLDS[*]}"
echo ""
echo "总配置组合数: $TOTAL_CONFIGS"
echo "总测试次数: $TOTAL_TESTS"
echo "=========================================="

# 修改设置调度器函数
setup_scheduler() {
    local scheduler_mode=$1
    local high_threshold=${2:-""}
    local low_threshold=${3:-""}
    
    echo "设置调度器模式: $scheduler_mode"
    
    case "$scheduler_mode" in
        "none")
            echo none | sudo tee /sys/block/nvme0n1/queue/scheduler
            echo "✓ 调度器设置为: none"
            ;;
        "bfq")
            echo bfq | sudo tee /sys/block/nvme0n1/queue/scheduler
            ./bdev_set_bytes /dev/nvme0n1 1 2147483647 2147483647
            echo "✓ 调度器设置为: bfq, bdev参数: 2147483647 2147483647"
            ;;
        "duet_same"|"duet_dual")
            echo bfq | sudo tee /sys/block/nvme0n1/queue/scheduler
            if [ -n "$high_threshold" ] && [ -n "$low_threshold" ]; then
                ./bdev_set_bytes /dev/nvme0n1 1 $high_threshold $low_threshold
                echo "✓ 调度器设置为: bfq ($scheduler_mode模式), bdev参数: $high_threshold $low_threshold"
            else
                echo "错误: $scheduler_mode模式需要提供threshold参数"
                exit 1
            fi
            ;;
        *)
            echo "错误: 未知的调度器模式 $scheduler_mode"
            exit 1
            ;;
    esac
    
    # 验证调度器设置
    current_scheduler=$(cat /sys/block/nvme0n1/queue/scheduler | grep -o '\[.*\]' | tr -d '[]')
    echo "当前调度器: $current_scheduler"
}

# 获取所有调度器配置的函数
get_all_scheduler_configs() {
    local configs=()
    
    # 恢复基础调度器
    configs+=("none:::")
    configs+=("bfq:::")
    
    # 添加duet_same配置
    for threshold in "${DUET_SAME_THRESHOLDS[@]}"; do
        configs+=("duet_same:$threshold:$threshold:")
    done
    
    添加duet_dual配置
    for low_threshold in "${DUET_LOW_THRESHOLDS[@]}"; do
        configs+=("duet_dual:$DUET_FIXED_HIGH:$low_threshold:")
    done
    
    echo "${configs[@]}"
}

# 生成配置描述的函数
get_config_description() {
    local scheduler_mode=$1
    local high=$2
    local low=$3
    
    case "$scheduler_mode" in
        "none"|"bfq")
            echo "$scheduler_mode"
            ;;
        "duet_same")
            echo "${scheduler_mode}(${high})"
            ;;
        "duet_dual")
            echo "${scheduler_mode}(${high}/${low})"
            ;;
        *)
            echo "$scheduler_mode"
            ;;
    esac
}

# 生成sustained.fio配置文件
generate_sustained_fio() {
    local bg_count=$1
    local block_size=$2
    local fio_file="sustained.fio"
    
    echo "生成sustained.fio配置: background数量=$bg_count, 块大小=$block_size"
    
    cat > "$fio_file" << EOF
[global]
filename=/dev/nvme0n1
ioengine=libaio
direct=1
time_based
ramp_time=3s
runtime=30s
rw=read
iodepth=4
group_reporting=1

EOF

    # 生成多个background任务
    for ((i=1; i<=bg_count; i++)); do
        cat >> "$fio_file" << EOF
[background_$i]
prioclass=1
prio=7
bs=$block_size
numjobs=1

EOF
    done
    
    echo "✓ 已生成 $fio_file (${bg_count}个background任务，块大小=${block_size})"
}

# 交互式清除旧结果函数
cleanup_old_results() {
    echo "========== 清理旧测试结果 =========="
    
    # 查找旧的结果目录
    OLD_DIRS=""
    if [ -d "results" ]; then
        OLD_DIRS="results"
    fi
    
    # 查找其他旧格式的目录
    OLD_LEGACY_DIRS=$(find . -maxdepth 1 -type d -name "sustained_results_*" -o -name "burst_results_*" -o -name "batch_test_*" 2>/dev/null)
    
    for dir in $OLD_LEGACY_DIRS; do
        if [ -d "$dir" ]; then
            OLD_DIRS="$OLD_DIRS $dir"
        fi
    done
    
    if [ -n "$OLD_DIRS" ]; then
        echo "发现以下旧的测试结果目录："
        total_size=0
        for dir in $OLD_DIRS; do
            size=$(du -sm "$dir" 2>/dev/null | cut -f1)
            echo "  $dir (大小: ${size}MB)"
            total_size=$((total_size + size))
        done
        echo "总计大小: ${total_size}MB"
        echo ""
        
        echo -n "是否删除这些目录？(y/N): "
        read -r response
        
        case "$response" in
            [yY]|[yY][eE][sS])
                echo "正在删除旧结果目录..."
                for dir in $OLD_DIRS; do
                    if [ -d "$dir" ]; then
                        rm -rf "$dir"
                        echo "  ✓ 已删除: $dir"
                    fi
                done
                echo "✓ 已删除所有旧的测试结果目录，释放空间: ${total_size}MB"
                ;;
            *)
                echo "保留现有目录，继续测试..."
                ;;
        esac
    else
        echo "✓ 未发现旧的测试结果目录"
    fi
    
    echo "=================================="
    echo ""
}

# 清理函数
cleanup_intermediate_files() {
    local test_dir=$1
    if [ "$AUTO_CLEAN_INTERMEDIATE" = "true" ]; then
        echo "  清理中间文件: $test_dir"
        # 删除日志文件但保留summary.txt
        rm -f "$test_dir"/*.log 2>/dev/null
        echo "  ✓ 中间文件清理完成"
    fi
}

cleanup_system_cache() {
    if [ "$CLEAN_SYSTEM_CACHE" = "true" ]; then
        echo "  清理系统缓存..."
        sync
        echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null 2>&1
        echo "  ✓ 系统缓存清理完成"
    fi
}

# 深度清理函数
deep_cleanup() {
    echo "进行深度清理..."
    
    # 清理系统缓存
    cleanup_system_cache
    
    # 清理临时文件
    sudo rm -rf /tmp/fio* /tmp/*burst* 2>/dev/null
    sudo rm -f core.* 2>/dev/null
    
    # 清理可能的测试残留进程
    sudo pkill -f burst_task 2>/dev/null || true
    sudo pkill -f fio 2>/dev/null || true
    
    echo "✓ 深度清理完成"
}

# 初始化汇总文件的函数
initialize_summary_files() {
    local timestamp=$(date +%Y%m%d_%H%M%S)
    
    # 创建汇总目录
    BATCH_SUMMARY_DIR="results/summary_${timestamp}"
    mkdir -p "$BATCH_SUMMARY_DIR"
    
    # 全局变量，供其他函数使用
    REALTIME_REPORT="$BATCH_SUMMARY_DIR/realtime_report.txt"
    REALTIME_CSV="$BATCH_SUMMARY_DIR/realtime_data.csv"
    
    # 初始化文件头
    cat > "$REALTIME_REPORT" << EOF
===== BFQ低延迟批量测试实时报告 =====
开始时间: $(date)
设备: /dev/nvme0n1

=== 测试配置 ===
调度器模式: ${SCHEDULERS[*]}
Background数量: ${BACKGROUND_COUNTS[*]}
块大小: ${BLOCK_SIZES[*]}
每个配置重复次数: $REPEAT_COUNT
总配置组合数: $((${#BACKGROUND_COUNTS[@]} * ${#BLOCK_SIZES[@]}))
总测试次数: $TOTAL_TESTS

=== 调度器模式说明 ===
- none: 无调度器
- bfq: BFQ调度器 + bdev_set_bytes 2147483647 2147483647
- duet_same: BFQ调度器 + 相同threshold值
  └── threshold配置: ${DUET_SAME_THRESHOLDS[*]}
- duet_dual: BFQ调度器 + 固定high + 可变low
  └── 固定high: $DUET_FIXED_HIGH, 可变low: ${DUET_LOW_THRESHOLDS[*]}

=== 实时测试结果 ===
(每完成一次测试后实时更新)

EOF

    # 初始化CSV文件头
    echo "配置编号,Background数量,块大小,调度器模式,具体配置,运行次数,Sustained吞吐量,Burst延迟(μs),突发轮次,完成时间" > "$REALTIME_CSV"
    
    echo "实时汇总文件已初始化:"
    echo "- 报告文件: $REALTIME_REPORT"
    echo "- CSV文件: $REALTIME_CSV"
    echo ""
}

# 添加单次测试结果写入函数
write_single_test_result() {
    local config_number=$1
    local bg_count=$2
    local block_size=$3
    local scheduler_mode=$4
    local config_desc=$5
    local run_number=$6
    local sustained=$7
    local latency=$8
    local rounds=$9
    local completion_time=$(date)
    
    # 立即写入CSV
    echo "$config_number,$bg_count,$block_size,$scheduler_mode,$config_desc,$run_number,$sustained,$latency,$rounds,$completion_time" >> "$REALTIME_CSV"
    
    # 同时写入文本报告
    cat >> "$REALTIME_REPORT" << EOF

--- 测试完成 ---
配置组合: $config_number, Background: $bg_count, 块大小: $block_size
调度器模式: $scheduler_mode ($config_desc), 第 $run_number 次测试
完成时间: $completion_time
Sustained吞吐量: $sustained
Burst延迟: $latency μs
突发轮次: $rounds
EOF
    
    echo "✓ 测试结果已立即写入汇总文件"
}

# 修复 run_single_test 函数中的 write_single_test_result 调用
run_single_test() {
    local scheduler_mode=$1
    local bg_count=$2
    local block_size=$3
    local run_number=$4
    local config_number=$5
    local high_threshold=${6:-""}
    local low_threshold=${7:-""}
    local timestamp=$(date +%H%M%S)
    
    # 构建配置描述和测试标识
    local config_desc=$(get_config_description $scheduler_mode $high_threshold $low_threshold)
    local test_id="$config_desc"
    
    echo ""
    echo "=========================================="
    echo "配置 $config_number - 第 $run_number 次测试"
    echo "调度器模式: $scheduler_mode"
    echo "具体配置: $config_desc"
    echo "Background: $bg_count, 块大小: $block_size"
    echo "=========================================="
    
    # 创建结果目录
    MAIN_RESULT_DIR="results"
    CONFIG_DIR="$MAIN_RESULT_DIR/bg${bg_count}_${block_size}"
    TEST_DIR="$CONFIG_DIR/${test_id}_r${run_number}_${timestamp}"
    
    mkdir -p "$TEST_DIR"
    
    SUSTAINED_LOG="$TEST_DIR/sustained.log"
    BURST_LOG="$TEST_DIR/burst.log"

    # 设置调度器和参数
    if [[ "$scheduler_mode" == "duet_"* ]]; then
        setup_scheduler $scheduler_mode $high_threshold $low_threshold
    else
        setup_scheduler $scheduler_mode
    fi

    # 生成当前配置的sustained.fio文件
    generate_sustained_fio $bg_count $block_size

    echo "同时启动后台任务和突发任务..."

    # 启动后台持续任务 - 减少输出
    echo "启动后台持续任务..."
    sudo fio sustained.fio 2>/dev/null | grep -E "(READ:|bw=|IOPS=)" > "$SUSTAINED_LOG" &
    BACKGROUND_PID=$!

    # 启动突发任务 - 重定向到null减少输出
    echo "启动突发任务..."
    sudo ionice -c1 -n0 ./burst_task 2>&1 | grep -E "(Average latency|=== Burst Round)" > "$BURST_LOG" &  # 只保留关键信息

    # 等待突发任务完全启动
    sleep 1

    # 获取真正的burst_task进程PID
    BURST_PID=$(ps aux | grep burst_task | tail -n2 | head -n1 | awk '{print $2}')

    # 应用优先级覆盖
    echo "突发任务PID: $BURST_PID"
    ./ioprio_override $BURST_PID

    echo ""
    echo "等待任务完全结束..."
    wait $BACKGROUND_PID 2>/dev/null

    # 后台任务结束后，杀死突发任务
    sudo pkill -f burst_task
    wait $BURST_PID 2>/dev/null

    echo "配置 $config_number - 第 $run_number 次测试执行完成，开始分析结果..."

    # 分析sustained workload的总吞吐量
    SUSTAINED_THROUGHPUT=""
    SUSTAINED_IOPS=""

    if [ -f "$SUSTAINED_LOG" ]; then
        # 尝试从不同位置提取throughput和IOPS
        RAW_THROUGHPUT=$(grep "READ: bw=" "$SUSTAINED_LOG" | tail -1 | sed -n 's/.*READ: bw=\([0-9.]*[KMGT]*iB\/s\).*/\1/p')
        SUSTAINED_IOPS=$(grep "read: IOPS=" "$SUSTAINED_LOG" | tail -1 | sed -n 's/.*IOPS=\([0-9.]*[k]*\).*/\1/p')
        
        # 转换单位为GB/s
        if [ ! -z "$RAW_THROUGHPUT" ]; then
            if [[ "$RAW_THROUGHPUT" =~ ([0-9.]+)([KMGT]?)iB/s ]]; then
                VALUE="${BASH_REMATCH[1]}"
                UNIT="${BASH_REMATCH[2]}"
                
                case "$UNIT" in
                    "K")
                        SUSTAINED_THROUGHPUT=$(echo "scale=3; $VALUE * 1024 / 1000000000" | bc -l)GB/s
                        ;;
                    "M")
                        THROUGHPUT_VALUE=$(echo "scale=3; $VALUE * 1048576 / 1000000000" | bc -l)
                        # 确保添加前导0
                        if [[ "$THROUGHPUT_VALUE" =~ ^\. ]]; then
                            THROUGHPUT_VALUE="0$THROUGHPUT_VALUE"
                        fi
                        SUSTAINED_THROUGHPUT="${THROUGHPUT_VALUE}GB/s"
                        ;;
                    "G")
                        SUSTAINED_THROUGHPUT=$(echo "scale=3; $VALUE * 1073741824 / 1000000000" | bc -l)GB/s
                        ;;
                    "T")
                        SUSTAINED_THROUGHPUT=$(echo "scale=3; $VALUE * 1099511627776 / 1000000000" | bc -l)GB/s
                        ;;
                    *)
                        SUSTAINED_THROUGHPUT=$(echo "scale=3; $VALUE / 1000000000" | bc -l)GB/s
                        ;;
                esac
            fi
        fi
        
        # 如果第一种方法失败，尝试JSON格式或手动计算
        if [ -z "$SUSTAINED_THROUGHPUT" ]; then
            # [保持原有的其他解析方法...]
            SUSTAINED_THROUGHPUT="解析失败"
        fi
        
        if [ -z "$SUSTAINED_IOPS" ]; then
            SUSTAINED_IOPS="解析失败"
        fi
    else
        SUSTAINED_THROUGHPUT="N/A"
        SUSTAINED_IOPS="N/A"
    fi

    # 分析burst_task的平均延迟
    OVERALL_AVG_LATENCY=""
    TOTAL_BURST_ROUNDS=0

    if [ -f "$BURST_LOG" ]; then
        TOTAL_BURST_ROUNDS=$(grep "=== Burst Round #" "$BURST_LOG" | wc -l)
        
        # 提取每轮的平均延迟并计算总体平均值
        TOTAL_LATENCY_SUM=0
        VALID_ROUND_COUNT=0
        
        while IFS= read -r line; do
            if [[ "$line" =~ Average\ latency:\ ([0-9.]+)\ μs ]]; then
                ROUND_LATENCY="${BASH_REMATCH[1]}"
                TOTAL_LATENCY_SUM=$(echo "$TOTAL_LATENCY_SUM + $ROUND_LATENCY" | bc -l 2>/dev/null || echo "$TOTAL_LATENCY_SUM")
                VALID_ROUND_COUNT=$((VALID_ROUND_COUNT + 1))
            fi
        done < "$BURST_LOG"
        
        if [ $VALID_ROUND_COUNT -gt 0 ]; then
            OVERALL_AVG_LATENCY=$(echo "scale=2; $TOTAL_LATENCY_SUM / $VALID_ROUND_COUNT" | bc -l)
        fi
    else
        OVERALL_AVG_LATENCY="N/A"
    fi

    # 生成简单的测试摘要文件
    cat > "$TEST_DIR/summary.txt" << EOF
测试配置: $config_desc, bg$bg_count, $block_size, run$run_number
时间: $(date)
调度器模式: $scheduler_mode
Sustained吞吐量: $SUSTAINED_THROUGHPUT
Burst平均延迟: $OVERALL_AVG_LATENCY μs
突发轮次: $TOTAL_BURST_ROUNDS
EOF

    echo "配置 $config_number - 第 $run_number 次测试结果:"
    echo "- 调度器模式: $scheduler_mode ($config_desc)"
    echo "- Background: $bg_count, 块大小: $block_size"
    echo "- Sustained吞吐量: $SUSTAINED_THROUGHPUT"
    echo "- Burst平均延迟: $OVERALL_AVG_LATENCY μs"
    echo "- 结果保存到: $TEST_DIR"
    
    # 返回结果（使用config_desc作为键）
    CONFIG_KEY="${config_desc}_${bg_count}_${block_size}_${run_number}"
    RESULTS_CONFIG[$CONFIG_KEY]="$config_desc,$bg_count,$block_size"
    RESULTS_SUSTAINED[$CONFIG_KEY]=$SUSTAINED_THROUGHPUT
    RESULTS_LATENCY[$CONFIG_KEY]=$OVERALL_AVG_LATENCY
    RESULTS_ROUNDS[$CONFIG_KEY]=$TOTAL_BURST_ROUNDS
    
    # 修复：正确的参数传递
    write_single_test_result $config_number $bg_count $block_size $scheduler_mode "$config_desc" $run_number $SUSTAINED_THROUGHPUT $OVERALL_AVG_LATENCY $TOTAL_BURST_ROUNDS
    
    # 调用清理函数
    cleanup_intermediate_files "$TEST_DIR"
    cleanup_system_cache
    
    echo "等待系统稳定..."
    sleep 3
}

# 主程序开始
# 在脚本开始时调用清理函数
cleanup_old_results

make

gcc -o burst_task burst_task.c -laio

# *** 重要：只在开始时调用一次 initialize_summary_files ***
initialize_summary_files

# 声明关联数组存储结果
declare -A RESULTS_CONFIG
declare -A RESULTS_SUSTAINED
declare -A RESULTS_LATENCY
declare -A RESULTS_ROUNDS

echo ""
echo "开始批量测试..."

# 执行批量测试 - 循环结构：每轮测试所有调度器一次
config_counter=1
total_test_counter=1

# 修改主程序循环部分
for bg_count in "${BACKGROUND_COUNTS[@]}"; do
    for block_size in "${BLOCK_SIZES[@]}"; do
        echo ""
        echo "=========================================="
        echo "开始测试组合: Background=$bg_count, 块大小=$block_size"
        echo "将进行 $REPEAT_COUNT 轮测试，每轮测试所有调度器配置"
        echo "=========================================="
        
        # 获取所有调度器配置 - 修复：使用正确的函数
        all_scheduler_configs=($(get_all_scheduler_configs))
        
        echo "本组合将测试 ${#all_scheduler_configs[@]} 种调度器配置:"
        for config in "${all_scheduler_configs[@]}"; do
            IFS=':' read -r scheduler_mode high low _ <<< "$config"
            config_desc=$(get_config_description $scheduler_mode $high $low)
            echo "  - $config_desc"
        done
        
        # 初始化运行次数计数器
        declare -A scheduler_run_count
        for config in "${all_scheduler_configs[@]}"; do
            scheduler_run_count[$config]=0
        done
        
        # 进行 REPEAT_COUNT 轮测试
        for round in $(seq 1 $REPEAT_COUNT); do
            echo ""
            echo "=========================================="
            echo "配置组合 $config_counter - 第 $round 轮测试"
            echo "Background=$bg_count, 块大小=$block_size"
            echo "本轮将依次测试所有调度器配置"
            echo "=========================================="
            
            # 每轮依次测试所有调度器配置
            for config in "${all_scheduler_configs[@]}"; do
                IFS=':' read -r scheduler_mode high low _ <<< "$config"
                
                scheduler_run_count[$config]=$((scheduler_run_count[$config] + 1))
                current_run=${scheduler_run_count[$config]}
                
                config_desc=$(get_config_description $scheduler_mode $high $low)
                
                echo ""
                echo "=========================================="
                echo "第 $round 轮 - 调度器配置: $config_desc (第 $current_run 次)"
                echo "Background数量: $bg_count, 块大小: $block_size"
                echo "=========================================="
                
                echo "执行测试 $total_test_counter/$TOTAL_TESTS"
                echo "配置: $config_desc + bg$bg_count + $block_size - 第 $current_run 次"
                
                # 修复：统一的条件判断和函数调用
                if [[ "$scheduler_mode" == "duet_"* ]]; then
                    run_single_test $scheduler_mode $bg_count $block_size $current_run $config_counter $high $low
                else
                    run_single_test $scheduler_mode $bg_count $block_size $current_run $config_counter
                fi
                
                total_test_counter=$((total_test_counter + 1))
                
                echo "调度器配置测试完成，等待系统稳定..."
                sleep 5
            done
            
            echo ""
            echo "第 $round 轮测试完成，已测试所有调度器配置一次"
            if [ $round -lt $REPEAT_COUNT ]; then
                echo "等待系统稳定后开始下一轮..."
                sleep 5
            fi
        done
        
        # 显示当前配置组合的测试总结
        echo ""
        echo "=========================================="
        echo "配置组合 $config_counter 测试完成总结:"
        echo "Background=$bg_count, 块大小=$block_size"
        for config in "${all_scheduler_configs[@]}"; do
            IFS=':' read -r scheduler_mode high low _ <<< "$config"
            config_desc=$(get_config_description $scheduler_mode $high $low)
            echo "- $config_desc: ${scheduler_run_count[$config]} 次测试"
        done
        echo "=========================================="
        
        config_counter=$((config_counter + 1))
        
        if [ $config_counter -le $((${#BACKGROUND_COUNTS[@]} * ${#BLOCK_SIZES[@]})) ]; then
            echo ""
            echo "等待系统稳定后进行下一个配置组合..."
            sleep 10
        fi
        
        # 清理计数器
        unset scheduler_run_count
    done
done

# 完成最终报告
cat >> "$REALTIME_REPORT" << EOF

=== 测试完成 ===
结束时间: $(date)
总共完成了 $TOTAL_TESTS 次独立测试
所有配置组合: $((config_counter - 1))

测试顺序说明：
1. 对于每个 (background数量, 块大小) 组合
2. 进行 $REPEAT_COUNT 轮测试
3. 每轮依次测试 none → bfq → duet_same → duet_dual 调度器
4. 完成后立即写入汇总文件，然后进行下一个配置组合

数据文件位置:
- 详细报告: $REALTIME_REPORT
- CSV数据: $REALTIME_CSV
- 原始数据: results/ 目录下各子文件夹
EOF

echo ""
echo "所有批量测试完成！"

echo ""
echo "=========================================="
echo "           批量测试完成"
echo "=========================================="
echo "调度器数量: ${#SCHEDULERS[@]}"
echo "总配置数: $((${#BACKGROUND_COUNTS[@]} * ${#BLOCK_SIZES[@]}))"
echo "总测试次数: $TOTAL_TESTS"
echo "每个调度器在每个配置下重复: $REPEAT_COUNT 次"
echo ""
echo "实时数据文件:"
echo "- 详细报告: $REALTIME_REPORT"
echo "- CSV数据: $REALTIME_CSV"
echo ""
echo "测试顺序示例:"
echo "第1轮: none→bfq→duet_same→duet_dual"
echo "第2轮: none→bfq→duet_same→duet_dual"
echo "第3轮: none→bfq→duet_same→duet_dual"
echo ""
echo "调度器范围: ${SCHEDULERS[*]}"
echo "Background数量范围: ${BACKGROUND_COUNTS[*]}"
echo "块大小范围: ${BLOCK_SIZES[*]}"
echo "=========================================="

