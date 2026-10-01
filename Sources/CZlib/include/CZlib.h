#ifndef CZLIB_H
#define CZLIB_H

#include <stddef.h>

/// Decompresses a gzip file (including multi-member files) to `dst`.
/// Returns 0 on success, -1 if `src` can't be opened, -2 on write failure, -3 on corrupt data.
int tuner_gunzip_file(const char *src, const char *dst);

#endif
