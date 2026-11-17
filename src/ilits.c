/* ilits - Ilitek ILI2105 (ili210x protocol) touch for the Citaq H10-3 under Android 10.
 * Static arm64. Talks to the controller over /dev/i2c-N (I2C_RDWR), injects touches via
 * /dev/uinput as a direct (touchscreen) multitouch device.
 *
 *   ilits info  [bus]          firmware + panel info + one touch-data read
 *   ilits raw   [bus]          print raw touch packets while you touch (Ctrl+C to stop)
 *   ilits reset                pulse the reset line (gpio0 B3 = gpio11), then info
 *   ilits run   [bus] [opts]   the daemon: opts  swapxy invx invy  maxx=N maxy=N
 *
 * Protocol (mainline ili210x, 2013): reg 0x10 -> 9 bytes:
 *   [status][x0 lo][x0 hi][y0 lo][y0 hi][x1 lo][x1 hi][y1 lo][y1 hi], status bit i = finger i down.
 * reg 0x20 panel info: max_x (le16), max_y (le16), xch, ych. reg 0x40 firmware: id, major, minor.
 * IRQ line gpio0 B4 (gpio12) goes low while data is pending; we poll it (or the bus) ~100 Hz.
 * build: aarch64-linux-gnu-gcc -static -O2 -o ilits.bin ilits.c */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <time.h>
#include <sys/ioctl.h>
#include <linux/i2c.h>
#include <linux/i2c-dev.h>
#include <linux/uinput.h>

static int fd_i2c = -1;
static const int ADDR = 0x41;

static int rd(unsigned char reg, unsigned char *buf, int len) {
    struct i2c_msg m[2] = {
        { .addr = ADDR, .flags = 0, .len = 1, .buf = &reg },
        { .addr = ADDR, .flags = I2C_M_RD, .len = len, .buf = buf } };
    struct i2c_rdwr_ioctl_data d = { m, 2 };
    return ioctl(fd_i2c, I2C_RDWR, &d) < 0 ? -1 : 0;
}

static void msleep(int ms) { struct timespec t = { ms / 1000, (ms % 1000) * 1000000L }; nanosleep(&t, 0); }

static int wfile(const char *p, const char *v) {
    int f = open(p, O_WRONLY); if (f < 0) return -1;
    int r = write(f, v, strlen(v)); close(f); return r < 0 ? -1 : 0;
}
static int rgpio(int n) {
    char p[64], c = '1'; snprintf(p, sizeof p, "/sys/class/gpio/gpio%d/value", n);
    int f = open(p, O_RDONLY); if (f < 0) return -1;
    if (read(f, &c, 1) != 1) c = '1';
    close(f); return c - '0';
}
static void gpio_setup(void) {
    wfile("/sys/class/gpio/export", "12");
    wfile("/sys/class/gpio/gpio12/direction", "in");
}
static void do_reset(void) {
    wfile("/sys/class/gpio/export", "11");
    wfile("/sys/class/gpio/gpio11/direction", "out");
    wfile("/sys/class/gpio/gpio11/value", "0"); msleep(20);
    wfile("/sys/class/gpio/gpio11/value", "1"); msleep(200);
    printf("reset pulsed (gpio11 low 20 ms, then high)\n");
}

static void hex(const char *t, unsigned char *b, int n) {
    printf("%s", t); for (int i = 0; i < n; i++) printf(" %02x", b[i]); printf("\n");
}

static int open_bus(int bus) {
    char p[32]; snprintf(p, sizeof p, "/dev/i2c-%d", bus);
    fd_i2c = open(p, O_RDWR);
    if (fd_i2c < 0) { fprintf(stderr, "open %s: %s\n", p, strerror(errno)); return -1; }
    return 0;
}

static int info(void) {
    unsigned char b[16]; int ok = 0;
    memset(b, 0, sizeof b);
    if (rd(0x40, b, 3) == 0) { hex("fw   (0x40):", b, 3); ok++; } else printf("fw   (0x40): no answer (%s)\n", strerror(errno));
    if (rd(0x20, b, 6) == 0) { hex("panel(0x20):", b, 6); printf("   -> max_x %d max_y %d, channels %d x %d\n", b[0] | b[1] << 8, b[2] | b[3] << 8, b[4], b[5]); ok++; }
    else printf("panel(0x20): no answer\n");
    if (rd(0x10, b, 9) == 0) { hex("touch(0x10):", b, 9); ok++; } else printf("touch(0x10): no answer\n");
    printf("irq line gpio12 = %d (0 = data pending)\n", rgpio(12));
    return ok;
}

static void raw(void) {
    unsigned char b[16], last[16]; memset(last, 0xee, sizeof last);
    printf("touch the screen... (Ctrl+C to stop)\n");
    for (;;) {
        if (rd(0x10, b, 9) == 0 && memcmp(b, last, 9)) {
            hex("", b, 9);
            int st = b[0];
            for (int i = 0; i < 2; i++) if (st & (1 << i))
                printf("   finger %d: x=%d y=%d\n", i, b[1 + 4 * i] | b[2 + 4 * i] << 8, b[3 + 4 * i] | b[4 + 4 * i] << 8);
            memcpy(last, b, 9); fflush(stdout);
        }
        msleep(10);
    }
}

static int ui;
static void emit(int type, int code, int val) {
    struct input_event e; memset(&e, 0, sizeof e); e.type = type; e.code = code; e.value = val;
    if (write(ui, &e, sizeof e) < 0) {}
}
static void absinfo(int code, int min, int max) {
    struct uinput_abs_setup a; memset(&a, 0, sizeof a);
    a.code = code; a.absinfo.minimum = min; a.absinfo.maximum = max;
    ioctl(ui, UI_ABS_SETUP, &a);
}

static int run(int swapxy, int invx, int invy, int maxx, int maxy) {
    unsigned char p[8];
    if (maxx <= 0 || maxy <= 0) {
        /* the chip reports the largest coordinate (1023 x 767), so the range is that + 1 */
        if (rd(0x20, p, 6) == 0 && (p[0] | p[1] << 8) > 0) { maxx = (p[0] | p[1] << 8) + 1; maxy = (p[2] | p[3] << 8) + 1; }
        else { maxx = 1024; maxy = 768; }
    }
    int ox = swapxy ? maxy : maxx, oy = swapxy ? maxx : maxy;
    ui = open("/dev/uinput", O_WRONLY | O_NONBLOCK);
    if (ui < 0) { perror("/dev/uinput"); return 1; }
    ioctl(ui, UI_SET_EVBIT, EV_SYN); ioctl(ui, UI_SET_EVBIT, EV_KEY); ioctl(ui, UI_SET_EVBIT, EV_ABS);
    ioctl(ui, UI_SET_KEYBIT, BTN_TOUCH);
    ioctl(ui, UI_SET_ABSBIT, ABS_X); ioctl(ui, UI_SET_ABSBIT, ABS_Y);
    ioctl(ui, UI_SET_ABSBIT, ABS_MT_SLOT); ioctl(ui, UI_SET_ABSBIT, ABS_MT_TRACKING_ID);
    ioctl(ui, UI_SET_ABSBIT, ABS_MT_POSITION_X); ioctl(ui, UI_SET_ABSBIT, ABS_MT_POSITION_Y);
    ioctl(ui, UI_SET_PROPBIT, INPUT_PROP_DIRECT);
    absinfo(ABS_X, 0, ox - 1); absinfo(ABS_Y, 0, oy - 1);
    absinfo(ABS_MT_POSITION_X, 0, ox - 1); absinfo(ABS_MT_POSITION_Y, 0, oy - 1);
    absinfo(ABS_MT_SLOT, 0, 1); absinfo(ABS_MT_TRACKING_ID, 0, 65535);
    struct uinput_setup us; memset(&us, 0, sizeof us);
    strcpy(us.name, "ilitek ili2105 (ilits)"); us.id.bustype = BUS_I2C; us.id.vendor = 0x222a; us.id.product = 0x2105;
    if (ioctl(ui, UI_DEV_SETUP, &us) < 0 || ioctl(ui, UI_DEV_CREATE) < 0) { perror("uinput create"); return 1; }
    fprintf(stderr, "ilits: running, panel %dx%d swapxy=%d invx=%d invy=%d\n", maxx, maxy, swapxy, invx, invy);
    int down[2] = {0, 0}, tid = 1, id[2] = {-1, -1}, errs = 0;
    unsigned char b[9];
    for (;;) {
        int irq = rgpio(12);
        if (irq == 1 && !down[0] && !down[1]) { msleep(8); continue; }    /* idle, no data */
        if (rd(0x10, b, 9) < 0) {
            if (++errs > 50) { fprintf(stderr, "ilits: i2c errors, resetting chip\n"); do_reset(); errs = 0; }
            msleep(20); continue;
        }
        errs = 0;
        int any = 0;
        for (int i = 0; i < 2; i++) {
            int t = (b[0] >> i) & 1;
            emit(EV_ABS, ABS_MT_SLOT, i);
            if (t) {
                int x = b[1 + 4 * i] | b[2 + 4 * i] << 8, y = b[3 + 4 * i] | b[4 + 4 * i] << 8;
                if (x >= maxx) x = maxx - 1;
                if (y >= maxy) y = maxy - 1;
                if (invx) x = maxx - 1 - x;
                if (invy) y = maxy - 1 - y;
                if (swapxy) { int s = x; x = y; y = s; }
                if (!down[i]) { id[i] = tid++ & 0xffff; emit(EV_ABS, ABS_MT_TRACKING_ID, id[i]); }
                emit(EV_ABS, ABS_MT_POSITION_X, x); emit(EV_ABS, ABS_MT_POSITION_Y, y);
                if (i == 0 || !any) { emit(EV_ABS, ABS_X, x); emit(EV_ABS, ABS_Y, y); }
                any = 1;
            } else if (down[i]) {
                emit(EV_ABS, ABS_MT_TRACKING_ID, -1);
            }
            down[i] = t;
        }
        emit(EV_KEY, BTN_TOUCH, any);
        emit(EV_SYN, SYN_REPORT, 0);
        msleep(any ? 10 : 5);
    }
}

int main(int c, char **v) {
    const char *mode = c > 1 ? v[1] : "info";
    int bus = 2, swapxy = 0, invx = 0, invy = 0, maxx = 0, maxy = 0;
    for (int i = 2; i < c; i++) {
        if (!strcmp(v[i], "swapxy")) swapxy = 1; else if (!strcmp(v[i], "invx")) invx = 1;
        else if (!strcmp(v[i], "invy")) invy = 1; else if (!strncmp(v[i], "maxx=", 5)) maxx = atoi(v[i] + 5);
        else if (!strncmp(v[i], "maxy=", 5)) maxy = atoi(v[i] + 5); else bus = atoi(v[i]);
    }
    gpio_setup();
    if (!strcmp(mode, "reset")) { do_reset(); mode = "info"; }
    if (open_bus(bus)) return 1;
    if (!strcmp(mode, "info")) return info() ? 0 : 1;
    if (!strcmp(mode, "raw")) { raw(); return 0; }
    if (!strcmp(mode, "run")) {
        for (;;) { int r = run(swapxy, invx, invy, maxx, maxy); fprintf(stderr, "ilits: run exited %d, retry in 5 s\n", r); sleep(5); }
    }
    fprintf(stderr, "usage: ilits info|raw|reset|run [bus] [swapxy] [invx] [invy] [maxx=N maxy=N]\n");
    return 1;
}
