#define _GNU_SOURCE

#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/time.h>
#include <errno.h>
#include <string.h>
#include <signal.h>
#include <libaio.h>

#include <linux/fs.h>

#define BLOCK_SIZE 1024 * 64// 16K
#define DEVICE_PATH "/dev/nvme0n1"
#define AIO_DEPTH 1
#define BURST_IOS 1  // 每次突发的IO数量

volatile int running = 1;

void signal_handler(int sig) {
    printf("Received signal %d, shutting down...\n", sig);
    fflush(stdout);
    running = 0;
}

long long get_time_us() {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return tv.tv_sec * 1000000LL + tv.tv_usec;
}

int main(int argc, char *argv[]) {
    int fd;
    void *buffer;
    long long program_start = get_time_us();
    int burst_round = 0;  // 突发轮次计数
    
    // AIO相关变量
    io_context_t ctx = 0;
    struct iocb cb;
    struct iocb *cbs[1];
    struct io_event events[1];
    
    signal(SIGTERM, signal_handler);
    signal(SIGINT, signal_handler);
    
    printf("Burst task started with libaio, PID: %d\n", getpid());
    fflush(stdout);
    
    // 打开设备
    fd = open(DEVICE_PATH, O_RDONLY | O_DIRECT);
    if (fd < 0) {
        perror("Failed to open device");
        return 1;
    }
    
    // 初始化AIO上下文
    if (io_setup(AIO_DEPTH, &ctx) < 0) {
        perror("Failed to setup AIO context");
        close(fd);
        return 1;
    }
    
    // 分配对齐的缓冲区
    if (posix_memalign(&buffer, BLOCK_SIZE, BLOCK_SIZE) != 0) {
        perror("Failed to allocate aligned buffer");
        io_destroy(ctx);
        close(fd);
        return 1;
    }
    
    // 主循环：持续进行突发测试
    while (running) {
        burst_round++;
        int io_count = 0;
        long long total_latency = 0;
        long long burst_start = get_time_us();
        
        printf("\n=== Starting Burst Round #%d ===\n", burst_round);
        fflush(stdout);
        
        // 执行一轮突发IO（1个IO）
        while (running && io_count < BURST_IOS) {
            if (!running) break;
            
            // 生成随机偏移
            off_t offset = (rand() % 1000) * BLOCK_SIZE;
            
            // 准备AIO请求
            memset(&cb, 0, sizeof(cb));
            io_prep_pread(&cb, fd, buffer, BLOCK_SIZE, offset);
            
            cbs[0] = &cb;
            
            // // 等待480μs
            // long long start = get_time_us();
            // while (get_time_us() - start < 480) {
            // }

            // 记录IO开始时间
            long long start_time = get_time_us();
            
            // 提交异步IO请求
            if (io_submit(ctx, 1, cbs) != 1) {
                perror("Failed to submit AIO request");
                continue;
            }
            
            // 等待IO完成
            int ret = io_getevents(ctx, 1, 1, events, NULL);
            if (ret < 0) {
                perror("Failed to get AIO events");
                continue;
            } else if (ret == 0) {
                printf("IO timeout occurred\n");
                fflush(stdout);
                continue;
            }
            
            // 记录IO完成时间
            long long end_time = get_time_us();
            
            // 检查IO结果
            if (events[0].res < 0) {
                printf("AIO read failed: %s\n", strerror(-events[0].res));
                printf("IO offset: %ld, return: %ld\n", offset, events[0].res);
                fflush(stdout);
                continue;
            } else {
                // 详细记录每个IO的offset和返回值
                printf("IO offset: %ld, return: %ld\n", offset, events[0].res);
                fflush(stdout);
                if (events[0].res != BLOCK_SIZE) {
                    printf("Partial read: %ld bytes instead of %d\n", events[0].res, BLOCK_SIZE);
                    fflush(stdout);
                }
            }
            
            io_count++;
            long long latency = end_time - start_time;
            
            // 统计所有IO的延迟（包括第一个）
            total_latency += latency;
            printf("AIO #%d completed: offset=%ld, latency=%lld μs\n", 
                   io_count, offset, latency);
            fflush(stdout);
            
            // 等待100ms后进行下一个IO
            usleep(100000);
        }
        
        // 计算本轮突发的统计结果
        long long burst_end = get_time_us();
        long long burst_time = burst_end - burst_start;
        int counted_ios = io_count;  // 统计所有IO
        
        printf("\n=== Burst Round #%d Summary ===\n", burst_round);
        printf("Total IOs: %d\n", io_count);
        printf("Burst time: %lld μs (%.2f s)\n", burst_time, burst_time / 1000000.0);
        if (counted_ios > 0) {
            printf("Average latency: %.2f μs\n", (double)total_latency / counted_ios);
            printf("Average IOPS: %.2f\n", counted_ios * 1000000.0 / burst_time);
        }
        printf("=== End Burst Round #%d ===\n", burst_round);
        fflush(stdout);
        
        // 如果程序仍在运行，等待100ms后开始下一轮突发
        if (running) {
            printf("Waiting 100ms before next burst round...\n");
            fflush(stdout);
            usleep(100000);  // 100ms间隔
        }
    }
    
    // 程序结束时的总体统计
    long long program_end = get_time_us();
    long long total_program_time = program_end - program_start;
    
    printf("\n=== Final Program Summary ===\n");
    printf("Total burst rounds: %d\n", burst_round);
    printf("Total program time: %lld μs (%.2f s)\n", total_program_time, total_program_time / 1000000.0);
    printf("Average time per burst round: %.2f s\n", (total_program_time / 1000000.0) / burst_round);
    printf("=== End Final Summary ===\n");
    fflush(stdout);
    
    // 清理资源
    free(buffer);
    io_destroy(ctx);
    close(fd);
    
    return 0;
}