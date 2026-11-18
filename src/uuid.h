#ifndef DRYDOCK_UUID_H
#define DRYDOCK_UUID_H
/*
 * muu_ -- the LC_UUID `uuid set stamped` gives an image: DD0C, then the
 * Drydock version that wrote it, then bytes derived from the UUID it replaces,
 * so a rewritten binary is recognizable in a crash report or `info`.
 */
#include <stdint.h>

#define MUU_STRLEN 37   /* 8-4-4-4-12 hex digits, hyphens and the NUL */

/* Sets RFC 4122's version-4 and variant bits, as every UUID Drydock derives
 * carries: a stamp here, a raise's in src/grow.c. */
void muu_rfc4122_v4(uint8_t u[16]);

void muu_stamp(const uint8_t old[16], unsigned major, unsigned minor, uint8_t out[16]);
int  muu_stamped_by(const uint8_t u[16], unsigned *major, unsigned *minor);
void muu_format(const uint8_t u[16], char out[MUU_STRLEN]);

#endif /* DRYDOCK_UUID_H */
