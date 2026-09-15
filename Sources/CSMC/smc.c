#include "smc.h"

#include <IOKit/IOKitLib.h>
#include <string.h>

#define KERNEL_INDEX_SMC      2
#define SMC_CMD_READ_BYTES    5
#define SMC_CMD_WRITE_BYTES   6
#define SMC_CMD_READ_KEYINFO  9
#define SMC_RESULT_NOT_FOUND  0x84

typedef struct {
    char major;
    char minor;
    char build;
    char reserved[1];
    uint16_t release;
} SMCKeyData_vers_t;

typedef struct {
    uint16_t version;
    uint16_t length;
    uint32_t cpuPLimit;
    uint32_t gpuPLimit;
    uint32_t memPLimit;
} SMCKeyData_pLimitData_t;

typedef struct {
    uint32_t dataSize;
    uint32_t dataType;
    char dataAttributes;
} SMCKeyData_keyInfo_t;

typedef struct {
    uint32_t key;
    SMCKeyData_vers_t vers;
    SMCKeyData_pLimitData_t pLimitData;
    SMCKeyData_keyInfo_t keyInfo;
    char result;
    char status;
    char data8;
    uint32_t data32;
    uint8_t bytes[32];
} SMCKeyData_t;

_Static_assert(sizeof(SMCKeyData_t) == 80, "SMCKeyData_t must match the kernel's 80-byte layout");

static uint32_t fourcc(const char *key) {
    return ((uint32_t)(uint8_t)key[0] << 24) | ((uint32_t)(uint8_t)key[1] << 16) |
           ((uint32_t)(uint8_t)key[2] << 8) | (uint32_t)(uint8_t)key[3];
}

static int call(uint32_t conn, SMCKeyData_t *in, SMCKeyData_t *out) {
    size_t outSize = sizeof(SMCKeyData_t);
    kern_return_t kr = IOConnectCallStructMethod(conn, KERNEL_INDEX_SMC, in, sizeof(SMCKeyData_t), out, &outSize);
    if (kr == kIOReturnNotPrivileged) return SMC_ERR_NOT_PRIVILEGED;
    if (kr != KERN_SUCCESS) return SMC_ERR_KERNEL;
    if ((uint8_t)out->result == SMC_RESULT_NOT_FOUND) return SMC_ERR_NOT_FOUND;
    if (out->result != 0) return SMC_ERR_RESULT;
    return SMC_OK;
}

static int key_info(uint32_t conn, const char *key, SMCKeyData_keyInfo_t *info) {
    if (strlen(key) != 4) return SMC_ERR_NOT_FOUND;
    SMCKeyData_t in = {0}, out = {0};
    in.key = fourcc(key);
    in.data8 = SMC_CMD_READ_KEYINFO;
    int r = call(conn, &in, &out);
    if (r != SMC_OK) return r;
    *info = out.keyInfo;
    return SMC_OK;
}

int smc_open(uint32_t *conn) {
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!service) return SMC_ERR_NOT_FOUND;
    kern_return_t kr = IOServiceOpen(service, mach_task_self(), 0, conn);
    IOObjectRelease(service);
    return kr == KERN_SUCCESS ? SMC_OK : SMC_ERR_KERNEL;
}

void smc_close(uint32_t conn) {
    if (conn) IOServiceClose(conn);
}

int smc_read_key(uint32_t conn, const char *key, uint8_t *out, uint32_t *size, uint32_t *type) {
    SMCKeyData_keyInfo_t info;
    int r = key_info(conn, key, &info);
    if (r != SMC_OK) return r;

    SMCKeyData_t in = {0}, result = {0};
    in.key = fourcc(key);
    in.keyInfo.dataSize = info.dataSize;
    in.data8 = SMC_CMD_READ_BYTES;
    r = call(conn, &in, &result);
    if (r != SMC_OK) return r;

    uint32_t n = info.dataSize;
    if (n > *size) n = *size;
    if (n > sizeof(result.bytes)) n = sizeof(result.bytes);
    memcpy(out, result.bytes, n);
    *size = info.dataSize;
    if (type) *type = info.dataType;
    return SMC_OK;
}

int smc_write_key(uint32_t conn, const char *key, const uint8_t *data, uint32_t size) {
    SMCKeyData_keyInfo_t info;
    int r = key_info(conn, key, &info);
    if (r != SMC_OK) return r;
    if (info.dataSize != size || size > 32) return SMC_ERR_SIZE_MISMATCH;

    SMCKeyData_t in = {0}, out = {0};
    in.key = fourcc(key);
    in.keyInfo.dataSize = size;
    in.data8 = SMC_CMD_WRITE_BYTES;
    memcpy(in.bytes, data, size);
    return call(conn, &in, &out);
}
