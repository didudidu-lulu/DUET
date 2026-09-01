#!/bin/bash

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

# 创建结果目录函数
create_results_dir() {
    results_dir="test_results_$(date +%Y%m%d_%H%M%S)"
    if ! mkdir -p "$results_dir"; then
        echo "错误：无法创建结果目录"
        exit 1
    fi
    # 确保目录权限正确
    sudo chown -R $USER:$USER "$results_dir"
    sudo chmod -R 755 "$results_dir"
    echo "已创建新的测试结果目录：$results_dir"
}

# 测试参数数组
burst_rw_types=("randread")  # 突发IO的读写类型
burst_bs_sizes=("4k")               # 突发IO的块大小
burst_iodepths=("1")            # 突发IO的队列深度

bg_rw_types=("read")             # 背景流的读写类型
bg_bs_sizes=("1M")           # 背景流的块大小
bg_iodepths=("1" "4")              # 背景流的队列深度
bg_counts=("8")                 # 背景流数量
repeat_count=3                          # 每组参数重复测试次数
local_mode=("bfq")  # 测试模式，包括无调度器、BFQ调度器和BFQ高优先级调度器

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
            # 处理浮点数，只取整数部分
            burst_bw_kbs=$(echo "$burst_bw_kbs" | cut -d. -f1)
        else
            burst_bw_kbs=0
        fi
        
        # 提取突发任务延迟信息（平均延迟从lat_ns，99%延迟从clat_ns）
        burst_lat_avg_ns=$(jq -r ".jobs[$bg_count].read.lat_ns.mean" "$result_file" 2>/dev/null)
        burst_lat_99_ns=$(jq -r ".jobs[$bg_count].read.clat_ns.percentile.\"99.000000\"" "$result_file" 2>/dev/null)
        
        # 处理延迟值，使用awk进行浮点运算转换为微秒
        if [ "$burst_lat_avg_ns" != "null" ] && [ "$burst_lat_avg_ns" != "" ]; then
            burst_lat_avg_usec=$(echo "$burst_lat_avg_ns" | awk '{printf "%.0f", $1/1000}')
        else
            # 如果延迟数据为null，尝试从usec字段获取
            local burst_lat_avg_usec_raw=$(jq -r ".jobs[$bg_count].read.lat_usec.mean" "$result_file" 2>/dev/null)
            if [ "$burst_lat_avg_usec_raw" != "null" ] && [ "$burst_lat_avg_usec_raw" != "" ]; then
                burst_lat_avg_usec=$(echo "$burst_lat_avg_usec_raw" | awk '{printf "%.0f", $1}')
            else
                burst_lat_avg_usec=0
            fi
        fi
        
        if [ "$burst_lat_99_ns" != "null" ] && [ "$burst_lat_99_ns" != "" ]; then
            burst_lat_99_usec=$(echo "$burst_lat_99_ns" | awk '{printf "%.0f", $1/1000}')
        else
            local burst_lat_99_usec_raw=$(jq -r ".jobs[$bg_count].read.lat_usec.percentile.\"99.000000\"" "$result_file" 2>/dev/null)
            if [ "$burst_lat_99_usec_raw" != "null" ] && [ "$burst_lat_99_usec_raw" != "" ]; then
                burst_lat_99_usec=$(echo "$burst_lat_99_usec_raw" | awk '{printf "%.0f", $1}')
            else
                burst_lat_99_usec=0
            fi
        fi
    else
        # 如果没有jq，使用grep和sed解析
        local bw_values=$(grep -o '"bw":[0-9]*' "$result_file" | sed 's/"bw"://')
        local bw_array=($bw_values)
        
        # 计算背景流总带宽
        for ((i=0; i<bg_count && i<${#bw_array[@]}; i++)); do
            total_bg_bw_kbs=$((total_bg_bw_kbs + ${bw_array[i]}))
            job_count=$((job_count + 1))
        done
        
        # 获取突发任务带宽
        if [ $bg_count -lt ${#bw_array[@]} ]; then
            burst_bw_kbs=${bw_array[$bg_count]}
        else
            burst_bw_kbs=0
        fi
        
        # 尝试提取延迟信息（简化版本）
        burst_lat_avg_ns=$(grep -o '"mean":[0-9.]*' "$result_file" | tail -1 | sed 's/"mean"://' | cut -d. -f1)
        burst_lat_99_ns=$(grep -o '"99.000000":[0-9.]*' "$result_file" | tail -1 | sed 's/"99.000000"://' | cut -d. -f1)
        
        if [ -z "$burst_lat_avg_ns" ]; then burst_lat_avg_ns=0; fi
        if [ -z "$burst_lat_99_ns" ]; then burst_lat_99_ns=0; fi
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
    
    # 将带宽统计写入汇总文件（为主测试创建单独的汇总文件）
    local main_summary_file="$results_dir/main_test_bandwidth_summary.csv"
    if [ ! -f "$main_summary_file" ]; then
        echo "测试名称,模式,背景流总带宽(KB/s),突发任务带宽(KB/s),总体带宽(KB/s),背景流总带宽(MB/s),突发任务带宽(MB/s),总体带宽(MB/s),突发任务平均延迟(μs),突发任务99%延迟(μs)" > "$main_summary_file"
    fi
    echo "$test_name,$mode,$total_bg_bw_kbs,$burst_bw_kbs,$total_bw_kbs,$bg_bw_mbs,$burst_bw_mbs,$total_bw_mbs,$burst_lat_avg_usec,$burst_lat_99_usec" >> "$main_summary_file"
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

# 运行单次测试
run_test() {
    local bg_rw=$1
    local bg_bs=$2
    local bg_iodepth=$3
    local bg_count=$4
    local burst_rw=$5
    local burst_iodepth=$6
    local burst_bs=$7
    local iteration=$8
    local mode=$9

    # 优化后的测试配置文件名
    local test_name="burst_rw-${burst_rw}_burst_bs-${burst_bs}_burst_iodepth-${burst_iodepth}_bg_rw-${bg_rw}_bg_bs-${bg_bs}_bg_iodepth-${bg_iodepth}_bg_count-${bg_count}_iter-${iteration}"

    # 创建完整的测试配置文件
    local test_config="$results_dir/test_${test_name}.fio"
    cp template.fio "$test_config"

    # 替换突发 IO 参数
    sed -i "s/BURST_RW/${burst_rw}/" "$test_config"
    sed -i "s/BURST_BS/${burst_bs}/" "$test_config"
    sed -i "s/BURST_IODEPTH/${burst_iodepth}/" "$test_config"
 
    # 修改burst_io的thinktime参数
    sed -i "s/thinktime=1s/thinktime=250ms/" "$test_config"
    sed -i "s/thinktime_blocks=1/thinktime_blocks=1/" "$test_config"
    
    # 先根据模式设置突发任务优先级（在添加背景流之前）
    if [ "$mode" = "bfq_high" ]; then
        sed -i "/^\[burst_io\]/a prioclass=1\nprio=0" "$test_config"
    elif [ "$mode" = "bfq_realtime" ]; then
        sed -i "/^\[burst_io\]/a prioclass=0\nprio=0" "$test_config"
    elif [ "$mode" = "bfq_limit" ]; then
        sed -i "/^\[burst_io\]/a prioclass=1\nprio=0" "$test_config"
    fi
    
    # 在burst_io配置之前添加背景流配置
    local bg_jobs=""
    for ((i=1; i<=bg_count; i++)); do
        bg_jobs+="
[background_${i}]
rw=${bg_rw}
bs=${bg_bs}
iodepth=${bg_iodepth}
runtime=30s
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
    
    # 根据模式设置突发任务优先级
    if [ "$mode" = "bfq_high" ]; then
        sed -i "/^\[burst_io\]/a prioclass=1\nprio=0" "$test_config"
    elif [ "$mode" = "bfq_realtime" ]; then
        sed -i "/^\[burst_io\]/a prioclass=0" "$test_config"
    elif [ "$mode" = "bfq_limit" ]; then
        sed -i "/^\[burst_io\]/a prioclass=1\nprio=0" "$test_config"
    fi

    log_message "开始测试: $test_name"
    
    # 启动FIO测试（包含背景流和突发任务）
    sudo fio "$test_config" --output="$results_dir/${test_name}_result.json" --output-format=json &
    fio_pid=$!
    
    # 如果是bfq_limit模式，需要找到突发任务的PID并使用ioprio_override
    if [ "$mode" = "bfq_limit" ]; then
        ./bdev_set_bytes /dev/nvme0n1 1 4194304 4194304
        log_message "使用ioprio_override提高突发任务优先级"
        ./ioprio_override $(ps aux | grep fio | tail -n2 | head -n1 | awk '{print $2}')
        
    fi
    
    # 等待测试完成
    wait $fio_pid
    
    # 计算并记录总带宽（所有模式都计算）
    calculate_main_test_bandwidth "$results_dir/${test_name}_result.json" "$bg_count" "$test_name" "$mode"
    
    # 清理配置文件
    # rm -f "$test_config"

    log_message "完成测试: $test_name"
}

# # 主测试循环
log_message "开始测试系列"
cleanup_old_results
create_results_dir  # 在清理后立即创建新目录

# 编译必要的程序
# log_message "编译必要的程序..."
# make
# if [ $? -ne 0 ]; then
#     log_message "错误: 编译失败"
#     exit 1
# fi

device="nvme0n1"  # 根据实际设备名修改

# 在 mode 列表中加入 deadline 和 deadline_high
for mode in "${local_mode[@]}"; do
    if [ "$mode" = "none" ]; then
        echo none | sudo tee /sys/block/nvme0n1/queue/scheduler
        scheduler_tag="none"
        # 不切换调度器
    elif [ "$mode" = "bfq" ]; then
        echo bfq | sudo tee /sys/block/$device/queue/scheduler
        scheduler_tag="bfq"
    elif [ "$mode" = "bfq_high" ]; then
        echo bfq | sudo tee /sys/block/$device/queue/scheduler
        scheduler_tag="bfq_high"
    elif [ "$mode" = "bfq_realtime" ]; then
        echo bfq | sudo tee /sys/block/$device/queue/scheduler
        scheduler_tag="bfq_realtime"
    elif [ "$mode" = "bfq_limit" ]; then
        echo bfq | sudo tee /sys/block/$device/queue/scheduler
        scheduler_tag="bfq_limit"
        log_message "设置BFQ调度器，准备使用带宽限制模式"

    elif [ "$mode" = "deadline" ]; then
        echo mq-deadline | sudo tee /sys/block/$device/queue/scheduler
        scheduler_tag="deadline"
    elif [ "$mode" = "deadline_high" ]; then
        echo mq-deadline | sudo tee /sys/block/$device/queue/scheduler
        # 设置 deadline 参数为最高优先级
        echo 1 | sudo tee /sys/block/$device/queue/iosched/read_expire
        echo 1 | sudo tee /sys/block/$device/queue/iosched/write_expire
        echo 1000 | sudo tee /sys/block/$device/queue/iosched/writes_starved
        echo 1 | sudo tee /sys/block/$device/queue/iosched/fifo_batch
        scheduler_tag="deadline_high"
    fi
    results_dir="test_results_${scheduler_tag}_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$results_dir"

    for burst_rw in "${burst_rw_types[@]}"; do
        for bg_rw in "${bg_rw_types[@]}"; do
            for bg_bs in "${bg_bs_sizes[@]}"; do
                for bg_count in "${bg_counts[@]}"; do
                    for bg_iodepth in "${bg_iodepths[@]}"; do
                        for burst_iodepth in "${burst_iodepths[@]}"; do
                            for burst_bs in "${burst_bs_sizes[@]}"; do
                                for ((iter=1; iter<=repeat_count; iter++)); do
                                    run_test "$bg_rw" "$bg_bs" "$bg_iodepth" "$bg_count" "$burst_rw" "$burst_iodepth" "$burst_bs" "$iter" "$mode"
                                    sleep 10  # 测试间隔
                                done
                            done
                        done
                    done
                done
            done
        done
    done
done

log_message "所有测试完成"
log_message "主测试带宽统计汇总已保存至各模式结果目录中的 main_test_bandwidth_summary.csv"

# ======= background-only 测试部分 =======
# log_message "开始 background-only 测试系列"
# results_dir_bgonly="test_results_bgonly_$(date +%Y%m%d_%H%M%S)"
# mkdir -p "$results_dir_bgonly"

# 创建带宽汇总文件的表头
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
# runtime=30s
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
