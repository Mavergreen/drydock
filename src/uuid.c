#include "uuid.h"

#include <stdio.h>
#include <string.h>
#include <CommonCrypto/CommonDigest.h>

#define MUU_SALT "drydock-stamp"

void muu_rfc4122_v4(uint8_t u[16]) {
    u[6] = (uint8_t)((u[6] & 0x0f) | 0x40);
    u[8] = (uint8_t)((u[8] & 0x3f) | 0x80);
}

void muu_stamp(const uint8_t old[16], unsigned major, unsigned minor, uint8_t out[16]) {
    uint8_t in[16 + sizeof MUU_SALT - 1], digest[CC_SHA256_DIGEST_LENGTH];
    memcpy(in, old, 16);
    memcpy(in + 16, MUU_SALT, sizeof MUU_SALT - 1);
    CC_SHA256(in, (CC_LONG)sizeof in, digest);
    memcpy(out, digest, 16);
    out[0] = 0xdd;
    out[1] = 0x0c;
    out[2] = (uint8_t)major;
    out[3] = (uint8_t)minor;
    muu_rfc4122_v4(out);
}

int muu_stamped_by(const uint8_t u[16], unsigned *major, unsigned *minor) {
    if (u[0] != 0xdd || u[1] != 0x0c || u[6] >> 4 != 4 || (u[8] & 0xc0) != 0x80) return 0;
    *major = u[2];
    *minor = u[3];
    return 1;
}

void muu_format(const uint8_t u[16], char out[MUU_STRLEN]) {
    snprintf(out, MUU_STRLEN,
             "%02X%02X%02X%02X-%02X%02X-%02X%02X-%02X%02X-%02X%02X%02X%02X%02X%02X",
             u[0], u[1], u[2], u[3], u[4], u[5], u[6], u[7],
             u[8], u[9], u[10], u[11], u[12], u[13], u[14], u[15]);
}
