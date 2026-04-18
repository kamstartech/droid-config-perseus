# SailfishOS Perseus — Verification TODOs

These items require booting SFOS and checking logs to verify/fix.
All require: `reboot hybridos,sailfish` or namespace start via nethunter-service.

---

## TODO-1: ofono binder path correctness

**Background:** Device exposes `@1.4::IRadio/slot1` + `slot2` via HIDL (qcrild).
Current `binder.conf` has `path=/ril_0` — format inherited from pre-built rootfs.
gbinder.conf (ApiLevel=35) was missing and is now added; this may be sufficient
for auto-discovery, or the path may need updating.

**Verify:**
```
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
```
journalctl -u sensorfwd --no-pager | grep -i 'register\|error\|hybris\|adaptor'
```
Expected: `hybrisaccelerometeradaptor registered`, etc.

---

## TODO-4: WiFi in SFOS switch_root mode

**Background:** Driver is `icnss` (built into kernel — no loadable .ko needed).
connman and wpa_supplicant are present in rootfs but untested.

**Verify:**
```
journalctl -u connman --no-pager | tail -30
journalctl -u wpa_supplicant --no-pager | tail -20
ip link show wlan0
```

**Note:** If wlan0 doesn't appear, check if icnss firmware path
`/vendor/firmware_mnt/image/wlanmdsp.mbn` is accessible (requires
vendor-firmware_mnt.mount to have run).

---

## TODO-5: Bluetooth

**Background:** bluebinder is present and depends on gbinder (now fixed).

**Verify:**
```
journalctl -u bluebinder --no-pager | tail -20
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
