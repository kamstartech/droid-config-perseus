# SailfishOS Rootfs Deployment (Perseus)

## Build Output

After successful `mic` build:
- **Raw rootfs**: `SailfishOScommunity-release-5.0.0.76-perseus/sfe-perseus-5.0.0.76.tar.bz2`
- **Flashable zip**: `SailfishOScommunity-release-5.0.0.76-perseus/sailfishos-perseus-release-5.0.0.76.zip`

## Deploy to Device (ADB Method)

This replaces the running SailfishOS rootfs at `/data/.stowaway/sailfish/` without re-flashing the entire ROM.

### Prerequisites
- Device booted to Android (LineageOS)
- ADB root access: `adb root`
- At least 2GB free on `/data` partition

### Steps

```bash
# 1. Ensure ADB has root
adb root
adb wait-for-device

# 2. Push the new rootfs archive to device
adb push \
  /home/jimmy/hadk/SailfishOScommunity-release-5.0.0.76-perseus/sfe-perseus-5.0.0.76.tar.bz2 \
  /data/local/tmp/sfe-perseus-5.0.0.76.tar.bz2

# 3. Remove old rootfs (preserve if you want rollback)
adb shell "rm -rf /data/.stowaway/sailfish/*"

# 4. Extract new rootfs
adb shell "tar -xjf /data/local/tmp/sfe-perseus-5.0.0.76.tar.bz2 -C /data/.stowaway/sailfish/"

# 5. Enable persistent journald logs (HADK: Logs across reboots)
adb shell "sed -i 's/^Storage=volatile/Storage=automatic/' /data/.stowaway/sailfish/etc/systemd/journald.conf"
adb shell "mkdir -p /data/.stowaway/sailfish/var/log/journal"

# 6. Verify key files
adb shell "ls /data/.stowaway/sailfish/sbin/init /data/.stowaway/sailfish/usr/lib64/dri/msm_dri.so"

# 7. Clean up temp archive
adb shell "rm -f /data/local/tmp/sfe-perseus-5.0.0.76.tar.bz2"

# 8. Trigger SailfishOS boot
adb shell "reboot hybridos,sailfish"
```

### Post-Boot Verification

After `reboot hybridos,sailfish`, the device boots into SailfishOS.

**Access via SSH:**
```bash
ssh defaultuser@192.168.2.15   # USB RNDIS, password: sailfish
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

## Troubleshooting

| Issue | Fix |
|-------|-----|
| `tar: no space left` | Free space on `/data` — `adb shell df -h /data` |
| Boot loops to Android | Check `distros.conf` init path, verify `/data/.stowaway/sailfish/sbin/init` exists |
| No SSH | Check `sshd.socket` is enabled in SailfishOS rootfs |
| Black screen | Check `MESA_LOADER_DRIVER_OVERRIDE=msm` and `msm_dri.so` presence |

## Rollback

If the new rootfs fails, restore from backup:
```bash
adb root
adb shell "rm -rf /data/.stowaway/sailfish/*"
adb shell "tar -xjf /data/local/tmp/sfe-perseus-BACKUP.tar.bz2 -C /data/.stowaway/sailfish/"
```
