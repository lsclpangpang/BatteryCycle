// AppleSMC 读写，结构体布局与 smcFanControl 的 smc.c 一致（内核要求 80 字节）
#include "smc.h"
#include <mach/mach.h>
#include <string.h>

#define KERNEL_INDEX_SMC     2
#define SMC_CMD_READ_BYTES   5
#define SMC_CMD_WRITE_BYTES  6
#define SMC_CMD_READ_KEYINFO 9

typedef struct { uint8_t major, minor, build, reserved; uint16_t release; } SMCVers;
typedef struct { uint16_t version, length; uint32_t cpuPLimit, gpuPLimit, memPLimit; } SMCPLimit;
typedef struct { uint32_t dataSize, dataType; uint8_t dataAttributes; } SMCKeyInfo;
typedef struct {
    uint32_t   key;
    SMCVers    vers;
    SMCPLimit  pLimitData;
    SMCKeyInfo keyInfo;
    uint8_t    result;
    uint8_t    status;
    uint8_t    data8;
    uint32_t   data32;
    uint8_t    bytes[32];
} SMCParam;

_Static_assert(sizeof(SMCParam) == 80, "SMCParam layout mismatch");

static io_connect_t conn;

static uint32_t fourcc(const char *k) {
    return ((uint32_t)k[0] << 24) | ((uint32_t)k[1] << 16) | ((uint32_t)k[2] << 8) | (uint32_t)k[3];
}

kern_return_t smc_open(void) {
    io_service_t svc = IOServiceGetMatchingService(MACH_PORT_NULL, IOServiceMatching("AppleSMC"));
    if (!svc) return kIOReturnNotFound;
    kern_return_t kr = IOServiceOpen(svc, mach_task_self(), 0, &conn);
    IOObjectRelease(svc);
    return kr;
}

void smc_close(void) {
    if (conn) IOServiceClose(conn);
    conn = 0;
}

static kern_return_t smc_call(SMCParam *in, SMCParam *out) {
    size_t out_size = sizeof(*out);
    return IOConnectCallStructMethod(conn, KERNEL_INDEX_SMC, in, sizeof(*in), out, &out_size);
}

static kern_return_t smc_key_info(const char *key, SMCKeyInfo *info) {
    SMCParam in = {0}, out = {0};
    in.key = fourcc(key);
    in.data8 = SMC_CMD_READ_KEYINFO;
    kern_return_t kr = smc_call(&in, &out);
    if (kr != KERN_SUCCESS) return kr;
    if (out.result != 0) return kIOReturnNotFound;
    *info = out.keyInfo;
    return KERN_SUCCESS;
}

bool smc_key_exists(const char *key) {
    SMCKeyInfo info;
    return smc_key_info(key, &info) == KERN_SUCCESS;
}

kern_return_t smc_read(const char *key, uint8_t *buf, uint32_t *size) {
    SMCKeyInfo info;
    kern_return_t kr = smc_key_info(key, &info);
    if (kr != KERN_SUCCESS) return kr;

    SMCParam in = {0}, out = {0};
    in.key = fourcc(key);
    in.keyInfo.dataSize = info.dataSize;
    in.data8 = SMC_CMD_READ_BYTES;
    kr = smc_call(&in, &out);
    if (kr != KERN_SUCCESS) return kr;
    if (out.result != 0) return kIOReturnError;

    uint32_t n = info.dataSize < *size ? info.dataSize : *size;
    memcpy(buf, out.bytes, n);
    *size = n;
    return KERN_SUCCESS;
}

kern_return_t smc_write(const char *key, const uint8_t *buf, uint32_t size) {
    SMCKeyInfo info;
    kern_return_t kr = smc_key_info(key, &info);
    if (kr != KERN_SUCCESS) return kr;
    if (size > info.dataSize || info.dataSize > sizeof(((SMCParam *)0)->bytes)) return kIOReturnBadArgument;

    SMCParam in = {0}, out = {0};
    in.key = fourcc(key);
    in.keyInfo.dataSize = info.dataSize;
    in.data8 = SMC_CMD_WRITE_BYTES;
    memcpy(in.bytes, buf, size);
    kr = smc_call(&in, &out);
    if (kr != KERN_SUCCESS) return kr;
    return out.result == 0 ? KERN_SUCCESS : kIOReturnError;
}
