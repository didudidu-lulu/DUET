#!/bin/bash

# 设备和挂载点配置
DEVICE="/dev/nvme0n1"
MOUNT_POINTS=("/mnt/nvme" "/media/str508/*")

# 卸载文件系统函数
unmount_filesystems() {
    echo "开始卸载文件系统..."
    
    # 强制卸载所有可能的挂载点
    while mount | grep -q "$DEVICE"; do
        echo "检测到设备 $DEVICE 仍有挂载点，正在卸载..."
        
        # 获取所有挂载点
        MOUNT_POINTS_FOUND=$(mount | grep "$DEVICE" | awk '{print $3}')
        
        for mp in $MOUNT_POINTS_FOUND; do
            echo "卸载挂载点: $mp"
            sudo umount "$mp" 2>/dev/null || sudo umount -l "$mp" 2>/dev/null || sudo umount -f "$mp" 2>/dev/null
        done
        
        sleep 1
    done
    
    # 确保设备完全释放
    echo "等待设备完全释放..."
    sleep 2
    
    # 验证卸载结果
    if mount | grep -q "$DEVICE"; then
        echo "警告: 设备 $DEVICE 仍有挂载点未完全卸载"
        mount | grep "$DEVICE"
    else
        echo "✓ 设备 $DEVICE 已完全卸载"
    fi
}

# 清理旧结果函数
cleanup_old_results() {
    local old_results=$(find . -maxdepth 1 -name "test_results_*" -type d)
    if [ ! -z "$old_results" ]; then
        echo "发现以下旧的测试结果目录："
        echo "$old_results"
        echo "是否删除这些目录？(y/n)"
        read -r answer
        if [ "$answer" = "y" ]; then
            sudo rm -rf $old_results
            echo "已删除旧的测试结果目录"
        fi
    fi
}

# 在脚本开始时执行卸载
echo "========== 自动化I/O测试脚本 =========="
echo "开始执行预检查..."
unmount_filesystems

# 测试参数数组
burst_rw_types=("randread")  # 突发IO的读写类型
burst_bs_sizes=("16k")               # 突发IO的块大小
burst_iodepths=("1")            # 突发IO的队列深度
burst_thinktimes=("500ms")  # 突发IO的思考时间
burst_thinktime_blocks=("2")  # 突发IO的思考时间块数

bg_rw_types=("read")             # 背景流的读写类型
bg_bs_sizes=("1M")           # 背景流的块大小
bg_iodepths=("4")              # 背景流的队列深度
bg_counts=("16")                 # 背景流数量
repeat_count=1                        # 每组参数重复测试次数
local_mode=("bfq_limit")  # 测试模式，包括无调度器、BFQ调度器和BFQ高优先级调度器

# 定义高低阈值变量
BFQ_LIMIT_HIGH=4194304   # 高阈值（单位：字节）
BFQ_LIMIT_LOW_LIST=(131072 65536 32768 16384)  # 低阈值列表

# 日志函数
log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$results_dir/test_log.txt"
}

# 计算主测试总带宽函数（包含burst和背景流）
calculate_main_test_bandwidth() {
    local result_file=$1
    local bg_count=$2
    local test_name=$3
    local mode=$4
    local burst_thinktime_block=${5:-"unknown"}
    
    if [ ! -f "$result_file" ]; then
        log_message "警告: 结果文件不存在: $result_file"
        return
    fi
    
    # 从JSON结果中提取各个job的带宽
    local total_bg_bw_kbs=0
    local burst_bw_kbs=0
    local job_count=0
    local burst_lat_avg_ns=0
    local burst_lat_99_ns=0
    
    # 使用jq解析JSON，提取所有job的带宽和延迟
    if command -v jq >/dev/null 2>&1; then
        # 提取背景流带宽（前bg_count个job是背景流）
        for ((i=0; i<bg_count; i++)); do
            local bw_kbs=$(jq -r ".jobs[$i].read.bw" "$result_file" 2>/dev/null)
            if [ "$bw_kbs" != "null" ] && [ "$bw_kbs" != "" ]; then
                # 处理浮点数，只取整数部分
                bw_kbs=$(echo "$bw_kbs" | cut -d. -f1)
                total_bg_bw_kbs=$((total_bg_bw_kbs + bw_kbs))
                job_count=$((job_count + 1))
            fi
        done
        
        # 提取突发任务带宽和延迟（最后一个job是burst_io）
        burst_bw_kbs=$(jq -r ".jobs[$bg_count].read.bw" "$result_file" 2>/dev/null)
        if [ "$burst_bw_kbs" != "null" ] && [ "$burst_bw_kbs" != "" ]; then
            burst_bw_kbs=$(echo "$burst_bw_kbs" | cut -d. -f1)
        else
            burst_bw_kbs=0
        fi
        
        # 处理延迟值
        burst_lat_avg_ns=$(jq -r ".jobs[$bg_count].read.lat_ns.mean" "$result_file" 2>/dev/null)
        burst_lat_99_ns=$(jq -r ".jobs[$bg_count].read.clat_ns.percentile.\"99.000000\"" "$result_file" 2>/dev/null)
        
        if [ "$burst_lat_avg_ns" != "null" ] && [ "$burst_lat_avg_ns" != "" ]; then
            burst_lat_avg_usec=$(echo "$burst_lat_avg_ns" | awk '{printf "%.0f", $1/1000}')
        else
            burst_lat_avg_usec=0
        fi
        
        if [ "$burst_lat_99_ns" != "null" ] && [ "$burst_lat_99_ns" != "" ]; then
            burst_lat_99_usec=$(echo "$burst_lat_99_ns" | awk '{printf "%.0f", $1/1000}')
        else
            burst_lat_99_usec=0
        fi
    fi
    
    # 计算总带宽和各种统计
    local total_bw_kbs=$((total_bg_bw_kbs + burst_bw_kbs))
    local total_bw_mbs=$((total_bw_kbs / 1024))
    local bg_bw_mbs=$((total_bg_bw_kbs / 1024))
    local burst_bw_mbs=$((burst_bw_kbs / 1024))
    
    log_message "=== 主测试带宽统计 - $test_name (模式: $mode) ==="
    log_message "背景流数量: $bg_count"
    log_message "背景流总带宽: ${total_bg_bw_kbs} KB/s (${bg_bw_mbs} MB/s)"
    log_message "突发任务带宽: ${burst_bw_kbs} KB/s (${burst_bw_mbs} MB/s)"
    log_message "突发任务平均延迟: ${burst_lat_avg_usec} μs"
    log_message "突发任务99%延迟: ${burst_lat_99_usec} μs"
    log_message "总体带宽: ${total_bw_kbs} KB/s (${total_bw_mbs} MB/s)"
    log_message "=================================================="
    
    # 追加到全局CSV
    echo "$test_name,$mode,$total_bg_bw_kbs,$burst_bw_kbs,$total_bw_kbs,$bg_bw_mbs,$burst_bw_mbs,$total_bw_mbs,$burst_lat_avg_usec,$burst_lat_99_usec" >> "$global_summary_file"
    
    # 写入组汇总文件时包含thinktime_blocks信息
    local iter=$(echo "$test_name" | grep -o 'iter-[^_]*' | cut -d'-' -f2)
    echo "$test_name,$mode,$iter,$burst_thinktime_block,$total_bg_bw_kbs,$burst_bw_kbs,$total_bw_kbs,$bg_bw_mbs,$burst_bw_mbs,$total_bw_mbs,$burst_lat_avg_usec,$burst_lat_99_usec" >> "$group_summary_file"
}

# 计算总带宽函数
calculate_total_bandwidth() {
    local result_file=$1
    local bg_count=$2
    local test_name=$3
    
    if [ ! -f "$result_file" ]; then
        log_message "警告: 结果文件不存在: $result_file"
        return
    fi
    
    # 从JSON结果中提取每个job的带宽
    local total_bw_kbs=0
    local job_count=0
    
    # 使用jq解析JSON，提取所有job的带宽
    if command -v jq >/dev/null 2>&1; then
        # 如果有jq命令，使用jq解析
        for ((i=0; i<bg_count; i++)); do
            local bw_kbs=$(jq -r ".jobs[$i].read.bw" "$result_file" 2>/dev/null)
            if [ "$bw_kbs" != "null" ] && [ "$bw_kbs" != "" ]; then
                total_bw_kbs=$((total_bw_kbs + bw_kbs))
                job_count=$((job_count + 1))
            fi
        done
    else
        # 如果没有jq，使用grep和sed解析
        local bw_values=$(grep -o '"bw":[0-9]*' "$result_file" | head -n "$bg_count" | sed 's/"bw"://')
        for bw in $bw_values; do
            total_bw_kbs=$((total_bw_kbs + bw))
            job_count=$((job_count + 1))
        done
    fi
    
    if [ $job_count -gt 0 ]; then
        # 转换为MB/s (1024 KB = 1 MB)
        local total_bw_mbs=$((total_bw_kbs / 1024))
        local avg_bw_kbs=$((total_bw_kbs / job_count))
        local avg_bw_mbs=$((avg_bw_kbs / 1024))
        
        log_message "=== 带宽统计 - $test_name ==="
        log_message "背景流数量: $bg_count"
        log_message "总带宽: ${total_bw_kbs} KB/s (${total_bw_mbs} MB/s)"
        log_message "平均单流带宽: ${avg_bw_kbs} KB/s (${avg_bw_mbs} MB/s)"
        log_message "=================================="
        
        # 将带宽统计写入单独的汇总文件
        echo "$test_name,总带宽(KB/s),${total_bw_kbs},总带宽(MB/s),${total_bw_mbs},平均单流带宽(KB/s),${avg_bw_kbs},平均单流带宽(MB/s),${avg_bw_mbs}" >> "$results_dir_bgonly/bandwidth_summary.csv"
    else
        log_message "警告: 无法从结果文件中提取带宽数据: $result_file"
    fi
}

# 修改run_test函数，优化文件存储结构
run_test() {
    local bg_rw=$1
    local bg_bs=$2
    local bg_iodepth=$3
    local bg_count=$4
    local burst_rw=$5
    local burst_iodepth=$6
    local burst_bs=$7
    local burst_thinktime=$8
    local burst_thinktime_block=$9
    local iteration=${10}
    local mode=${11}
    local BFQ_LIMIT_LOW=${12:-$BFQ_LIMIT_LOW}

    # 优化后的测试配置文件名（包含thinktime_blocks）
    local test_name="burst_bs-${burst_bs}_burst_iodepth-${burst_iodepth}_burst_thinktime-${burst_thinktime}_burst_thinktime_blocks-${burst_thinktime_block}_bg_bs-${bg_bs}_bg_iodepth-${bg_iodepth}_bg_count-${bg_count}_iter-${iteration}"

    # 将配置文件和结果文件分类存储
    local test_config="$results_dir/fio_configs/test_${test_name}_${mode}.fio"
    cp template.fio "$test_config"

    # 替换突发 IO 参数
    sed -i "s/BURST_RW/${burst_rw}/" "$test_config"
    sed -i "s/BURST_BS/${burst_bs}/" "$test_config"
    sed -i "s/BURST_IODEPTH/${burst_iodepth}/" "$test_config"
 
    # 修改burst_io的thinktime参数
    sed -i "s/BURST_THINKTIME/${burst_thinktime}/" "$test_config"
    sed -i "s/BURST_THINKBLOCKS/${burst_thinktime_block}/" "$test_config"
    
    echo $mode $burst_thinktime_block
    sed -i "/^\[burst_io\]/a prioclass=1\nprio=0" "$test_config"

    # 在burst_io配置之前添加背景流配置
    local bg_jobs=""
    for ((i=1; i<=bg_count; i++)); do
        bg_jobs+="
[background_${i}]
prioclass=1
prio=7
rw=${bg_rw}
bs=${bg_bs}
iodepth=${bg_iodepth}
"
    done
    
    # 将背景流配置插入到burst_io之前
    awk -v bg_config="$bg_jobs" '
        /^\[burst_io\]/ {
            print bg_config
            print $0
            next
        }
        {print}
    ' "$test_config" > "$test_config.tmp" && mv "$test_config.tmp" "$test_config"

    log_message "开始测试: $test_name (模式: $mode, thinktime_blocks: $burst_thinktime_block)"
    
    # 结果文件存储到raw_results目录
    local result_file="$results_dir/raw_results/${test_name}_${mode}_result.json"
    sudo fio "$test_config" --output="$result_file" --output-format=json &
    fio_pid=$!
    
    # 如果是bfq_limit模式，需要在FIO启动后进行特殊处理
    if [ "$mode" = "bfq_limit" ]; then
        sleep 2
        ./bdev_set_bytes /dev/nvme0n1 1 $BFQ_LIMIT_HIGH $BFQ_LIMIT_LOW
        log_message "使用ioprio_override提高突发任务优先级"
        local burst_pid=$(ps aux | grep fio | tail -n2 | head -n1 | awk '{print $2}')
        ./ioprio_override $burst_pid
    fi
    
    # 等待测试完成
    wait $fio_pid
    
    # 计算并记录总带宽
    calculate_main_test_bandwidth "$result_file" "$bg_count" "$test_name" "$mode" "$burst_thinktime_block"
    
    log_message "完成测试: $test_name (模式: $mode, thinktime_blocks: $burst_thinktime_block)"
}

# 添加组分析函数
generate_group_analysis() {
    local group_dir=$1
    local analysis_file="$group_dir/performance_analysis.txt"
    
    echo "=== 测试组性能分析报告 ===" > "$analysis_file"
    echo "生成时间: $(date)" >> "$analysis_file"
    echo "" >> "$analysis_file"
    
    # 从组汇总文件计算平均值和标准差
    if [ -f "$group_dir/group_summary.csv" ]; then
        echo "=== 各调度器平均性能 ===" >> "$analysis_file"
        for scheduler in "${local_mode[@]}"; do
            echo "调度器: $scheduler" >> "$analysis_file"
            
            # 计算该调度器的平均带宽和延迟
            avg_bg_bw=$(awk -F',' -v sched="$scheduler" '$2==sched {sum+=$4; count++} END {if(count>0) print sum/count; else print 0}' "$group_dir/group_summary.csv")
            avg_burst_bw=$(awk -F',' -v sched="$scheduler" '$2==sched {sum+=$5; count++} END {if(count>0) print sum/count; else print 0}' "$group_dir/group_summary.csv")
            avg_burst_lat=$(awk -F',' -v sched="$scheduler" '$2==sched {sum+=$10; count++} END {if(count>0) print sum/count; else print 0}' "$group_dir/group_summary.csv")
            
            echo "  平均背景流带宽: ${avg_bg_bw} KB/s" >> "$analysis_file"
            echo "  平均突发任务带宽: ${avg_burst_bw} KB/s" >> "$analysis_file"
            echo "  平均突发任务延迟: ${avg_burst_lat} μs" >> "$analysis_file"
            echo "" >> "$analysis_file"
        done
    fi
    
    echo "=== 文件说明 ===" >> "$analysis_file"
    echo "- fio_configs/: FIO配置文件" >> "$analysis_file"
    echo "- raw_results/: 原始JSON测试结果" >> "$analysis_file"
    echo "- group_summary.csv: 该组详细测试数据" >> "$analysis_file"
    echo "- performance_analysis.txt: 性能分析报告" >> "$analysis_file"
}

# 全局汇总文件路径
global_summary_file="test_results_global_$(date +%Y%m%d_%H%M%S)/scheduler_comparison_summary.csv"
mkdir -p "$(dirname "$global_summary_file")"

if [ ! -f "$global_summary_file" ]; then
    echo "测试名称,模式,背景流总带宽(KB/s),突发任务带宽(KB/s),总体带宽(KB/s),背景流总带宽(MB/s),突发任务带宽(MB/s),总体带宽(MB/s),突发任务平均延迟(μs),突发任务99%延迟(μs)" > "$global_summary_file"
fi

# 在calculate_main_test_bandwidth函数中追加结果
calculate_main_test_bandwidth() {
    local result_file=$1
    local bg_count=$2
    local test_name=$3
    local mode=$4
    local burst_thinktime_block=${5:-"unknown"}

    # 从JSON结果中提取各个job的带宽
    local total_bg_bw_kbs=0
    local burst_bw_kbs=0
    local job_count=0
    local burst_lat_avg_ns=0
    local burst_lat_99_ns=0
    
    # 使用jq解析JSON，提取所有job的带宽和延迟
    if command -v jq >/dev/null 2>&1; then
        # 提取背景流带宽（前bg_count个job是背景流）
        for ((i=0; i<bg_count; i++)); do
            local bw_kbs=$(jq -r ".jobs[$i].read.bw" "$result_file" 2>/dev/null)
            if [ "$bw_kbs" != "null" ] && [ "$bw_kbs" != "" ]; then
                # 处理浮点数，只取整数部分
                bw_kbs=$(echo "$bw_kbs" | cut -d. -f1)
                total_bg_bw_kbs=$((total_bg_bw_kbs + bw_kbs))
                job_count=$((job_count + 1))
            fi
        done
        
        # 提取突发任务带宽和延迟（最后一个job是burst_io）
        burst_bw_kbs=$(jq -r ".jobs[$bg_count].read.bw" "$result_file" 2>/dev/null)
        if [ "$burst_bw_kbs" != "null" ] && [ "$burst_bw_kbs" != "" ]; then
            burst_bw_kbs=$(echo "$burst_bw_kbs" | cut -d. -f1)
        else
            burst_bw_kbs=0
        fi
        
        # 处理延迟值
        burst_lat_avg_ns=$(jq -r ".jobs[$bg_count].read.lat_ns.mean" "$result_file" 2>/dev/null)
        burst_lat_99_ns=$(jq -r ".jobs[$bg_count].read.clat_ns.percentile.\"99.000000\"" "$result_file" 2>/dev/null)
        
        if [ "$burst_lat_avg_ns" != "null" ] && [ "$burst_lat_avg_ns" != "" ]; then
            burst_lat_avg_usec=$(echo "$burst_lat_avg_ns" | awk '{printf "%.0f", $1/1000}')
        else
            burst_lat_avg_usec=0
        fi
        
        if [ "$burst_lat_99_ns" != "null" ] && [ "$burst_lat_99_ns" != "" ]; then
            burst_lat_99_usec=$(echo "$burst_lat_99_ns" | awk '{printf "%.0f", $1/1000}')
        else
            burst_lat_99_usec=0
        fi
    fi
    
    # 计算总带宽和各种统计
    local total_bw_kbs=$((total_bg_bw_kbs + burst_bw_kbs))
    local total_bw_mbs=$((total_bw_kbs / 1024))
    local bg_bw_mbs=$((total_bg_bw_kbs / 1024))
    local burst_bw_mbs=$((burst_bw_kbs / 1024))
    
    log_message "=== 主测试带宽统计 - $test_name (模式: $mode) ==="
    log_message "背景流数量: $bg_count"
    log_message "背景流总带宽: ${total_bg_bw_kbs} KB/s (${bg_bw_mbs} MB/s)"
    log_message "突发任务带宽: ${burst_bw_kbs} KB/s (${burst_bw_mbs} MB/s)"
    log_message "突发任务平均延迟: ${burst_lat_avg_usec} μs"
    log_message "突发任务99%延迟: ${burst_lat_99_usec} μs"
    log_message "总体带宽: ${total_bw_kbs} KB/s (${total_bw_mbs} MB/s)"
    log_message "=================================================="
    
    # 追加到全局CSV
    echo "$test_name,$mode,$total_bg_bw_kbs,$burst_bw_kbs,$total_bw_kbs,$bg_bw_mbs,$burst_bw_mbs,$total_bw_mbs,$burst_lat_avg_usec,$burst_lat_99_usec" >> "$global_summary_file"
}

# 计算总带宽函数
calculate_total_bandwidth() {
    local result_file=$1
    local bg_count=$2
    local test_name=$3
    
    if [ ! -f "$result_file" ]; then
        log_message "警告: 结果文件不存在: $result_file"
        return
    fi
    
    # 从JSON结果中提取每个job的带宽
    local total_bw_kbs=0
    local job_count=0
    
    # 使用jq解析JSON，提取所有job的带宽
    if command -v jq >/dev/null 2>&1; then
        # 如果有jq命令，使用jq解析
        for ((i=0; i<bg_count; i++)); do
            local bw_kbs=$(jq -r ".jobs[$i].read.bw" "$result_file" 2>/dev/null)
            if [ "$bw_kbs" != "null" ] && [ "$bw_kbs" != "" ]; then
                total_bw_kbs=$((total_bw_kbs + bw_kbs))
                job_count=$((job_count + 1))
            fi
        done
    else
        # 如果没有jq，使用grep和sed解析
        local bw_values=$(grep -o '"bw":[0-9]*' "$result_file" | head -n "$bg_count" | sed 's/"bw"://')
        for bw in $bw_values; do
            total_bw_kbs=$((total_bw_kbs + bw))
            job_count=$((job_count + 1))
        done
    fi
    
    if [ $job_count -gt 0 ]; then
        # 转换为MB/s (1024 KB = 1 MB)
        local total_bw_mbs=$((total_bw_kbs / 1024))
        local avg_bw_kbs=$((total_bw_kbs / job_count))
        local avg_bw_mbs=$((avg_bw_kbs / 1024))
        
        log_message "=== 带宽统计 - $test_name ==="
        log_message "背景流数量: $bg_count"
        log_message "总带宽: ${total_bw_kbs} KB/s (${total_bw_mbs} MB/s)"
        log_message "平均单流带宽: ${avg_bw_kbs} KB/s (${avg_bw_mbs} MB/s)"
        log_message "=================================="
        
        # 将带宽统计写入单独的汇总文件
        echo "$test_name,总带宽(KB/s),${total_bw_kbs},总带宽(MB/s),${total_bw_mbs},平均单流带宽(KB/s),${avg_bw_kbs},平均单流带宽(MB/s),${avg_bw_mbs}" >> "$results_dir_bgonly/bandwidth_summary.csv"
    else
        log_message "警告: 无法从结果文件中提取带宽数据: $result_file"
    fi
}

# 修改run_test函数，优化文件存储结构
run_test() {
    local bg_rw=$1
    local bg_bs=$2
    local bg_iodepth=$3
    local bg_count=$4
    local burst_rw=$5
    local burst_iodepth=$6
    local burst_bs=$7
    local burst_thinktime=$8
    local burst_thinktime_block=$9
    local iteration=${10}
    local mode=${11}
    local BFQ_LIMIT_LOW=${12:-$BFQ_LIMIT_LOW}

    # 优化后的测试配置文件名（包含thinktime_blocks）
    local test_name="burst_bs-${burst_bs}_burst_iodepth-${burst_iodepth}_burst_thinktime-${burst_thinktime}_burst_thinktime_blocks-${burst_thinktime_block}_bg_bs-${bg_bs}_bg_iodepth-${bg_iodepth}_bg_count-${bg_count}_iter-${iteration}"

    # 将配置文件和结果文件分类存储
    local test_config="$results_dir/fio_configs/test_${test_name}_${mode}.fio"
    cp template.fio "$test_config"

    # 替换突发 IO 参数
    sed -i "s/BURST_RW/${burst_rw}/" "$test_config"
    sed -i "s/BURST_BS/${burst_bs}/" "$test_config"
    sed -i "s/BURST_IODEPTH/${burst_iodepth}/" "$test_config"
 
    # 修改burst_io的thinktime参数
    sed -i "s/BURST_THINKTIME/${burst_thinktime}/" "$test_config"
    sed -i "s/BURST_THINKBLOCKS/${burst_thinktime_block}/" "$test_config"
    
    echo $mode $burst_thinktime_block
    sed -i "/^\[burst_io\]/a prioclass=1\nprio=0" "$test_config"

    # 在burst_io配置之前添加背景流配置
    local bg_jobs=""
    for ((i=1; i<=bg_count; i++)); do
        bg_jobs+="
[background_${i}]
prioclass=1
prio=7
rw=${bg_rw}
bs=${bg_bs}
iodepth=${bg_iodepth}
"
    done
    
    # 将背景流配置插入到burst_io之前
    awk -v bg_config="$bg_jobs" '
        /^\[burst_io\]/ {
            print bg_config
            print $0
            next
        }
        {print}
    ' "$test_config" > "$test_config.tmp" && mv "$test_config.tmp" "$test_config"

    log_message "开始测试: $test_name (模式: $mode, thinktime_blocks: $burst_thinktime_block)"
    
    # 结果文件存储到raw_results目录
    local result_file="$results_dir/raw_results/${test_name}_${mode}_result.json"
    sudo fio "$test_config" --output="$result_file" --output-format=json &
    fio_pid=$!
    
    # 如果是bfq_limit模式，需要在FIO启动后进行特殊处理
    if [ "$mode" = "bfq_limit" ]; then
        sleep 2
        ./bdev_set_bytes /dev/nvme0n1 1 $BFQ_LIMIT_HIGH $BFQ_LIMIT_LOW
        log_message "使用ioprio_override提高突发任务优先级"
        local burst_pid=$(ps aux | grep fio | tail -n2 | head -n1 | awk '{print $2}')
        ./ioprio_override $burst_pid
    fi
    
    # 等待测试完成
    wait $fio_pid
    
    # 计算并记录总带宽
    calculate_main_test_bandwidth "$result_file" "$bg_count" "$test_name" "$mode" "$burst_thinktime_block"
    
    log_message "完成测试: $test_name (模式: $mode, thinktime_blocks: $burst_thinktime_block)"
}

generate_group_stats() {
    local group_dir=$1
    local summary_file="$group_dir/group_summary.csv"
    local stats_file="$group_dir/group_stats.csv"

    # 检查汇总文件是否存在
    if [ ! -f "$summary_file" ]; then
        echo "group_summary.csv 不存在，无法生成统计结果" > "$stats_file"
        return
    fi

    # 写入表头
    echo "调度器,thinktime_blocks,低阈值,背景流总带宽(KB/s)-均值,突发任务带宽(KB/s)-均值,总体带宽(KB/s)-均值,突发任务平均延迟(μs)-均值,突发任务99%延迟(μs)-均值,背景流总带宽(KB/s)-标准差,突发任务带宽(KB/s)-标准差,总体带宽(KB/s)-标准差,突发任务平均延迟(μs)-标准差,突发任务99%延迟(μs)-标准差" > "$stats_file"

    # 按调度器、thinktime_blocks、低阈值分组统计
    awk -F',' '
    NR>1 {
        key = $2","$4","$12
        bg_bw[key] += $5; burst_bw[key] += $6; total_bw[key] += $7
        burst_lat[key] += $11; burst_lat99[key] += $12
        bg_bw2[key] += ($5)^2; burst_bw2[key] += ($6)^2; total_bw2[key] += ($7)^2
        burst_lat2[key] += ($11)^2; burst_lat992[key] += ($12)^2
        cnt[key]++
    }
    END {
        for (k in cnt) {
            split(k, arr, ",")
            sched=arr[1]; tblock=arr[2]; low=arr[3]
            n=cnt[k]
            # 均值
            bg_avg=bg_bw[k]/n; burst_avg=burst_bw[k]/n; total_avg=total_bw[k]/n
            lat_avg=burst_lat[k]/n; lat99_avg=burst_lat99[k]/n
            # 标准差
            bg_std=sqrt(bg_bw2[k]/n-bg_avg^2)
            burst_std=sqrt(burst_bw2[k]/n-burst_avg^2)
            total_std=sqrt(total_bw2[k]/n-total_avg^2)
            lat_std=sqrt(burst_lat2[k]/n-lat_avg^2)
            lat99_std=sqrt(burst_lat992[k]/n-lat99_avg^2)
            printf "%s,%s,%s,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f\n", sched, tblock, low, bg_avg, burst_avg, total_avg, lat_avg, lat99_avg, bg_std, burst_std, total_std, lat_std, lat99_std
        }
    }
    ' "$summary_file" >> "$stats_file"
}


# 主测试循环
for bg_count in "${bg_counts[@]}"; do
    for burst_thinktime in "${burst_thinktimes[@]}"; do
        for burst_thinktime_block in "${burst_thinktime_blocks[@]}"; do
            for burst_rw in "${burst_rw_types[@]}"; do
                for bg_rw in "${bg_rw_types[@]}"; do
                    for bg_bs in "${bg_bs_sizes[@]}"; do
                        for bg_iodepth in "${bg_iodepths[@]}"; do
                            for burst_iodepth in "${burst_iodepths[@]}"; do
                                for burst_bs in "${burst_bs_sizes[@]}"; do
                                    for ((iter=1; iter<=repeat_count; iter++)); do
                                        for mode in "${local_mode[@]}"; do
                                            if [ "$mode" = "bfq_limit" ]; then
                                                for BFQ_LIMIT_LOW in "${BFQ_LIMIT_LOW_LIST[@]}"; do
                                                    echo bfq | sudo tee /sys/block/$device/queue/scheduler
                                                    scheduler_tag="bfq_limit"
                                                    log_message "设置BFQ调度器，准备使用带宽限制模式，低阈值：$BFQ_LIMIT_LOW"
                                                    # 在run_test调用前设置并创建目录
                                                    test_group_dir="test_results_bfq_limit_${bg_count}_${burst_thinktime}_${burst_thinktime_block}_${BFQ_LIMIT_LOW}"
                                                    mkdir -p "$test_group_dir/fio_configs"
                                                    mkdir -p "$test_group_dir/raw_results"
                                                    results_dir="$test_group_dir"
                                                    run_test "$bg_rw" "$bg_bs" "$bg_iodepth" "$bg_count" "$burst_rw" "$burst_iodepth" "$burst_bs" "$burst_thinktime" "$burst_thinktime_block" "$iter" "$mode" "$BFQ_LIMIT_LOW"
                                                    sudo sync
                                                    sleep 5
                                                done
                                            else
                                                # 其它调度器只运行一次
                                                if [ "$mode" = "none" ]; then
                                                    echo none | sudo tee /sys/block/nvme0n1/queue/scheduler
                                                    scheduler_tag="none"
                                                elif [ "$mode" = "bfq" ]; then
                                                    echo bfq | sudo tee /sys/block/$device/queue/scheduler
                                                    ./bdev_set_bytes /dev/nvme0n1 1 2147483647 2147483647
                                                    scheduler_tag="bfq"
                                                fi
                                                results_dir="$test_group_dir"
                                                run_test "$bg_rw" "$bg_bs" "$bg_iodepth" "$bg_count" "$burst_rw" "$burst_iodepth" "$burst_bs" "$burst_thinktime" "$burst_thinktime_block" "$iter" "$mode"
                                                sudo sync
                                                sleep 5
                                            fi
                                        done
                                    done
                                done
                            done
                        done
                    done
                done
            done
        done
    done
done

# 在每组实验循环结束后自动生成统计文件
generate_group_analysis "$test_group_dir"
generate_group_stats "$test_group_dir"

log_message "所有测试完成"
log_message "主测试带宽统计汇总已保存至各模式结果目录中的 main_test_bandwidth_summary.csv"

# ======= background-only 测试部分 =======
# log_message "开始 background-only 测试系列"
# results_dir_bgonly="test_results_bgonly_$(date +%Y%m%d_%H%M%S)"
# mkdir -p "$results_dir_bgonly"

# # 创建带宽汇总文件的表头
# echo "测试名称,总带宽(KB/s),值,总带宽(MB/s),值,平均单流带宽(KB/s),值,平均单流带宽(MB/s),值" > "$results_dir_bgonly/bandwidth_summary.csv"
# echo none | sudo tee /sys/block/nvme0n1/queue/scheduler
# for bg_rw in "${bg_rw_types[@]}"; do
#     for bg_bs in "${bg_bs_sizes[@]}"; do
#         for bg_iodepth in "${bg_iodepths[@]}"; do
#             for bg_count in "${bg_counts[@]}"; do
#                 for ((iter=1; iter<=repeat_count; iter++)); do
#                     test_config="$results_dir_bgonly/bgonly_rw-${bg_rw}_bs-${bg_bs}_iodepth-${bg_iodepth}_count-${bg_count}_iter-${iter}.fio"
#                     cp template.fio "$test_config"
#                     # 删除 burst_io 段及其内容
#                     awk '
#                         BEGIN {in_burst=0}
#                         /^\[burst_io\]/ {in_burst=1; next}
#                         /^\[/ && !/^\[burst_io\]/ {in_burst=0}
#                         !in_burst
#                     ' "$test_config" > tmp && mv tmp "$test_config"
#                     # 添加 background 流配置
#                     for ((i=1; i<=bg_count; i++)); do
#                         cat >> "$test_config" << EOF

# [background_${i}]
# rw=${bg_rw}
# bs=${bg_bs}
# iodepth=${bg_iodepth}
# EOF
#                     done
#                     test_name="bgonly_rw-${bg_rw}_bs-${bg_bs}_iodepth-${bg_iodepth}_count-${bg_count}_iter-${iter}"
#                     log_message "开始 background-only 测试: $test_name"
#                     sudo fio "$test_config" --output="$results_dir_bgonly/${test_name}_result.json" --output-format=json
#                     log_message "完成 background-only 测试: $test_name"
                    
#                     # 计算并记录总带宽
#                     calculate_total_bandwidth "$results_dir_bgonly/${test_name}_result.json" "$bg_count" "$test_name"
                    
#                     sleep 5
#                 done
#             done
#         done
#     done
# done

# log_message "所有 background-only 测试完成"
# log_message "带宽统计汇总已保存至: $results_dir_bgonly/bandwidth_summary.csv"

# 添加组分析函数
generate_group_analysis() {
    local group_dir=$1
    local analysis_file="$group_dir/performance_analysis.txt"
    
    echo "=== 测试组性能分析报告 ===" > "$analysis_file"
    echo "生成时间: $(date)" >> "$analysis_file"
    echo "" >> "$analysis_file"
    
    # 从组汇总文件计算平均值和标准差
    if [ -f "$group_dir/group_summary.csv" ]; then
        echo "=== 各调度器平均性能 ===" >> "$analysis_file"
        for scheduler in "${local_mode[@]}"; do
            echo "调度器: $scheduler" >> "$analysis_file"
            
            # 计算该调度器的平均带宽和延迟
            avg_bg_bw=$(awk -F',' -v sched="$scheduler" '$2==sched {sum+=$4; count++} END {if(count>0) print sum/count; else print 0}' "$group_dir/group_summary.csv")
            avg_burst_bw=$(awk -F',' -v sched="$scheduler" '$2==sched {sum+=$5; count++} END {if(count>0) print sum/count; else print 0}' "$group_dir/group_summary.csv")
            avg_burst_lat=$(awk -F',' -v sched="$scheduler" '$2==sched {sum+=$10; count++} END {if(count>0) print sum/count; else print 0}' "$group_dir/group_summary.csv")
            
            echo "  平均背景流带宽: ${avg_bg_bw} KB/s" >> "$analysis_file"
            echo "  平均突发任务带宽: ${avg_burst_bw} KB/s" >> "$analysis_file"
            echo "  平均突发任务延迟: ${avg_burst_lat} μs" >> "$analysis_file"
            echo "" >> "$analysis_file"
        done
    fi
    
    echo "=== 文件说明 ===" >> "$analysis_file"
    echo "- fio_configs/: FIO配置文件" >> "$analysis_file"
    echo "- raw_results/: 原始JSON测试结果" >> "$analysis_file"
    echo "- group_summary.csv: 该组详细测试数据" >> "$analysis_file"
    echo "- performance_analysis.txt: 性能分析报告" >> "$analysis_file"
}

