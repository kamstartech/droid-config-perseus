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
package (enables SDK connection, installs devel-su if missing). See TODO-8.

---

## ✅ DONE: ofono binder path correctness

**Background:** Device exposes `@1.4::IRadio/slot1` + `slot2` via HIDL (qcrild).
`binder.conf` now uses `path=/ril_0` and `gbinder.conf` (ApiLevel=35) is present.

**Result (2026-06-16):** Both SIM slots register correctly. No more `Refusing to register slot`
errors. See `TRD-010`.

---

## ✅ DONE: Dual SIM support

**Result (2026-06-16):** Added `binder.d/dual-sim.conf` with `[slot2]` / `path=/ril_1` /
`slot=1` / `radioInterface=1.4`. Both SIMs registered and data/voice verified live.
See `TRD-010`.

---

## ✅ DONE: sensorfwd — sensor adaptor registration

**Result:** All expected hybris sensor adaptors register (`accelerometersensor`,
`alssensor`, `compasssensor`, `gyroscopesensor`, `orientationsensor`, `proximitysensor`).
Auto-rotate verified working. See `TRD-011`.

---

## ✅ DONE: WiFi in SFOS switch_root mode

**Result (2026-06-20):** `vendor.cnss-daemon` is now started explicitly in
`droid-hal-startup.sh`. `iw wlan0 link` shows a working AP association. See `TRD-024`.

**Still to clean up:** Mask the unused `vendor-lib-modules-qca_cld3_wlan.ko.mount` unit
when building RPMs (TODO-6).

---

## TODO-5: Bluetooth

**Background:** `bluebinder.service` is running and `hci0` is present, but the `bt_power`
rfkill entry is soft-blocked, so BlueZ cannot bring the adapter UP. The fix is to add
`rfkill unblock bt_power` to `droid-hal-startup.sh` before `systemd-notify --ready`.

**Verify:**
```bash
journalctl -u bluebinder --no-pager | tail -20
rfkill list
```
Expected after fix: `bt_power` and `hci0` **not** soft-blocked.

**Follow-up:** Once Bluetooth is UP, verify `perseus-update-csd-macs.service` reads the
live MAC from `/sys/class/bluetooth/hci0/address`. See `TRD-024` / `TRD-032`.

---

## TODO-6: WiFi mount unit (when droid-hal RPMs are built)

**Background:** The `vendor-lib-modules-qca_cld3_wlan.ko.mount` unit in the
droid-configs template references `/system/lib/modules/wlan.ko` (enchilada path).
On perseus, WiFi is `icnss` built-in — no `.ko` file exists.

**Action when building RPMs:** Mask this unit in our device sparse:
```
sparse/usr/lib/systemd/system/vendor-lib-modules-qca_cld3_wlan.ko.mount -> /dev/null
```
(Not done yet as the unit is not present/enabled in the current rootfs.)

---

## ✅ DONE: GPU rendering path

**Result:** The display stack now uses `MESA_LOADER_DRIVER_OVERRIDE=zink` end-to-end.
All GUI processes open `/dev/kgsl-3d0`; lipstick maps `libgallium_dri.so` +
`libvulkan_freedreno.so` and renders with hardware acceleration (no llvmpipe/swrast).
See `TRD-022`.

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

---

## TODO-9: NFC

**Background:** NFC packages are commented out in the SailfishOS adaptation/configuration
patterns. The vendor NFC HAL crash-loop was fixed by `TRD-016`, so the HAL layer should now
be reachable once the Sailfish side is enabled.

**Action:** Choose and enable the correct plugin:
- `nfcd-binder-plugin` for Android 8+ HAL, **or**
- `nfcd-pn54x-plugin` for direct pn54x driver access.

Then uncomment the related `Requires:` lines in the patterns, rebuild the rootfs, and verify
`nfc-daemon` registers with D-Bus. See `TRD-035`.

---

## TODO-10: GPS / geoclue

**Background:** `geoclue-provider-hybris-binder` is included in the adaptation pattern, but
GPS has not been verified live. The GNSS HAL services (`glgps`, `ignss_2_0`, `lhd`) are
defined in the Android init but may be disabled in SailfishOS mode.

**Verify:**
```bash
journalctl -u geoclue --no-pager | tail -30
service list | grep -i gnss
```
If the GNSS HAL is not running, explicitly start it in `droid-hal-startup.sh`. See `TRD-036`.

---

## TODO-11: Fingerprint

**Background:** SailfishOS fingerprint support is not configured for perseus. The upstream
`droid-configs-device` sparse templates contain `sailfish-fpd` settings and a
`wait_for_keymint`/`wait_for_keymaster` oneshot, but they have not been copied or validated
for this device.

**Action:**
1. ~~Identify the actual fingerprint HAL on perseus (FPC1020 / Goodix).~~ DONE (July 2026):
   **Goodix** — `vendor.goodix.hardware.fingerprintextension` in `device/xiaomi/perseus/manifest.xml`;
   the standard `android.hardware.biometrics.fingerprint@2.1` HAL comes from the stock vendor manifest.
2. ~~Add the correct sparse files under `/etc/sailfish-fpd/` and `/etc/mce/`.~~ DONE — the
   `sparse-15` templates are packaged automatically (`android_version_major 15`); quirk knobs live
   in `sparse-15/etc/sailfish-fpd/50-settings.ini`, override in device sparse only if enrollment misbehaves.
3. ~~Wire `wait_for_keymint.service` before `sailfish-fpd.service`.~~ DONE, with a device override:
   the sparse-15 template polls for the KeyMint AIDL service, which the keymaster@4.0 (HIDL) vendor
   never provides — it would loop forever, block `multi-user.target`, and wake the CPU at 1 Hz.
   `sparse/usr/bin/droid/wait_for_keymint` (device sparse shadows the template) instead waits for
   `android.hardware.biometrics.fingerprint@2.1::IBiometricsFingerprint` on /dev/hwbinder with a
   120 s bound.
4. **OPEN:** Build the community middleware. `sailfish-devicelock-fpd` is an **official Jolla
   package** (in the `jolla-@RELEASE@` repo already in the kickstart) — nothing to build for it;
   the pattern's `jolla-devicelock-daemon-encsfa` was commented out since the two are mutually
   exclusive (same as the tama/tucana ports). What must be built locally, from
   `hybris/mw/sailfish-fpd-community` (cloned July 2026, with `external/fake_crypt`):
   - Android side (HABUILD): `make libbiometry_fp_api` and `make fake_crypt`
     (fake_crypt is required because perseus is keymaster 4.0), then `rpm/copy-hal.sh`
   - SDK: `build_packages.sh --build=hybris/mw/sailfish-fpd-community` with
     `--spec=rpm/droid-biometry-fp.spec`, `--spec=rpm/droid-fake-crypt.spec` (both
     `--do-not-install`), then once more with the default spec for the daemon.
   Note: `libbiometry_fp_api` is an Android.mk lib from the Android-10 era — expect
   Android-15 build fixes similar to the libhybris camera/media AttributionSourceState work.
5. **OPEN:** Verify the Goodix HAL registers on hwbinder in Sailfish
   (`binder-list -d /dev/hwbinder | grep -i fingerprint`), then enrollment and device-lock
   unlock. See `TRD-037`.
