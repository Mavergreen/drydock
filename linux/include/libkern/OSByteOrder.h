#ifndef DRYDOCK_LINUX_LIBKERN_OSBYTEORDER_H
#define DRYDOCK_LINUX_LIBKERN_OSBYTEORDER_H
#include <stdint.h>
#define OSSwapInt16(x) ((uint16_t)__builtin_bswap16((uint16_t)(x)))
#define OSSwapInt32(x) ((uint32_t)__builtin_bswap32((uint32_t)(x)))
#define OSSwapInt64(x) ((uint64_t)__builtin_bswap64((uint64_t)(x)))
#if __BYTE_ORDER__ != __ORDER_LITTLE_ENDIAN__
#error "drydock reads little-endian Mach-O on a little-endian host"
#endif
#define OSSwapHostToBigInt16(x) OSSwapInt16(x)
#define OSSwapHostToBigInt32(x) OSSwapInt32(x)
#define OSSwapHostToBigInt64(x) OSSwapInt64(x)
#define OSSwapBigToHostInt16(x) OSSwapInt16(x)
#define OSSwapBigToHostInt32(x) OSSwapInt32(x)
#define OSSwapBigToHostInt64(x) OSSwapInt64(x)
#endif
