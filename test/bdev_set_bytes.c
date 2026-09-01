// 功能：设置块设备的字节数。
// 使用方法: ./bdev_set_bytes <device_name> <enable> <bfq_high_bytes> <bfq_low_bytes>
#include <stdlib.h>
#include <sys/syscall.h>
#include <unistd.h>

int main(int argc, char *argv[]) {
    return syscall(467, argv[1], atoi(argv[2]), atoi(argv[3]), atoi(argv[4]));
}
