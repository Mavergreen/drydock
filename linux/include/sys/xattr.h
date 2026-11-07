#ifndef DRYDOCK_LINUX_SYS_XATTR_H
#define DRYDOCK_LINUX_SYS_XATTR_H
#include_next <sys/xattr.h>
#define listxattr(path, list, size, options) listxattr(path, list, size)
#define getxattr(path, name, value, size, position, options) getxattr(path, name, value, size)
#define fsetxattr(fd, name, value, size, position, options) fsetxattr(fd, name, value, size, options)
#define setxattr(path, name, value, size, position, options) setxattr(path, name, value, size, options)
#endif
