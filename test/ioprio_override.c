// 功能: 通过系统调用设置进程的I/O优先级
// // 参数: 传入的参数为整数，表示优先级
// 返回值: // 成功返回0，失败返回-1
#include <stdlib.h>
#include <sys/syscall.h>
#include <unistd.h>

int main(int argc, char *argv[]) { return syscall(468, atoi(argv[1])); }
