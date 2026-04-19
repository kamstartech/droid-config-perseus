# SailfishOS Perseus — Verification TODOs

These items require booting SFOS and checking logs to verify/fix.
Boot method: `adb shell "reboot hybridos,sailfish"`

**Access after boot:**
```bash
ssh defaultuser@192.168.2.15   # USB RNDIS, password: sailfish
devel-su                        # root shell inside SFOS
journalctl -f                   # live logs
```

---

## ✅ DONE: Touch tap registered as hold

Every tap triggered a long-press. Root cause: `libQt5EglDeviceIntegration` (eglfs built-in
input) and `-plugin evdevtouch` both opened the fts touch device simultaneously. Kernel
splits events between them — neither reader saw a complete press+release.
Fix: `QT_QPA_EGLFS_DISABLE_INPUT=1` in compositor env file.

---

## ✅ DONE: Startup wizard bypass

The startup wizard no longer blocks at the security code page.
- `~/.config/jolla-startupwizard-usersession-done` created → device boots to home screen
- PIN pad fix also in place (nemo-devicelock.socket RuntimeDirectory drop-in)

---

## ✅ DONE: SSH / developer access

- `sshd.socket` enabled in `multi-user.target.wants`
- USB mode: `developer_mode` (RNDIS at 192.168.2.15)
- Password: `sailfish`

**Remaining:** Run `pkcon install jolla-developer-mode` from SSH to install the full
package (enables SDK connection, installs devel-su if missing).

---

## TODO-1: ofono binder path correctness

**Background:** Device exposes `@1.4::IRadio/slot1` + `slot2` via HIDL (qcrild).
Current `binder.conf` has `path=/ril_0` — format inherited from pre-built rootfs.
gbinder.conf (ApiLevel=35) was missing and is now added; this may be sufficient
for auto-discovery, or the path may need updating.

**Verify:**
```bash
journalctl -u ofono --no-pager | grep -i 'IRadio\|slot\|register\|error'
```

**Fix if wrong:** Edit `/etc/ofono/binder.conf`:
```ini
[slot1]
path=/ril_0      # try: slot1  or  android.hardware.radio@1.4::IRadio/slot1
```

---

## TODO-2: Dual SIM — is slot2 needed?

**Background:** VINTF manifest exposes `@1.4::IRadio/slot2`. Current binder.conf
only configures `ExpectSlots=slot1`.

**Verify:** Check if physical SIM tray has 2 cards inserted.

**Fix if needed:** Add to `/etc/ofono/binder.conf`:
```ini
[Settings]
ExpectSlots=slot1,slot2

[slot2]
path=/ril_1
slot=1
```

---

## TODO-3: sensorfwd — sensor adaptor registration

**Background:** Was failing before (MCE D-Bus timeout). Root causes fixed:
- sensorfwd ordering drop-in added (waits for droid-hal.service)
- gbinder.conf now present (required by libhybrissensorfw)

**Verify:**
```bash
journalctl -u sensorfwd --no-pager | grep -i 'register\|error\|hybris\|adaptor'
```
Expected: `hybrisaccelerometeradaptor registered`, etc.

---

## TODO-4: WiFi in SFOS switch_root mode

**Background:** Driver is `icnss` (built into kernel — no loadable .ko needed).
connman and wpa_supplicant are present. `vendor-firmware_mnt.mount` is now properly
enabled in `local-fs.target.wants` so `/vendor/firmware_mnt/image/wlanmdsp.mbn`
should be accessible.

**Verify:**
```bash
journalctl -u connman --no-pager | tail -30
journalctl -u wpa_supplicant --no-pager | tail -20
ip link show wlan0
ls /vendor/firmware_mnt/image/wlan*
```

---

## TODO-5: Bluetooth

**Background:** bluebinder depends on gbinder (now fixed). `vendor-bt_firmware.mount`
is now properly enabled in `local-fs.target.wants` so `/vendor/bt_firmware/` should
be accessible.

**Verify:**
```bash
journalctl -u bluebinder --no-pager | tail -20
ls /vendor/bt_firmware/
```
Expected: `bluetoothd` + `bluebinder` both running, `/dev/rfkill` accessible.

---

## TODO-6: WiFi mount unit (when droid-hal RPMs are built)

**Background:** The `vendor-lib-modules-qca_cld3_wlan.ko.mount` unit in the
droid-configs template references `/system/lib/modules/wlan.ko` (enchilada path).
On perseus, WiFi is icnss built-in — no .ko file exists.

**Action when building RPMs:** Mask this unit in our device sparse:
```
sparse/usr/lib/systemd/system/vendor-lib-modules-qca_cld3_wlan.ko.mount -> /dev/null
```
(Not done yet as the unit is not present/enabled in the current rootfs.)

---

## TODO-7: Verify freedreno GPU initializes correctly

**Background:** Mesa 24.1.3 `msm_dri.so` (freedreno, Adreno 630) was built and deployed
to `/usr/lib64/dri/msm_dri.so`. `MESA_LOADER_DRIVER_OVERRIDE=msm` set in compositor env.
Previously using kms_swrast (LLVMpipe CPU rendering) — causes severe lag.

**Verify:**
```bash
# From SSH, check lipstick log for GL renderer string
journalctl -u lipstick --no-pager | grep -i 'GL_RENDERER\|freedreno\|msm\|FD630\|llvm\|swrast'
# Expected: FD630  (NOT llvmpipe or softpipe)
```

**If still swrast:** Check `msm_dri.so` is present and readable:
```bash
ls -la /usr/lib64/dri/msm_dri.so
file /usr/lib64/dri/msm_dri.so
```

---

## TODO-8: Install jolla-developer-mode package

**Background:** The package RPM is preloaded at `/var/lib/jolla-developer-mode/preloaded/`
but not installed. Its post-install scripts normally handle some developer mode setup.
SSH is already enabled manually but the full package provides `devel-su`, SDK connectivity,
and ensures all developer mode dependencies are in place.

**Action:**
```bash
# From SSH:
devel-su pkcon install jolla-developer-mode
# or if devel-su is not yet available:
su -c 'pkcon install jolla-developer-mode'
```
