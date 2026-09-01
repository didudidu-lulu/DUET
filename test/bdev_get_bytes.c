// System call number: 465
// 使用方法: ./bdev_get_bytes <device_name>
#include <stdio.h>
#include <stdlib.h>
#include <sys/syscall.h>
#include <unistd.h>

int main(int argc, char *argv[]) {
    int size = syscall(469, argv[1]);
    printf("%d\n", size);
}
