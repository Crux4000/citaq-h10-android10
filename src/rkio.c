/* rkio - 64-bit-offset block I/O for the Citaq H10-3 (static arm64).
 * The stock Android 5.1 busybox is 32-bit without large-file support, so its dd
 * cannot seek past 2 GiB. This can.
 *   rkio w <file> <dev> <offset_MiB>        copy file into dev at offset
 *   rkio z <dev> <offset_MiB> <len_MiB>     write zeros
 *   rkio r <dev> <offset_MiB> <len_MiB>     read to stdout (pipe into md5sum)
 * Prints "rkio ok" to stderr on success, exits 1 on any error.
 * build: aarch64-linux-gnu-gcc -static -O2 -o rkio rkio.c */
#define _FILE_OFFSET_BITS 64
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#define MIB (1LL << 20)
static char buf[1 << 20];
static void die(const char *w) { fprintf(stderr, "rkio: %s: %s\n", w, strerror(errno)); exit(1); }
static void wall(int fd, const char *b, size_t n, off_t off) {
    while (n) { ssize_t k = pwrite(fd, b, n, off); if (k <= 0) die("write"); b += k; n -= k; off += k; }
}
int main(int c, char **v) {
    if (c < 5) { fprintf(stderr, "usage: rkio w <file> <dev> <offMiB> | z|r <dev> <offMiB> <lenMiB>\n"); return 1; }
    if (v[1][0] == 'w') {
        int in = open(v[2], O_RDONLY), out = open(v[3], O_WRONLY);
        if (in < 0) die(v[2]);
        if (out < 0) die(v[3]);
        off_t off = atoll(v[4]) * MIB; ssize_t n;
        while ((n = read(in, buf, sizeof buf)) > 0) { wall(out, buf, n, off); off += n; }
        if (n < 0) die("read");
        if (fsync(out)) die("fsync");
    } else if (v[1][0] == 'z') {
        int out = open(v[2], O_WRONLY); if (out < 0) die(v[2]);
        off_t off = atoll(v[3]) * MIB; long long left = atoll(v[4]);
        memset(buf, 0, sizeof buf);
        for (; left > 0; left--, off += MIB) wall(out, buf, MIB, off);
        if (fsync(out)) die("fsync");
    } else if (v[1][0] == 'r') {
        int in = open(v[2], O_RDONLY); if (in < 0) die(v[2]);
        off_t off = atoll(v[3]) * MIB; long long left = atoll(v[4]);
        for (; left > 0; left--, off += MIB) {
            ssize_t got = 0;
            while (got < MIB) { ssize_t k = pread(in, buf + got, MIB - got, off + got); if (k <= 0) die("read"); got += k; }
            const char *p = buf; size_t n = MIB;
            while (n) { ssize_t k = write(1, p, n); if (k <= 0) die("stdout"); p += k; n -= k; }
        }
    } else { fprintf(stderr, "rkio: bad mode\n"); return 1; }
    fprintf(stderr, "rkio ok\n");
    return 0;
}
