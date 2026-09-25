# SailfishOS Rootfs Deployment (Perseus)

## Build Output

After successful `mic` build:
- **Raw rootfs**: `SailfishOScommunity-release-5.0.0.76-perseus/sfe-perseus-5.0.0.76.tar.bz2`
- **Flashable zip**: `SailfishOScommunity-release-5.0.0.76-perseus/sailfishos-perseus-release-5.0.0.76.zip`

## Deploy to Device (ADB + SSH Method)

This replaces the running SailfishOS rootfs at `/data/.stowaway/sailfish/` without re-flashing the entire ROM.

### Prerequisites
- Device booted to Android (LineageOS)
- ADB root access: `adb root`
- At least 2GB free on `/data` partition
- USB cable connected to the host (for ADB deploy and USB RNDIS SSH afterwards)

### Steps

> **Note:** ADB is only available while the device is in Android. After the reboot into SailfishOS, use SSH over USB RNDIS (IP `192.168.2.15`).

```bash
# 1. Ensure ADB has root
adb root
adb wait-for-device

# 2. Push the new rootfs archive to device
adb push \
  /home/jimmy/hadk/SailfishOScommunity-release-5.0.0.76-perseus/sfe-perseus-5.0.0.76.tar.bz2 \
  /data/local/tmp/sfe-perseus-5.0.0.76.tar.bz2

# 3. Remove old rootfs (preserve if you want rollback)
adb shell "rm -rf /data/.stowaway/sailfish && mkdir -p /data/.stowaway/sailfish"

# 4. Extract new rootfs
adb shell "tar -xjf /data/local/tmp/sfe-perseus-5.0.0.76.tar.bz2 -C /data/.stowaway/sailfish/"

# 5. Enable persistent journald logs (HADK: Logs across reboots)
adb shell "sed -i 's/^Storage=volatile/Storage=automatic/' /data/.stowaway/sailfish/etc/systemd/journald.conf"
adb shell "mkdir -p /data/.stowaway/sailfish/var/log/journal"

# 5b. Deploy /kaos.init — the kaos-way dm-mapper refresh hook.
# The trampoline executes this right after its pivot_root, BEFORE systemd
# starts. It exposes the dm-linear devices Android's first-stage init already
# created (/dev/mapper/<name> + /run/droid/<name>) and re-emits uevents; it
# constructs NO dm-linear table itself. Sailfish's native systemd .mount
# units then consume /run/droid/* (system_root.mount etc.), so the old
# hardcoded-table droid-mount-setup.service path is not needed.
# Source of truth: hybris/droid-configs/sparse/kaos.init
adb push hybris/droid-configs/sparse/kaos.init /data/local/tmp/kaos.init
adb shell "cat /data/local/tmp/kaos.init > /data/.stowaway/sailfish/kaos.init && chmod 755 /data/.stowaway/sailfish/kaos.init && rm -f /data/local/tmp/kaos.init"

# 5c. Disable the native dm-setup path (kaos way). The .mount units ship
# without Requires/After=droid-mount-setup.service and the enable-symlink is
# removed from the sparse overlay, so on a clean deploy this is a no-op; it
# only matters when upgrading a rootfs that still carries the OLD native
# units from the sfe tarball.
adb shell "rm -f /data/.stowaway/sailfish/usr/lib/systemd/system/local-fs.target.wants/droid-mount-setup.service"

# 6. Install SSH keys (optional but recommended for password-less access)
# Replace SSH_KEY with the path to your public key if it differs.
SSH_KEY="${HOME}/.ssh/id_ed25519.pub"
adb shell "mkdir -p /data/.stowaway/sailfish/home/defaultuser/.ssh && chmod 700 /data/.stowaway/sailfish/home/defaultuser/.ssh"
adb shell "mkdir -p /data/.stowaway/sailfish/root/.ssh && chmod 700 /data/.stowaway/sailfish/root/.ssh"
adb push "${SSH_KEY}" /data/local/tmp/perseus_key.pub
adb shell "cat /data/local/tmp/perseus_key.pub > /data/.stowaway/sailfish/home/defaultuser/.ssh/authorized_keys && chmod 600 /data/.stowaway/sailfish/home/defaultuser/.ssh/authorized_keys && chown -R 100000:100000 /data/.stowaway/sailfish/home/defaultuser/.ssh"
adb shell "cat /data/local/tmp/perseus_key.pub > /data/.stowaway/sailfish/root/.ssh/authorized_keys && chmod 600 /data/.stowaway/sailfish/root/.ssh/authorized_keys && chown -R 0:0 /data/.stowaway/sailfish/root/.ssh"
adb shell "rm -f /data/local/tmp/perseus_key.pub"

# 7. Verify init exists
adb shell "ls /data/.stowaway/sailfish/sbin/init"

#    Optional: if mesa-freedreno is included in the adaptation pattern, also verify:
#    adb shell "ls /data/.stowaway/sailfish/usr/lib64/dri/msm_dri.so"

# 8. Clean up temp archive
adb shell "rm -f /data/local/tmp/sfe-perseus-5.0.0.76.tar.bz2"

# 9. Trigger SailfishOS boot — COLD BOOT (power off, then power on).
#    This is the kaos-way path: Android first-stage init → trampoline
#    (init wrapper) → run_init_second_stage() → cold_boot_pivot_root(),
#    which runs /kaos.init (see step 5b) before handing off to Sailfish
#    systemd. The device will disconnect from ADB during reboot; pick
#    "sailfish" in the trampoline ROM selector.
adb reboot  # then power-cycle the device (complete off → on)

# NOTE: `reboot hybridos,sailfish` (warm trampoline --primary handover via
# multirom_boot_hybridos / hybridos_switch_root) is the OTHER boot path and
# is still the "default way": it does NOT execute /kaos.init and instead
# MS_MOVE-relocates Android's already-mounted partitions into the distro
# rootfs. Making that warm path also kaos-way (run /kaos.init before
# handover) is a TODO — see docs/exec-plans/tech-debt-tracker.md (TRD-043).
```

### Post-Boot Verification

After a cold boot with "sailfish" selected in the trampoline ROM selector, the device boots into SailfishOS. ADB is **not** available in SailfishOS; use SSH over the USB RNDIS interface instead.

**Access via SSH:**
```bash
# Wait for the device to finish booting (USB network interface should appear on the host)
ssh defaultuser@192.168.2.15   # USB RNDIS, password: sailfish
ssh root@192.168.2.15          # key-based root access if SSH keys were installed in step 6
```

If the SSH connection fails, wait a bit longer for the USB RNDIS interface to come up and for `sshd` to start.

**Check the kaos-way dm/mount path (boot-0 journal):**
```bash
devel-su
journalctl -b 0 | grep -E 'kaos|kaos-dm-refresh|Droid mount'
# Expected:
#   kernel: trampoline: running /kaos.init before init handoff
#   kernel: [kaos-dm-refresh] uevent add dm-1 (system) ... dm-5 (system_ext)
#   kernel: trampoline: kaos.init exited status=0
#   systemd[1]: Mounted Droid mount for /system_root|/vendor|/product|/odm|/system_ext.
#   droid-hal-startup: Partition status: system=ok vendor=ok ...
# There must be NO 'Failed to mount' for the Droid mount units, and
# droid-hal-startup should report every partition ok.
```

**Check GPU:**
```bash
devel-su
journalctl -u lipstick | grep -i 'GL_RENDERER\|freedreno\|msm'
# Expected: FD630 (NOT llvmpipe/swrast)
```

**Check sensors:**
```bash
journalctl -u sensorfwd | grep -i 'register\|adaptor'
```

**Check radio:**
```bash
journalctl -u ofono | grep -i 'IRadio\|slot'
```

**Check D-Bus telephony access (libdbusaccess / `/proc` hidepid):**
```bash
# /proc must NOT be mounted with hidepid=2
mount | grep "on /proc "
# Expected: proc on /proc type proc (rw,relatime,gid=3009)
# NOT:      proc on /proc type proc (rw,relatime,gid=3009,hidepid=2)

# Should return [ "tel" ], NOT "Caller must be privileged"
DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/100000/dbus/user_bus_socket \
  dbus-send --session --print-reply \
  --dest=org.freedesktop.Telepathy.ConnectionManager.ring \
  /org/freedesktop/Telepathy/ConnectionManager/ring \
  org.freedesktop.Telepathy.ConnectionManager.ListProtocols
```
If this fails with `AccessDenied: Caller must be privileged`, verify `/proc` was remounted without `hidepid=2`. The remount is done by `droid-hal-startup.sh`; on a running device you can fix it with `mount -o remount,hidepid=0 /proc`.

**Check vibration / haptic feedback:**
```bash
# 1. Verify vibrator sysfs nodes are writable by defaultuser
ls -la /sys/class/leds/vibrator/
# Expected: activate, duration, state (and brightness) are 0666

# 2. Verify touch-feedback profile values are non-zero
profileclient -V current | grep -E 'touchscreen.vibration.level|touchscreen.sound.level'
# Expected: both = 1 (or higher)
# If missing or 0, Settings > Sounds and feedback > Touch screen vibration / Touch sounds is off.

# 3. Trigger a touch feedback event
printf "play keyboard_letter\nquit\n" | script -q -c ngf-client /dev/null
# The motor should click briefly.

# 4. If still silent, capture an NGFD verbose log
systemctl --user stop ngfd
ngfd -v &
NGFD_PID=$!
printf "play keyboard_letter\nquit\n" | script -q -c ngf-client /dev/null
wait $NGFD_PID
# Look for droid-vibrator sink activity; if only canberra appears,
# check profile.current.touchscreen.vibration.level (step 2).
```

## Troubleshooting

| Issue | Fix |
|-------|-----|
| `tar: no space left` | Free space on `/data` — `adb shell df -h /data` (run from Android) |
| Boot loops to Android | Check `distros.conf` init path, verify `/data/.stowaway/sailfish/sbin/init` exists |
| No SSH | Check `sshd.socket` is enabled in SailfishOS rootfs; verify USB RNDIS is up on the host |
| Black screen | Check `MESA_LOADER_DRIVER_OVERRIDE=msm` and `msm_dri.so` presence (only if mesa-freedreno is used) |
| Calls/SMS fail; logs show `Caller must be privileged` | Android mounts `/proc` with `hidepid=2,gid=3009`, which stops SailfishOS services from reading caller process credentials. `droid-hal-startup.sh` remounts `/proc` with `hidepid=0` before user-session services start so libdbusaccess works for all users. On a running device use `mount -o remount,hidepid=0 /proc`. |
| No vibration / haptic feedback works only sometimes | Two common causes on `perseus`: (1) `droid-system` udev rules reset vibrator LED sysfs to `0664 system:system` before NGFD opens them, causing the `droid-vibrator` plugin to fail to load. Fixed by `9999-vibrator-permissions.rules` + `vibrator-permissions.conf` tmpfiles rule. (2) `profile.current.touchscreen.vibration.level` is `0`, so `n_haptic_can_handle()` rejects touch events. Fixed by `/etc/profiled/60-perseus-vibration.ini` defaults. Verify with the **Check vibration** commands above. |
| No touch sounds | Same profile root cause as vibration: `profile.current.touchscreen.sound.level` may be `0`. The same `/etc/profiled/60-perseus-vibration.ini` fix sets a default of `1`. |
| Android partitions fail to mount; `droid-hal-startup` reports partition status other than `ok` | The kaos way relies on `/kaos.init` (step 5b) populating `/run/droid/*` before systemd. If it is missing or not executable, the `.mount` units have nothing to consume — re-run step 5b. On an upgraded rootfs, stale `Requires≈After=droid-mount-setup.service` lines in `*.mount` / `droid-hal-prepare.service` can resurrect the old hardcoded-table path; verify they are gone (`grep droid-mount-setup /usr/lib/systemd/system/*.mount`). |

## Rollback

If the new rootfs fails, restore from backup:
```bash
adb root
adb shell "rm -rf /data/.stowaway/sailfish/*"
adb shell "tar -xjf /data/local/tmp/sfe-perseus-BACKUP.tar.bz2 -C /data/.stowaway/sailfish/"
```
