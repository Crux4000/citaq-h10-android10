/* blshim - make Android's brightness slider drive the Citaq H10-3 LVDS backlight.
 * The PX5 (MTC) kernel's pwm-backlight driver ignores 'brightness' and holds the PWM at 100 %.
 * The DTB points that driver at an unused PWM (pwm3 @ff680030, pin GPIO3_D6 not used on the Citaq), so Android's lights
 * HAL still has /sys/class/backlight/<x>/brightness to write to (0..255, 0 = screen off),
 * while the real backlight PWM (pwm0 @ff680000, pin GPIO3_B0) is free for this daemon to drive
 * through the PWM sysfs interface: period 25000 ns, normal polarity, duty 0 = dark.
 * build: aarch64-linux-gnu-gcc -static -O2 -o blshim blshim.c
 * usage: blshim [min_percent]   (default 3: lowest non-zero slider position = 3 % duty)
 */
#include <dirent.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define PERIOD 25000

static int rd(const char *p) {
    FILE *f = fopen(p, "r");
    int v = -1;
    if (f) { if (fscanf(f, "%d", &v) != 1) v = -1; fclose(f); }
    return v;
}
static int wr(const char *p, long v) {
    FILE *f = fopen(p, "w");
    if (!f) return -1;
    int r = fprintf(f, "%ld", v) < 0 ? -1 : 0;
    if (fclose(f)) r = -1;
    return r;
}
static int find_dir(const char *base, const char *want_link, char *out, size_t n) {
    DIR *d = opendir(base);
    struct dirent *e;
    char p[512], l[512];
    if (!d) return -1;
    while ((e = readdir(d))) {
        if (e->d_name[0] == '.') continue;
        snprintf(p, sizeof p, "%s/%s", base, e->d_name);
        if (want_link) {
            char dl[600];
            snprintf(dl, sizeof dl, "%s/device", p);
            ssize_t k = readlink(dl, l, sizeof l - 1);
            if (k <= 0) continue;
            l[k] = 0;
            if (!strstr(l, want_link)) continue;
        }
        snprintf(out, n, "%s", p);
        closedir(d);
        return 0;
    }
    closedir(d);
    return -1;
}

int main(int argc, char **argv) {
    int minpct = argc > 1 ? atoi(argv[1]) : 3;
    char chip[512], pwm[600], bl[512], p[700];
    for (int tries = 0; ; tries++) {          /* wait for sysfs at boot */
        if (!find_dir("/sys/class/pwm", "ff680000", chip, sizeof chip) &&
            !find_dir("/sys/class/backlight", NULL, bl, sizeof bl)) break;
        if (tries > 60) { fprintf(stderr, "blshim: pwm chip ff680000 or backlight not found\n"); return 1; }
        sleep(1);
    }
    snprintf(pwm, sizeof pwm, "%s/pwm0", chip);
    if (access(pwm, F_OK)) {
        snprintf(p, sizeof p, "%s/export", chip);
        if (wr(p, 0)) { perror("blshim: export pwm0 (is it still claimed by pwm-backlight?)"); return 1; }
        usleep(200000);
    }
    snprintf(p, sizeof p, "%s/period", pwm);       wr(p, PERIOD);
    snprintf(p, sizeof p, "%s/enable", pwm);       wr(p, 1);
    char bpath[700], mpath[700], dpath[700];
    snprintf(bpath, sizeof bpath, "%s/brightness", bl);
    snprintf(mpath, sizeof mpath, "%s/max_brightness", bl);
    snprintf(dpath, sizeof dpath, "%s/duty_cycle", pwm);
    int max = rd(mpath);
    if (max <= 0) max = 255;
    printf("blshim: %s -> %s (max %d, min %d%%)\n", bl, pwm, max, minpct);
    fflush(stdout);
    int last = -2;
    for (;;) {
        int b = rd(bpath);
        if (b != last && b >= 0) {
            if (b > max) b = max;
            long duty = b == 0 ? 0 :
                (long)PERIOD * (minpct * max + (long)b * (100 - minpct)) / (100L * max);
            wr(dpath, duty);
            last = b;
        }
        usleep(100000);
    }
}
