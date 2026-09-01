#!/bin/bash

# 简单的日志函数
log_message() {
    echo "$1"
}

# 生成组分析函数（简化版）
generate_group_analysis() {
    local group_dir=$1
    echo "完成组测试: $group_dir"
}

# 设备和挂载点配置
DEVICE="/dev/nvme0n1"
MOUNT_POINTS=("/mnt/nvme")

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
unmount_filesystems

# 测试参数数组
burst_rw_types=("randread")  # 突发IO的读写类型
burst_bs_sizes=("4k")                # 突发IO的块大小
burst_iodepths=("1")            # 突发IO的队列深度
burst_thinktimes=("100ms")  # 突发IO的思考时间
burst_thinktime_blocks=("1")  # 突发IO的思考时间块数

bg_rw_types=("read")             # 背景流的读写类型
bg_bs_sizes=("1M")            # 背景流的块大小
bg_iodepths=("4") # 背景流的队列深度
bg_counts=("8")                 # 背景流数量
repeat_count=3                         # 每组参数重复测试次数
local_mode=("none" "bfq" "bfq_limit")  # 测试模式，包括无调度器、BFQ调度器和BFQ高优先级调度器

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
    
    # 写入全局汇总文件
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

    # log_message "开始测试: $test_name (模式: $mode, thinktime_blocks: $burst_thinktime_block)"
    
    # 结果文件存储到raw_results目录
    local result_file="$results_dir/raw_results/${test_name}_${mode}_result.json"
    sudo strace -f fio "$test_config" --output="$result_file" --output-format=json 2> strace.log &
    fio_pid=$!
    
    # 如果是bfq_limit模式，需要在FIO启动后进行特殊处理
    if [ "$mode" = "bfq_limit" ]; then
        sleep 2  # 等待fio启动
        ./bdev_set_bytes /dev/nvme0n1 1 4194304 4194304
        local burst_pid=$(ps aux | grep fio | tail -n2 | head -n1 | awk '{print $2}')
        ./ioprio_override $burst_pid
        # local fio_pids=$(pgrep fio)
        # for pid in $fio_pids; do
        #     ./ioprio_override $pid 2>/dev/null || true
        # done
    fi
    
    # 等待测试完成
    wait $fio_pid
    
    # 计算并记录总带宽
    calculate_main_test_bandwidth "$result_file" "$bg_count" "$test_name" "$mode" "$burst_thinktime_block"
    
    log_message "完成测试: $test_name (模式: $mode, thinktime_blocks: $burst_thinktime_block)"
}

# # 主测试循环
log_message "开始测试系列"
cleanup_old_results

device="nvme0n1"  # 根据实际设备名修改

# 创建全局汇总文件
global_summary_dir="test_results_global_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$global_summary_dir"
global_summary_file="$global_summary_dir/scheduler_comparison_summary.csv"

# 创建全局汇总文件表头
echo "bg_count,burst_thinktime,bg_rw,bg_bs,bg_iodepth,burst_rw,burst_bs,burst_iodepth,iteration,scheduler,背景流总带宽KB/s,突发任务带宽KB/s,总体带宽KB/s,背景流总带宽MB/s,突发任务带宽MB/s,总体带宽MB/s,突发任务平均延迟us,突发任务99%延迟us" > "$global_summary_file"

# 修改主循环，添加thinktime_blocks循环
for bg_count in "${bg_counts[@]}"; do  # 最外层：背景流数量
    for burst_thinktime in "${burst_thinktimes[@]}"; do  # 第二层：思考时间
        for burst_thinktime_block in "${burst_thinktime_blocks[@]}"; do  # 第三层：思考时间块数
            for burst_rw in "${burst_rw_types[@]}"; do
                for bg_rw in "${bg_rw_types[@]}"; do
                    for bg_bs in "${bg_bs_sizes[@]}"; do
                        for bg_iodepth in "${bg_iodepths[@]}"; do
                            for burst_iodepth in "${burst_iodepths[@]}"; do
                                for burst_bs in "${burst_bs_sizes[@]}"; do
                                    
                                    # 为每组测试条件创建一个统一的结果目录（包含thinktime_blocks）
                                    test_group_dir="test_results_bg${bg_count}_${bg_bs}_${burst_thinktime}_blocks${burst_thinktime_block}_$(date +%Y%m%d_%H%M%S)"
                                    mkdir -p "$test_group_dir"
                                    
                                    # 在组目录下创建子目录分类存储
                                    mkdir -p "$test_group_dir/fio_configs"    # FIO配置文件
                                    mkdir -p "$test_group_dir/raw_results"    # 原始JSON结果
                                    mkdir -p "$test_group_dir/summaries"      # 各调度器汇总
                                    
                                    for ((iter=1; iter<=repeat_count; iter++)); do
                                        
                                        # 为这一组测试条件写入表头和空行分隔
                                        if [ "$iter" -eq 1 ]; then
                                            # 写入空行分隔（除了第一组）
                                            # if [ "$bg_count" != "${bg_counts[0]}" ] || [ "$burst_thinktime" != "${burst_thinktimes[0]}" ] || [ "$burst_thinktime_block" != "${burst_thinktime_blocks[0]}" ] || [ "$bg_bs" != "${bg_bs_sizes[0]}" ]; then
                                            #     echo "" >> "$global_summary_file"
                                            # fi
                                            # 写入表头
                                            echo "测试名称,模式,背景流总带宽(KB/s),突发任务带宽(KB/s),总体带宽(KB/s),背景流总带宽(MB/s),突发任务带宽(MB/s),总体带宽(MB/s),突发任务平均延迟(μs),突发任务99%延迟(μs)" >> "$global_summary_file"
                                            
                                            # 在组目录下创建该组的详细汇总文件
                                            group_summary_file="$test_group_dir/group_summary.csv"
                                            echo "测试名称,模式,重复次数,thinktime_blocks,背景流总带宽(KB/s),突发任务带宽(KB/s),总体带宽(KB/s),背景流总带宽(MB/s),突发任务带宽(MB/s),总体带宽(MB/s),突发任务平均延迟(μs),突发任务99%延迟(μs)" > "$group_summary_file"
                                        fi
                                        
                                        # 最内层：所有调度器模式
                                        for mode in "${local_mode[@]}"; do
                                            
                                            # 设置调度器
                                            if [ "$mode" = "none" ]; then
                                                echo none | sudo tee /sys/block/nvme0n1/queue/scheduler
                                                scheduler_tag="none"
                                            elif [ "$mode" = "bfq" ]; then
                                                echo bfq | sudo tee /sys/block/$device/queue/scheduler
                                                ./bdev_set_bytes /dev/nvme0n1 1 2147483647 2147483647
                                                scheduler_tag="bfq"
                                            elif [ "$mode" = "bfq_limit" ]; then
                                                echo bfq | sudo tee /sys/block/$device/queue/scheduler
                                                scheduler_tag="bfq_limit"
                                                log_message "设置BFQ调度器，准备使用限制模式"
                                            fi

                                            # 使用统一的results_dir指向当前组目录
                                            results_dir="$test_group_dir"

                                            # 运行测试（在run_test函数内部处理bfq_limit的特殊逻辑）
                                            run_test "$bg_rw" "$bg_bs" "$bg_iodepth" "$bg_count" "$burst_rw" "$burst_iodepth" "$burst_bs" "$burst_thinktime" "$burst_thinktime_block" "$iter" "$mode"
                                            
                                            sudo sync
                                            sleep 5  # 测试间隔
                                        done
                                    done
                                    
                                    # 在每组测试完成后，生成该组的统计分析
                                    generate_group_analysis "$test_group_dir"
                                    
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

# # ======= background-only 测试部分 =======
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
# prioclass=1
# prio=7
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

