# Wi-Fi driver (bcmdhd.ko)

The PX5 kernel builds the Broadcom driver as a module, and the module shipped in the PX5 vendor
image **can't be used**:
- it was built for 4.19.**101** and the kernel is 4.19.111, so 107 of 280 symbol CRCs differ
  (`disagrees about version of symbol module_layout`)
- worse, the struct layouts differ. Rockchip's 4.19.111 `struct device` is 0x310 bytes, but the module
  thinks it's 0x308. Every `sdio_func` field after it is off by 8, so patching the CRCs would only load
  a broken driver.

So the port uses a `bcmdhd.ko` rebuilt from the matching source. The boot hook bind-mounts
`/data/citaq/bcmdhd.ko` over `/vendor/lib/modules/bcmdhd.ko`, and the Wi-Fi HAL loads it as usual.

## Download

Get `bcmdhd-citaq.ko` from this repo's **Releases** page and verify it:
MD5 `f628ca9839f9b18f66aff51586fbdefa`, 2.3 MB. Rename it to `bcmdhd.ko` for `install_data.py`.

It's GPL. The source is Rockchip's public kernel at the commit below, with the config described here.

## Rebuilding it yourself

Source: `rockchip-linux/kernel`, branch `develop-4.19`, commit **5dedb0163a** (2 Jun 2020,
SUBLEVEL 111, same day as the PX5 kernel build #1152).

1. Config = the PX5 kernel's own config (extract it from the kernel image: `IKCONFIG` is built in, e.g.
   with the kernel's `scripts/extract-ikconfig`), plus `CONFIG_BCMDHD=y` and `CONFIG_AP6XXX=m`.
2. `make ARCH=arm64 HOSTCFLAGS=-fcommon modules_prepare`
3. **`Module.symvers` must carry the running kernel's exact CRCs.** These were read out of the
   PX5 kernel image itself: its `__ksymtab` (PREL32 entries, 11,013 symbols) and `__kcrctab`
   (`module_layout` = 0xda43fad4). Generate `Module.symvers` from those values.
4. Build just the driver, calling the cross compiler directly (Rockchip's `gcc-wrapper.py` turns some
   warnings into errors):
   ```sh
   make ARCH=arm64 CC=aarch64-linux-gnu-gcc M=drivers/net/wireless/rockchip_wlan/rkwifi/bcmdhd modules
   aarch64-linux-gnu-strip --strip-debug bcmdhd.ko
   ```
5. Check it: `modinfo` vermagic should be `4.19.111+ SMP preempt mod_unload modversions aarch64`, and
   there should be 0 CRC mismatches against the kernel. The rebuilt module was also checked against the
   kernel's disassembly (`sdio_func.num` at 0x320, `mmc_host.pm_caps` 0x380, `net_device` 0x880).

## Device tree side

`dtb/make_citaq_a10_dtb.sh` enables SDIO0 (`dwmmc@ff0d0000`, 4-bit, 50 MHz, 1.8 V pads) with an
`mmc-pwrseq-simple` on GPIO3_A4 and host-wake on GPIO3_A6.

One gotcha: the 4.19 MMC core numbers hosts in probe order, and probe order is DT node order. With
SDIO0 ahead of the eMMC, the eMMC became `mmcblk1`, `blkdevparts=mmcblk0:…` matched nothing, and init
dropped to the bootloader. The script moves the SDIO and pwrseq nodes to the end of the tree.

At boot, the driver detects the chip as BCM4345 rev 9 and loads `fw_bcm43456c5_ag.bin` +
`nvram_ap6256.txt`. Both are already in the PX5 vendor image. Some terminals have an AP6255 (BCM43455)
instead; the vendor image has its files too (`fw_bcm43455c0_ag.bin`, `nvram_ap6255.txt`), and the same
driver picks them by chip revision.

**AP6255 firmware crash.** On the first AP6255 terminal, `fw_bcm43455c0_ag.bin` (Broadcom, from the
PX5 image) crashed about 13 minutes after Wi-Fi came up (`TRAP` / `FIRMWARE HALTED` in `dmesg`), and
Wi-Fi stayed down until it was toggled. The image also carries Cypress's build for the same chip,
`fw_cyw43455.bin` (`version 7.45.203 (r724662 CY)`). Bind-mounted over the Broadcom file, it connects
fine and is being soak-tested; the workaround is in the README's Known issues. AP6256 terminals
load `fw_bcm43456c5_ag.bin`, so swapping the 43455 file doesn't affect them.

The RK818's 32 kHz output must be on and set as a clock (reg 0x20 = `xx01`). After a battery pull it
isn't, and the driver times out ("HT Avail timeout"). `citaq-boot.sh` fixes the register and
re-probes SDIO.
