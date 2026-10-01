#include "CZlib.h"

#include <stdio.h>
#include <zlib.h>

int tuner_gunzip_file(const char *src, const char *dst) {
    gzFile in = gzopen(src, "rb");
    if (!in) return -1;
    gzbuffer(in, 1 << 18);
    FILE *out = fopen(dst, "wb");
    if (!out) { gzclose(in); return -2; }

    static const size_t chunk = 1 << 20;
    char buf[1 << 16];
    (void)chunk;
    int result = 0;
    for (;;) {
        int n = gzread(in, buf, sizeof(buf));
        if (n < 0) { result = -3; break; }
        if (n == 0) break;
        if (fwrite(buf, 1, (size_t)n, out) != (size_t)n) { result = -2; break; }
    }
    // gzread stops early on a truncated stream without an error code; gzerror reports it.
    int err = Z_OK;
    gzerror(in, &err);
    if (result == 0 && err != Z_OK && err != Z_STREAM_END) result = -3;
    fclose(out);
    gzclose(in);
    return result;
}
