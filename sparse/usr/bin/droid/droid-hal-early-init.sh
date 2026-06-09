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

# Mount system_ext (Android 15 has system_ext as separate partition)
if ! mountpoint -q /system_ext 2>/dev/null; then
    ensure_mp /system_ext
    SYSEXT_DEV=$(find_dm_dev system_ext)
    if [ -n "$SYSEXT_DEV" ]; then
        log "Mounting system_ext from $SYSEXT_DEV"
        mount -t ext4 -o ro,relatime,discard "$SYSEXT_DEV" /system_ext
    fi
fi

# Mount product
if ! mountpoint -q /product 2>/dev/null; then
    ensure_mp /product
    PROD_DEV=$(find_dm_dev product)
    if [ -n "$PROD_DEV" ]; then
        log "Mounting product from $PROD_DEV"
        mount -t ext4 -o ro,relatime,discard "$PROD_DEV" /product
    fi
fi

# Mount odm
if ! mountpoint -q /odm 2>/dev/null; then
    ensure_mp /odm
    ODM_DEV=$(find_dm_dev odm)
    if [ -n "$ODM_DEV" ]; then
        log "Mounting odm from $ODM_DEV"
        mount -t ext4 -o ro,relatime,discard "$ODM_DEV" /odm
    fi
fi

# Create /dev/block/mapper symlinks for processes that expect them
mkdir -p /dev/block/mapper
for d in /sys/block/dm-*; do
    [ -f "$d/dm/name" ] || continue
    name=$(cat "$d/dm/name")
    dev="/dev/${d##*/}"
    [ -e "/dev/block/mapper/$name" ] || ln -sf "$dev" "/dev/block/mapper/$name"
done

# Android 15 APEX resolution: bionic libs and linker are symlinks to
# /apex/com.android.runtime/ which isn't mounted in SFOS. Use tmpfs +
# copies of bootstrap bionic (not symlinks — q.so resolves realpath and
# rejects targets outside permitted namespace paths).
if ! mountpoint -q /apex 2>/dev/null; then
    log "Mounting tmpfs on /apex for Android 15 bionic"
    mkdir -p /apex
    mount -t tmpfs -o mode=0755,size=32m tmpfs /apex
fi

if [ ! -f /apex/com.android.runtime/lib64/bionic/libc.so ]; then
    log "Populating APEX runtime from bootstrap bionic"
    mkdir -p /apex/com.android.runtime/lib64/bionic
    mkdir -p /apex/com.android.runtime/lib/bionic
    mkdir -p /apex/com.android.runtime/bin

    # 64-bit bionic — copy real files (not symlinks)
    for f in libc.so libm.so libdl.so libdl_android.so libclang_rt.hwasan-aarch64-android.so; do
        src="/system/lib64/bootstrap/$f"
        [ -f "$src" ] && cp "$src" "/apex/com.android.runtime/lib64/bionic/$f"
    done
    # q.so also searches /apex/.../lib64/ directly
    for f in libc.so libm.so libdl.so libdl_android.so; do
        [ -f "/apex/com.android.runtime/lib64/bionic/$f" ] && \
            ln -sf "bionic/$f" "/apex/com.android.runtime/lib64/$f"
    done

    # 32-bit bionic
    for f in libc.so libm.so libdl.so libdl_android.so; do
        src="/system/lib/bootstrap/$f"
        [ -f "$src" ] && cp "$src" "/apex/com.android.runtime/lib/bionic/$f"
        [ -f "/apex/com.android.runtime/lib/bionic/$f" ] && \
            ln -sf "bionic/$f" "/apex/com.android.runtime/lib/$f"
    done

    # Linker binaries
    for b in linker64 linker linker_asan linker_asan64 linker_hwasan64; do
        src="/system/bin/bootstrap/$b"
        [ -f "$src" ] && cp "$src" "/apex/com.android.runtime/bin/$b"
    done

    # ICU (com.android.i18n) — essential for Android 15 HALs
    if [ ! -f /apex/com.android.i18n/lib64/libicuuc.so ]; then
        log "Populating com.android.i18n APEX"
        mkdir -p /apex/com.android.i18n/lib64
        mkdir -p /apex/com.android.i18n/lib
        mkdir -p /apex/com.android.i18n/etc

        # Link data files
        [ -d /system/usr/icu ] && ln -sf /system/usr/icu /apex/com.android.i18n/etc/icu

        # Copy libraries from system (they might be in /system/lib64/ or bootstrap)
        for f in libicuuc.so libicui18n.so libicu.so libandroidicu.so; do
            for d in /system/lib64 /system/lib64/bootstrap; do
                [ -f "$d/$f" ] && cp "$d/$f" "/apex/com.android.i18n/lib64/$f" && break
            done
            for d in /system/lib /system/lib/bootstrap; do
                [ -f "$d/$f" ] && cp "$d/$f" "/apex/com.android.i18n/lib/$f" && break
            done
        done
    fi

    # Conscrypt (com.android.conscrypt) — essential for secure HAL communication
    if [ ! -f /apex/com.android.conscrypt/lib64/libcrypto.so ]; then
        log "Populating com.android.conscrypt APEX"
        mkdir -p /apex/com.android.conscrypt/lib64
        mkdir -p /apex/com.android.conscrypt/lib
        for f in libcrypto.so libssl.so; do
            [ -f "/system/lib64/$f" ] && cp "/system/lib64/$f" "/apex/com.android.conscrypt/lib64/$f"
            [ -f "/system/lib/$f" ] && cp "/system/lib/$f" "/apex/com.android.conscrypt/lib/$f"
        done
    fi

    log "APEX populated: $(ls /apex/com.android.runtime/lib64/bionic/ 2>/dev/null | wc -w) lib64, $(ls /apex/com.android.runtime/bin/ 2>/dev/null | wc -w) bin"
fi

# Linkerconfig: always regenerate to prevent stale configs from rootfs
ensure_mp /linkerconfig
rm -f /linkerconfig/ld.config.txt
log "Generating linkerconfig for Android 15"
cat > /linkerconfig/ld.config.txt <<'LDCFG'
dir.system = /system/bin
dir.vendor = /vendor/bin

[system]
additional.namespaces = default
namespace.default.isolated = false
namespace.default.search.paths = /system/lib64/bootstrap:/system/lib64:/system/lib64/hw:/system_ext/lib64:/product/lib64:/odm/lib64:/apex/com.android.runtime/lib64:/apex/com.android.i18n/lib64:/apex/com.android.conscrypt/lib64
namespace.default.permitted.paths = /system:/vendor:/system_ext:/product:/odm:/apex:/data
namespace.default.asan.search.paths = /system/lib64

[vendor]
additional.namespaces = default
namespace.default.isolated = false
namespace.default.search.paths = /vendor/lib64:/vendor/lib64/hw:/system/lib64/bootstrap:/system/lib64:/system/lib64/hw:/system_ext/lib64:/product/lib64:/odm/lib64:/apex/com.android.runtime/lib64:/apex/com.android.i18n/lib64:/apex/com.android.conscrypt/lib64
namespace.default.permitted.paths = /system:/vendor:/system_ext:/product:/odm:/apex:/data
namespace.default.asan.search.paths = /vendor/lib64
LDCFG
log "Linkerconfig generated"

log "Done: system=$(mountpoint -q /system && echo ok || echo FAIL) vendor=$(mountpoint -q /vendor && echo ok || echo FAIL) apex=$([ -f /apex/com.android.runtime/lib64/bionic/libc.so ] && echo ok || echo FAIL)"
