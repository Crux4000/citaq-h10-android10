/* propset - change an already-set Android system property in place, including ro.* ones.
 * Edits the prop_info in the shared property area (files in /dev/__properties__) the way bionic's
 * own writer does (dirty bit, value, new serial, futex wake). Must run as root.
 * Citaq H10-3 / PX5 Android 10: used to replace ro.serialno ("id.so" from Rockchip drmservice,
 * rejected by Google check-in) with a valid serial.
 * usage: propset <name> <value>        (value < 92 bytes)
 * build: aarch64-linux-gnu-gcc -static -O2 -o propset propset.c
 */
#include <dirent.h>
#include <fcntl.h>
#include <limits.h>
#include <linux/futex.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <unistd.h>

#define PROP_VALUE_MAX 92

static int try_file(const char *path, const char *name, const char *val) {
    int fd = open(path, O_RDWR);
    if (fd < 0) return 0;
    struct stat st;
    if (fstat(fd, &st) || st.st_size < 128) { close(fd); return 0; }
    unsigned char *m = mmap(NULL, st.st_size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    if (m == MAP_FAILED) return 0;
    size_t nl = strlen(name) + 1, vl = strlen(val);
    int done = 0;
    for (size_t off = 4 + PROP_VALUE_MAX; off + nl <= (size_t)st.st_size; off++) {
        if (memcmp(m + off, name, nl)) continue;
        if (off & 3) continue;                               /* prop_info is 4-byte aligned */
        _Atomic uint32_t *serial = (_Atomic uint32_t *)(m + off - PROP_VALUE_MAX - 4);
        char *value = (char *)(m + off - PROP_VALUE_MAX);
        uint32_t s = atomic_load(serial);
        size_t cur = strnlen(value, PROP_VALUE_MAX);
        if (cur >= PROP_VALUE_MAX || (s >> 24) != cur) continue;   /* not a real prop_info */
        printf("%s: %s = \"%s\" -> \"%s\"\n", path, name, value, val);
        atomic_store(serial, s | 1);                        /* dirty */
        memset(value, 0, PROP_VALUE_MAX);
        memcpy(value, val, vl);
        atomic_store(serial, ((uint32_t)vl << 24) | ((s + 2) & 0xffffff));
        syscall(SYS_futex, serial, FUTEX_WAKE, INT_MAX, NULL, NULL, 0);
        done = 1;
        break;
    }
    munmap(m, st.st_size);
    return done;
}

int main(int argc, char **argv) {
    if (argc != 3 || strlen(argv[2]) >= PROP_VALUE_MAX) {
        fprintf(stderr, "usage: propset <name> <value(<92 bytes)>\n");
        return 2;
    }
    DIR *d = opendir("/dev/__properties__");
    if (!d) { perror("/dev/__properties__"); return 1; }
    struct dirent *e;
    char p[512];
    int n = 0;
    while ((e = readdir(d))) {
        if (e->d_name[0] == '.') continue;
        snprintf(p, sizeof p, "/dev/__properties__/%s", e->d_name);
        n += try_file(p, argv[1], argv[2]);
    }
    closedir(d);
    if (!n) { fprintf(stderr, "%s not found (not set yet? use setprop)\n", argv[1]); return 1; }
    return 0;
}
