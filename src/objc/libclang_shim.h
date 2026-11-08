/* libclang_shim.h -- libclang, loaded at run time.
 *
 * tools/objc-source-inventory.c calls 46 clang_* functions. libclang_shim.c defines each of
 * them, with clang-c/Index.h's own prototype, as a forwarder through a function pointer that
 * drydock_libclang_load resolves from the libclang it is given, so drydock-objc links no
 * libclang and a host without one runs every other subcommand. A forwarder called before a
 * successful load aborts, naming itself. */
#ifndef DRYDOCK_LIBCLANG_SHIM_H
#define DRYDOCK_LIBCLANG_SHIM_H

#include <stddef.h>

/* dlopen(PATH, RTLD_NOW|RTLD_LOCAL), then resolve all 46 functions. 0 when every one
 * resolved; -1 otherwise, with the dlopen failure or the first missing symbol in ERR
 * (truncated to ERRLEN) and nothing left loaded. One libclang per process: a call after
 * a success is -1. */
int drydock_libclang_load(const char *path, char *err, size_t errlen);

/* The loaded libclang's clang_getClangVersion(), into OUT (truncated to OUTLEN), and the
 * major version that follows its first "version ", or -1 when it names none. */
int drydock_libclang_major(char *out, size_t outlen);

#endif
