#ifndef ANCHOR_SMC_H
#define ANCHOR_SMC_H

#include <stdint.h>

#define SMC_OK                 0
#define SMC_ERR_NOT_FOUND      1
#define SMC_ERR_SIZE_MISMATCH  2
#define SMC_ERR_NOT_PRIVILEGED 3
#define SMC_ERR_RESULT         4
#define SMC_ERR_KERNEL         5

/// Opens a connection to the AppleSMC service.
int smc_open(uint32_t *conn);
void smc_close(uint32_t conn);

/// Reads a 4-character key. `size` is the capacity of `out` on input (max 32)
/// and the key's true data size on output.
int smc_read_key(uint32_t conn, const char *key, uint8_t *out, uint32_t *size, uint32_t *type);

/// Writes a 4-character key. `size` must match the key's data size. Requires root.
int smc_write_key(uint32_t conn, const char *key, const uint8_t *data, uint32_t size);

#endif
