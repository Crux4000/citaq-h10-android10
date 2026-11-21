/* volshim - make Android's media volume control the Citaq H10-3 codec's hardware volume.
 * On this PX5/MTC build AudioService changes the STREAM_MUSIC index (volume_music_speaker in
 * Settings.System) but nothing is applied to the audio (the car MCU normally does volume).
 * volshim watches /data/system/users/0/settings_system.xml and sets the codec's digital DAC volume
 * to match. Re-checks every second in case the audio HAL's route tables rewrite it when a stream starts.
 * The Citaq is built with either of two codecs (the boot hook binds whichever is fitted); volshim checks
 * which card it got:
 *   RT5651: "DAC1 Playback Volume" (the HAL routes LOUT/HPO straight from the DAC - "LOUT MIX DAC L1/R1",
 *           "HPO MIX DAC1" - so the analog OUT/HP volume controls are bypassed and do nothing; v1 used those).
 *     index 0          -> LOUT/HPO playback switches off (mute)
 *     index max        -> DAC1 175 (0 dB); each index step below max = -3 dB (8 x 0.375 dB)
 *     OUT/HP Playback Volume held at 31 (0 dB)
 *   ES8316: "DAC Playback Volume" (0-192, 0.5 dB steps, 192 = 0 dB).
 *     index 0          -> DAC 0 (-96 dB, silent)
 *     index max        -> DAC 192 (0 dB); each index step below max = -3 dB (6 x 0.5 dB)
 * build: aarch64-linux-gnu-gcc -static -O2 -o volshim volshim.c
 * usage: volshim [settings_key] [max_index]   (defaults volume_music_speaker 15 = ro.config.media_vol_steps)
 */
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#include <sound/asound.h>

#define SETTINGS "/data/system/users/0/settings_system.xml"
#define CTL "/dev/snd/controlC0"
#define ZERO_DB 31      /* OUT/HP Playback Volume 0 dB */
#define DAC_0DB 175     /* RT5651 DAC1 Playback Volume 0 dB */
#define ES_0DB 192      /* ES8316 DAC Playback Volume 0 dB */

enum { RT5651, ES8316 };
static int codec = RT5651;

static int ctl_rw(int fd, const char *name, int write, long v, long *out) {
    struct snd_ctl_elem_value ev;
    memset(&ev, 0, sizeof ev);
    ev.id.iface = SNDRV_CTL_ELEM_IFACE_MIXER;
    snprintf((char *)ev.id.name, sizeof ev.id.name, "%s", name);
    if (ioctl(fd, SNDRV_CTL_IOCTL_ELEM_READ, &ev) < 0) return -1;
    if (out) *out = ev.value.integer.value[0];
    if (!write) return 0;
    struct snd_ctl_elem_info info;
    memset(&info, 0, sizeof info);
    info.id = ev.id;
    unsigned cnt = ioctl(fd, SNDRV_CTL_IOCTL_ELEM_INFO, &info) < 0 ? 1 : info.count;
    if (cnt < 1 || cnt > 2) cnt = 1;
    int same = 1;
    for (unsigned i = 0; i < cnt; i++) if (ev.value.integer.value[i] != v) same = 0;
    if (same) return 0;
    for (unsigned i = 0; i < cnt; i++) ev.value.integer.value[i] = v;
    return ioctl(fd, SNDRV_CTL_IOCTL_ELEM_WRITE, &ev) < 0 ? -1 : 1;
}

static int read_index(const char *key) {
    FILE *f = fopen(SETTINGS, "r");
    if (!f) return -1;
    static char buf[1 << 18];
    size_t n = fread(buf, 1, sizeof buf - 1, f);
    fclose(f);
    buf[n] = 0;
    char pat[96];
    snprintf(pat, sizeof pat, "name=\"%s\"", key);
    char *p = strstr(buf, pat);
    if (!p) return -1;
    char *e = strchr(p, '>');
    char *v = strstr(p, "value=\"");
    if (!v || (e && v > e)) return -1;
    return atoi(v + 7);
}

static void apply(int fd, int idx, int max) {
    int on = idx > 0;
    int ch = 0;
    long reg;
    if (codec == ES8316) {
        reg = on ? ES_0DB - 6L * (max - idx) : 0;
        if (reg < 0) reg = 0;
        if (reg > ES_0DB) reg = ES_0DB;
        ch |= ctl_rw(fd, "DAC Playback Volume", 1, reg, NULL) > 0;
    } else {
        reg = DAC_0DB - 8L * (max - idx);
        if (reg < 0) reg = 0;
        if (reg > DAC_0DB) reg = DAC_0DB;
        const char *sw[] = { "LOUT L Playback Switch", "LOUT R Playback Switch",
                             "HPO L Playback Switch", "HPO R Playback Switch" };
        for (int i = 0; i < 4; i++) ch |= ctl_rw(fd, sw[i], 1, on, NULL) > 0;
        if (on) {
            ch |= ctl_rw(fd, "DAC1 Playback Volume", 1, reg, NULL) > 0;
            ch |= ctl_rw(fd, "OUT Playback Volume", 1, ZERO_DB, NULL) > 0;
            ch |= ctl_rw(fd, "HP Playback Volume", 1, ZERO_DB, NULL) > 0;
        }
    }
    if (ch) { printf("volshim: index %d/%d -> %s reg %ld\n", idx, max, on ? "on" : "MUTE", reg); fflush(stdout); }
}

int main(int argc, char **argv) {
    const char *key = argc > 1 ? argv[1] : "volume_music_speaker";
    int max = argc > 2 && atoi(argv[2]) > 0 ? atoi(argv[2]) : 15;
    int fd = -1;
    for (int t = 0; fd < 0; t++) {
        fd = open(CTL, O_RDWR);
        if (fd < 0) { if (t > 60) { perror(CTL); return 1; } sleep(1); }
    }
    long dummy;
    if (ctl_rw(fd, "DAC1 Playback Volume", 0, 0, &dummy) == 0) codec = RT5651;
    else if (ctl_rw(fd, "DAC Playback Volume", 0, 0, &dummy) == 0) codec = ES8316;
    else { fprintf(stderr, "volshim: no RT5651 or ES8316 DAC volume control on %s\n", CTL); return 1; }
    printf("volshim: %s, key %s, max %d\n", codec == ES8316 ? "ES8316" : "RT5651", key, max); fflush(stdout);
    time_t last_m = 0; long last_ns = -1;
    int idx = -1;
    for (int tick = 0; ; tick++) {
        struct stat st;
        if (!stat(SETTINGS, &st) && (st.st_mtime != last_m || st.st_mtim.tv_nsec != last_ns)) {
            last_m = st.st_mtime; last_ns = st.st_mtim.tv_nsec;
            int v = read_index(key);
            if (v >= 0 && v != idx) { idx = v; apply(fd, idx, max); }
        }
        if (idx >= 0 && tick % 4 == 0) apply(fd, idx, max);    /* re-assert ~1 s */
        usleep(250000);
    }
}
