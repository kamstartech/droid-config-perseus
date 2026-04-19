#!/bin/sh
# droid-hal-early-init.sh — Mount Android partitions before droid-hal-init
# Called by droid-hal-init.service ExecStartPre
# Perseus (Mi Mix 3) specific: handles dm-verity + raw block device fallback

log() { echo "droid-hal-early-init: $*" > /dev/kmsg 2>/dev/null; }

# Resolve dm device by name via sysfs
find_dm_dev() {
    local name="$1"
    for d in /sys/block/dm-*; do
        [ -f "$d/dm/name" ] || continue
        if [ "$(cat "$d/dm/name")" = "$name" ]; then
            echo "/dev/${d##*/}"
            return 0
        fi
    done
    return 1
}

ensure_mp() { [ -d "$1" ] || mkdir -p "$1"; }

# Mount system_root from dm device (dm-verity) or raw block device
if ! mountpoint -q /system_root 2>/dev/null; then
    ensure_mp /system_root
    SYS_DEV=$(find_dm_dev system)
    if [ -n "$SYS_DEV" ]; then
        log "Mounting system_root from $SYS_DEV"
        mount -t ext4 -o ro,relatime,discard "$SYS_DEV" /system_root
    else
        log "No dm system device, trying /dev/sde48"
        mount -t ext4 -o ro,relatime,discard /dev/sde48 /system_root
    fi
fi

# Bind-mount /system from system_root
if ! mountpoint -q /system 2>/dev/null; then
    ensure_mp /system
    if [ -d /system_root/system ]; then
        log "Bind-mounting /system from /system_root/system"
        mount --bind /system_root/system /system
    elif mountpoint -q /system_root; then
        log "No /system_root/system dir, bind-mounting /system_root"
        mount --bind /system_root /system
    fi
fi

# Mount vendor from dm device or raw block device
if ! mountpoint -q /vendor 2>/dev/null; then
    ensure_mp /vendor
    VEND_DEV=$(find_dm_dev vendor)
    if [ -n "$VEND_DEV" ]; then
        log "Mounting vendor from $VEND_DEV"
        mount -t ext4 -o ro,relatime,discard "$VEND_DEV" /vendor
    else
        log "No dm vendor device, trying /dev/sde47"
        mount -t ext4 -o ro,relatime,discard /dev/sde47 /vendor
    fi
fi

# Mount firmware sub-partitions (raw block devices, no dm-verity)
if ! mountpoint -q /vendor/firmware_mnt 2>/dev/null; then
    ensure_mp /vendor/firmware_mnt
    log "Mounting modem firmware"
    mount -t vfat -o ro /dev/sde46 /vendor/firmware_mnt 2>/dev/null
fi

if ! mountpoint -q /vendor/dsp 2>/dev/null; then
    ensure_mp /vendor/dsp
    log "Mounting DSP"
    mount -t ext4 -o ro /dev/sde44 /vendor/dsp 2>/dev/null
fi

if ! mountpoint -q /vendor/bt_firmware 2>/dev/null; then
    ensure_mp /vendor/bt_firmware
    log "Mounting Bluetooth firmware"
    mount -t vfat -o ro /dev/sde24 /vendor/bt_firmware 2>/dev/null
fi

if ! mountpoint -q /mnt/vendor/persist 2>/dev/null; then
    ensure_mp /mnt/vendor/persist
    log "Mounting persist"
    mount -t ext4 -o rw,noatime /dev/sda15 /mnt/vendor/persist 2>/dev/null
fi

# Create /dev/block/mapper symlinks for processes that expect them
mkdir -p /dev/block/mapper
for d in /sys/block/dm-*; do
    [ -f "$d/dm/name" ] || continue
    name=$(cat "$d/dm/name")
    dev="/dev/${d##*/}"
    [ -e "/dev/block/mapper/$name" ] || ln -sf "$dev" "/dev/block/mapper/$name"
done

log "Done: system=$(mountpoint -q /system && echo ok || echo FAIL) vendor=$(mountpoint -q /vendor && echo ok || echo FAIL)"
