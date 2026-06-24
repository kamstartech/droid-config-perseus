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

# 9. Trigger SailfishOS boot
#    The device will disconnect from ADB during reboot.
adb shell "reboot hybridos,sailfish"
```

### Post-Boot Verification

After `reboot hybridos,sailfish`, the device boots into SailfishOS. ADB is **not** available in SailfishOS; use SSH over the USB RNDIS interface instead.

**Access via SSH:**
```bash
# Wait for the device to finish booting (USB network interface should appear on the host)
ssh defaultuser@192.168.2.15   # USB RNDIS, password: sailfish
ssh root@192.168.2.15          # key-based root access if SSH keys were installed in step 6
```

If the SSH connection fails, wait a bit longer for the USB RNDIS interface to come up and for `sshd` to start.

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

## Rollback

If the new rootfs fails, restore from backup:
```bash
adb root
adb shell "rm -rf /data/.stowaway/sailfish/*"
adb shell "tar -xjf /data/local/tmp/sfe-perseus-BACKUP.tar.bz2 -C /data/.stowaway/sailfish/"
```
