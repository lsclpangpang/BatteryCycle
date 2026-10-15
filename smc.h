#pragma once
#include <IOKit/IOKitLib.h>
#include <stdbool.h>
#include <stdint.h>

kern_return_t smc_open(void);
void smc_close(void);
bool smc_key_exists(const char *key);
// 读取 key，*size 传入缓冲区大小，返回实际字节数
kern_return_t smc_read(const char *key, uint8_t *buf, uint32_t *size);
// 写入 key，不足 key 长度的部分补 0
kern_return_t smc_write(const char *key, const uint8_t *buf, uint32_t size);
