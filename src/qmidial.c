/*
 * qmidial - minimal QMI data-call client for the Citaq H10-3 (Fibocom NL668, qmi_wwan), no dependencies.
 *
 * Stands in for pppd under the PX5 ROM's Rockchip RIL (installed as "pppd" so the RIL's "killall pppd"
 * stops it): starts an IPv4 data call over QMI on /dev/cdc-wdm0, switches the modem and wwan0 to raw IP,
 * renames wwan0 to ppp0, configures it the way pppd would (local address, peer = gateway, MTU) and sets the
 * same net.ppp0.* properties pppd's ip-up script sets, so the RIL hands it to Android as mobile data.
 * Runs in the foreground until SIGTERM/SIGINT/SIGHUP or until the modem reports the call dropped, then
 * stops the call and renames the interface back to wwan0.
 *
 *   qmidial [-d /dev/cdc-wdm0] [-i wwan0] [-n ppp0] [-p profile] [-a apn] [-t]
 *     -p  3GPP profile (context) number, default 1 (the RIL writes Android's APN into context 1)
 *     -a  APN to use instead of the profile's
 *     -t  test: bring the call up, print the settings, take it down again and exit
 *
 * The raw_ip sysfs switch (/sys/class/net/wwan0/qmi/raw_ip) is root-only; the boot hook sets it to Y.
 * Exit status: 0 = stopped by a signal, 1 = setup failed, 2 = call dropped by the network/modem.
 */
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define SVC_CTL 0x00
#define SVC_WDS 0x01
#define SVC_WDA 0x1a

static const char *dev = "/dev/cdc-wdm0", *ifsrc = "wwan0", *ifname = "ppp0", *apn;
static int fd = -1, profile = 1, test;
static uint8_t wds_cid, ctl_tid;
static uint16_t svc_tid;
static uint32_t handle;
static int have_handle, renamed;
static volatile sig_atomic_t stop_sig;
static uint8_t rx[4096];

static void logm(const char *fmt, ...) {
  va_list ap; char b[512];
  va_start(ap, fmt); vsnprintf(b, sizeof b, fmt, ap); va_end(ap);
  fprintf(stderr, "qmidial: %s\n", b);
  int l = open("/dev/kmsg", O_WRONLY | O_CLOEXEC);  /* also in dmesg, handy when started by rild */
  if (l >= 0) { dprintf(l, "qmidial: %s\n", b); close(l); }
}

static int run(const char *fmt, ...) {
  va_list ap; char b[512];
  va_start(ap, fmt); vsnprintf(b, sizeof b, fmt, ap); va_end(ap);
  int r = system(b);
  if (r != 0) logm("command failed (%d): %s", r, b);
  return r;
}

static void put16(uint8_t *p, uint16_t v) { p[0] = v; p[1] = v >> 8; }
static uint16_t get16(const uint8_t *p) { return p[0] | p[1] << 8; }
static uint32_t get32(const uint8_t *p) { return p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24; }

/* TLV builder */
struct msg { uint8_t b[512]; int n; };
static void tlv(struct msg *m, uint8_t t, const void *v, uint16_t l) {
  m->b[m->n] = t; put16(m->b + m->n + 1, l); memcpy(m->b + m->n + 3, v, l); m->n += 3 + l;
}
static void tlv8(struct msg *m, uint8_t t, uint8_t v) { tlv(m, t, &v, 1); }
static void tlv32(struct msg *m, uint8_t t, uint32_t v) {
  uint8_t b[4] = { v, v >> 8, v >> 16, v >> 24 }; tlv(m, t, b, 4);
}

/* find TLV t in a response's TLV area */
static const uint8_t *find(const uint8_t *tl, int len, uint8_t t, uint16_t *l) {
  int i = 0;
  while (i + 3 <= len) {
    uint16_t n = get16(tl + i + 1);
    if (i + 3 + n > len) break;
    if (tl[i] == t) { if (l) *l = n; return tl + i + 3; }
    i += 3 + n;
  }
  return NULL;
}

/* Send a request and wait for its response. Returns the QMI error code (0 = success, -1 = I/O or timeout),
 * with *tl / *tlen pointing at the response TLVs. Indications and unrelated messages are skipped. */
static int request(uint8_t svc, uint8_t cid, uint16_t msgid, struct msg *m, int timeout_ms,
                   const uint8_t **tl, int *tlen) {
  uint8_t b[600]; int hl = svc == SVC_CTL ? 6 : 7, n = 6 + hl + m->n;
  uint16_t tid;
  b[0] = 0x01; put16(b + 1, n - 1); b[3] = 0x00; b[4] = svc; b[5] = cid;
  b[6] = 0x00;
  if (svc == SVC_CTL) { tid = ++ctl_tid ? ctl_tid : ++ctl_tid; b[7] = tid; }
  else { tid = ++svc_tid ? svc_tid : ++svc_tid; put16(b + 7, tid); }
  put16(b + 6 + hl - 4, msgid); put16(b + 6 + hl - 2, m->n);
  memcpy(b + 6 + hl, m->b, m->n);
  if (write(fd, b, n) != n) { logm("write %s: %s", dev, strerror(errno)); return -1; }
  struct timespec t0; clock_gettime(CLOCK_MONOTONIC, &t0);
  for (;;) {
    struct timespec t1; clock_gettime(CLOCK_MONOTONIC, &t1);
    int left = timeout_ms - (int)((t1.tv_sec - t0.tv_sec) * 1000 + (t1.tv_nsec - t0.tv_nsec) / 1000000);
    if (left <= 0) { logm("no reply to service 0x%02x message 0x%04x", svc, msgid); return -1; }
    struct pollfd p = { fd, POLLIN, 0 };
    int r = poll(&p, 1, left);
    if (r < 0) { if (errno == EINTR) continue; return -1; }
    if (r == 0) continue;
    int got = read(fd, rx, sizeof rx);
    if (got < 0) { if (errno == EINTR || errno == EAGAIN) continue; logm("read: %s", strerror(errno)); return -1; }
    if (got < 13 || rx[0] != 0x01 || rx[4] != svc) continue;
    if (svc != SVC_CTL && rx[5] != cid) continue;
    int o = 6, rtid, flags = rx[o];
    if (svc == SVC_CTL) { rtid = rx[o + 1]; o += 2; } else { rtid = get16(rx + o + 1); o += 3; }
    uint16_t rmsg = get16(rx + o), rlen = get16(rx + o + 2);
    o += 4;
    if (svc == SVC_CTL ? (flags & 0x01) == 0 : (flags & 0x02) == 0) continue;  /* not a response */
    if (rtid != tid || rmsg != msgid || o + rlen > got) continue;
    *tl = rx + o; *tlen = rlen;
    uint16_t l; const uint8_t *res = find(*tl, rlen, 0x02, &l);
    if (!res || l < 4) return -1;
    return get16(res) == 0 ? 0 : get16(res + 2);
  }
}

static int get_cid(uint8_t svc, uint8_t *cid) {
  struct msg m = { .n = 0 }; const uint8_t *tl; int len; uint16_t l; int e = -1;
  tlv8(&m, 0x01, svc);
  for (int i = 0; i < 4 && e == -1; i++)  /* the first message after opening the device often goes unanswered */
    e = request(SVC_CTL, 0, 0x0022, &m, i ? 3000 : 1500, &tl, &len);
  const uint8_t *v = e == 0 ? find(tl, len, 0x01, &l) : NULL;
  if (!v || l < 2) { logm("no QMI client for service 0x%02x (error %d)", svc, e); return -1; }
  *cid = v[1];
  return 0;
}

static void release_cid(uint8_t svc, uint8_t cid) {
  struct msg m = { .n = 0 }; const uint8_t *tl; int len; uint8_t v[2] = { svc, cid };
  tlv(&m, 0x01, v, 2);
  request(SVC_CTL, 0, 0x0023, &m, 2000, &tl, &len);
}

static void ip4(uint32_t a, char *s) { sprintf(s, "%u.%u.%u.%u", a >> 24, a >> 16 & 255, a >> 8 & 255, a & 255); }

static int pkt_status(void) {  /* 2 = connected, 1 = disconnected, -1 = no answer */
  struct msg m = { .n = 0 }; const uint8_t *tl; int len; uint16_t l;
  if (request(SVC_WDS, wds_cid, 0x0022, &m, 5000, &tl, &len) != 0) return -1;
  const uint8_t *v = find(tl, len, 0x01, &l);
  return v && l >= 1 ? v[0] : -1;
}

static void teardown(void) {
  const uint8_t *tl; int len;
  if (renamed) {
    run("/system/bin/ip link set %s down", ifname);
    run("/system/bin/ip addr flush dev %s", ifname);
    run("/system/bin/ip link set %s name %s", ifname, ifsrc);
    renamed = 0;
  }
  if (have_handle) {
    struct msg m = { .n = 0 };
    tlv32(&m, 0x01, handle);
    int e = request(SVC_WDS, wds_cid, 0x0021, &m, 10000, &tl, &len);
    logm("call stopped (%d)", e);
    have_handle = 0;
  }
  if (wds_cid) { release_cid(SVC_WDS, wds_cid); wds_cid = 0; }
  if (!test) {
    system("/system/bin/setprop net.ppp0.local-ip ''");
    system("/system/bin/setprop net.ppp0.remote-ip ''");
  }
}

static void on_sig(int s) { stop_sig = s; }

int main(int argc, char **argv) {
  int c;
  while ((c = getopt(argc, argv, "d:i:n:p:a:t")) != -1) switch (c) {
    case 'd': dev = optarg; break;
    case 'i': ifsrc = optarg; break;
    case 'n': ifname = optarg; break;
    case 'p': profile = atoi(optarg); break;
    case 'a': apn = optarg; break;
    case 't': test = 1; break;
    default: fprintf(stderr, "usage: qmidial [-d dev] [-i wwan0] [-n ppp0] [-p profile] [-a apn] [-t]\n"); return 1;
  }
  struct sigaction sa = { .sa_handler = on_sig };
  sigaction(SIGTERM, &sa, NULL); sigaction(SIGINT, &sa, NULL); sigaction(SIGHUP, &sa, NULL);
  signal(SIGPIPE, SIG_IGN);

  /* a previous instance killed without cleaning up (rild stopped, so init SIGKILLed it) leaves the QMI
   * interface named ppp0: rename it back so we start from wwan0 */
  if (!test) {
    char p[64];
    snprintf(p, sizeof p, "/sys/class/net/%s/qmi", ifname);
    if (access(p, F_OK) == 0) {
      logm("%s is the QMI interface left from a previous run, renaming it back", ifname);
      run("/system/bin/ip link set %s down", ifname);
      run("/system/bin/ip addr flush dev %s", ifname);
      run("/system/bin/ip link set %s name %s", ifname, ifsrc);
    }
  }

  fd = open(dev, O_RDWR | O_CLOEXEC);
  if (fd < 0) { logm("open %s: %s", dev, strerror(errno)); return 1; }
  { struct pollfd p = { fd, POLLIN, 0 }; while (poll(&p, 1, 0) > 0 && read(fd, rx, sizeof rx) > 0) ; }  /* drain */

  /* CTL sync: releases every QMI client ID, including ones leaked by an instance that was killed
   * (we are the only QMI user on this terminal); the first message after opening often goes unanswered */
  {
    struct msg m = { .n = 0 }; const uint8_t *tl; int len; int e = -1;
    for (int i = 0; i < 4 && e == -1; i++) e = request(SVC_CTL, 0, 0x0027, &m, i ? 3000 : 1500, &tl, &len);
    if (e) logm("CTL sync: error %d", e);
  }
  /* which QMI services the modem offers (CTL get version info) */
  {
    struct msg m = { .n = 0 }; const uint8_t *tl; int len; uint16_t l; int e = -1;
    for (int i = 0; i < 4 && e == -1; i++) e = request(SVC_CTL, 0, 0x0021, &m, i ? 3000 : 1500, &tl, &len);
    const uint8_t *v = e == 0 ? find(tl, len, 0x01, &l) : NULL;
    if (v && l >= 1 && test) {
      char b[400]; int o = 0;
      for (int i = 0; i < v[0] && 1 + i * 5 + 5 <= l && o < 380; i++)
        o += snprintf(b + o, sizeof b - o, " %02x", v[1 + i * 5]);
      logm("services:%s", b);
    }
  }
  /* raw IP on the modem side (the kernel side is the raw_ip sysfs switch, set by the boot hook):
   * WDA set data format, or the older CTL set data format if WDA isn't there or refuses */
  int raw = 0;
  uint8_t wda;
  if (get_cid(SVC_WDA, &wda) == 0) {
    struct msg m = { .n = 0 }; const uint8_t *tl; int len;
    tlv32(&m, 0x11, 2);  /* link layer protocol: raw IP */
    int e = request(SVC_WDA, wda, 0x0020, &m, 5000, &tl, &len);
    uint16_t l; const uint8_t *v = e == 0 ? find(tl, len, 0x11, &l) : NULL;
    if (e) logm("WDA set data format: error %d", e);
    else raw = v && l >= 4 && get32(v) == 2;
    release_cid(SVC_WDA, wda);
  }
  if (!raw) {
    struct msg m = { .n = 0 }; const uint8_t *tl; int len;
    uint8_t lp[2] = { 2, 0 };          /* link protocol: raw IP */
    tlv8(&m, 0x01, 0);                 /* no QoS header */
    tlv(&m, 0x10, lp, 2);
    int e = request(SVC_CTL, 0, 0x0026, &m, 5000, &tl, &len);
    if (e) logm("CTL set data format: error %d", e);
    else raw = 1;
  }
  logm("data format: %s", raw ? "raw IP" : "unchanged (modem refused raw IP)");
  if (get_cid(SVC_WDS, &wds_cid)) return 1;

  /* start the call */
  {
    struct msg m = { .n = 0 }; const uint8_t *tl; int len; uint16_t l;
    tlv8(&m, 0x19, 4);                   /* IPv4 */
    if (apn) tlv(&m, 0x14, apn, strlen(apn));
    else tlv8(&m, 0x31, profile);        /* 3GPP profile index */
    int e = request(SVC_WDS, wds_cid, 0x0020, &m, 90000, &tl, &len);
    if (e == 0) {
      const uint8_t *v = find(tl, len, 0x01, &l);
      if (v && l >= 4) { handle = get32(v); have_handle = 1; }
      logm("call started on profile %d%s", profile, apn ? " with given APN" : "");
    } else if (e == 0x1a) {
      logm("call was already up (no effect)");
    } else {
      const uint8_t *r = e > 0 ? find(tl, len, 0x11, &l) : NULL;
      if (r && l >= 4) logm("start network failed: error %d, reason type %d code %d", e, get16(r), get16(r + 2));
      else logm("start network failed: error %d", e);
      teardown(); return 1;
    }
  }

  /* addresses */
  uint32_t ip = 0, gw = 0, mask = 0, d1 = 0, d2 = 0, mtu = 1500;
  {
    struct msg m = { .n = 0 }; const uint8_t *tl; int len; uint16_t l; const uint8_t *v;
    tlv32(&m, 0x10, 0x0010 | 0x0100 | 0x0200 | 0x2000);  /* DNS, IP address, gateway, MTU */
    int e = request(SVC_WDS, wds_cid, 0x002d, &m, 10000, &tl, &len);
    if (e) { logm("get runtime settings: error %d", e); teardown(); return 1; }
    if ((v = find(tl, len, 0x1e, &l)) && l >= 4) ip = get32(v);
    if ((v = find(tl, len, 0x20, &l)) && l >= 4) gw = get32(v);
    if ((v = find(tl, len, 0x21, &l)) && l >= 4) mask = get32(v);
    if ((v = find(tl, len, 0x15, &l)) && l >= 4) d1 = get32(v);
    if ((v = find(tl, len, 0x16, &l)) && l >= 4) d2 = get32(v);
    if ((v = find(tl, len, 0x29, &l)) && l >= 4 && get32(v) >= 576) mtu = get32(v);
  }
  if (!ip) { logm("no IPv4 address from the modem"); teardown(); return 1; }
  char sip[16], sgw[16], smask[16], sd1[16], sd2[16];
  if (!gw) gw = (ip & 0xffffff00) | ((ip & 0xff) == 1 ? 2 : 1);  /* raw IP has no ARP: any on-link peer works */
  ip4(ip, sip); ip4(gw, sgw); ip4(mask, smask); ip4(d1, sd1); ip4(d2, sd2);
  logm("address set (mtu %u, dns %s)", mtu, d2 ? "x2" : d1 ? "x1" : "none");

  if (test) {
    printf("ip %s\ngateway %s\nmask %s\ndns1 %s\ndns2 %s\nmtu %u\n", sip, sgw, smask, sd1, sd2, mtu);
    teardown();
    return 0;
  }

  /* interface: wwan0 -> ppp0, address with the gateway as peer (like pppd), up */
  run("/system/bin/ip link set %s down", ifsrc);
  if (run("/system/bin/ip link set %s name %s", ifsrc, ifname)) { teardown(); return 1; }
  renamed = 1;
  run("/system/bin/ip addr flush dev %s", ifname);
  if (run("/system/bin/ip addr add %s peer %s dev %s", sip, sgw, ifname) ||
      run("/system/bin/ip link set %s mtu %u up", ifname, mtu)) { teardown(); return 1; }

  /* the properties pppd's /etc/ppp/ip-up sets; the RIL reads them */
  run("/system/bin/setprop net.ppp0.dns1 %s", sd1);
  run("/system/bin/setprop net.ppp0.dns2 %s", d2 ? sd2 : sd1);
  run("/system/bin/setprop net.ppp0.remote-ip %s", sgw);
  run("/system/bin/setprop net.ppp0.gw %s", sgw);
  run("/system/bin/setprop net.ppp0.mask %s", smask);
  run("/system/bin/setprop net.ppp0.local-ip %s", sip);
  run("/system/bin/setprop net.interfaces.defaultroute gprs");

  int rc = 0, misses = 0;
  while (!stop_sig) {
    sleep(5);
    if (stop_sig) break;
    int s = pkt_status();
    if (s == 2) {
      misses = 0;
      /* Android sets the interface MTU to its 1500 default once it takes the link over; put the network's back */
      char p[64], b[16] = ""; snprintf(p, sizeof p, "/sys/class/net/%s/mtu", ifname);
      int f = open(p, O_RDONLY | O_CLOEXEC);
      if (f >= 0) { int n = read(f, b, sizeof b - 1); close(f); if (n > 0) b[n] = 0; }
      if ((unsigned)atoi(b) != mtu && atoi(b) > 0) run("/system/bin/ip link set %s mtu %u", ifname, mtu);
      continue;
    }
    if (s == -1 && ++misses < 3) continue;
    logm("call dropped (status %d)", s);
    have_handle = 0;  /* nothing to stop */
    rc = 2;
    break;
  }
  if (stop_sig) logm("stopping (signal %d)", (int)stop_sig);
  teardown();
  return rc;
}
