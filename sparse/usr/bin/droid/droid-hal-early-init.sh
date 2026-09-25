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

# Mount real Android userdata partition on /data.
# Perseus historically used a 64 MB tmpfs /data because Android /data/data is
# FBE-encrypted and unreadable in SailfishOS. However, APEX decompression
# (apexd) writes to /data/apex/decompressed/ and needs a real filesystem with
# enough free space. Mounting the userdata partition here gives apexd that
# target while the encrypted /data/data/ sub-tree remains inaccessible.
mount_real_data() {
    mountpoint -q /data 2>/dev/null && return 0
    ensure_mp /data
    # The Sailfish rootfs is a bind-mount of a directory on the userdata
    # partition; /proc/mounts shows the underlying ext4 device mounted at /.
    local data_dev
    data_dev=$(awk '$2 == "/" && $3 == "ext4" {print $1; exit}' /proc/mounts)
    if [ -z "$data_dev" ]; then
        log "WARN: cannot determine userdata device from /proc/mounts"
        return 1
    fi
    log "Mounting real userdata partition $data_dev on /data"
    if mount -t ext4 -o rw,noatime "$data_dev" /data; then
        log "Real userdata mounted on /data"
        # Restore Android /data ownership/permissions.
        chown system:system /data
        chmod 0771 /data
        return 0
    else
        log "WARN: failed to mount real userdata on /data"
        return 1
    fi
}

# Android init.rc marks /data/apex/decompressed as FBE-encrypted
# (encryption=Require). SailfishOS has no FBE key, so apexd fails with
# "Required key not available" when it tries to write decompressed APEXes
# there. Bind-mount an unencrypted sibling directory over it so apexd can
# write to a real filesystem.
ensure_apex_decompression_unencrypted() {
    [ -d /data/apex/decompressed ] || return 0
    ensure_mp /data/.apex-decompressed
    chown root:system /data/.apex-decompressed
    chmod 0755 /data/.apex-decompressed
    if mountpoint -q /data/apex/decompressed 2>/dev/null; then
        umount /data/apex/decompressed 2>/dev/null || true
    fi
    mount --bind /data/.apex-decompressed /data/apex/decompressed && \
        log "Bind-mounted unencrypted /data/.apex-decompressed over /data/apex/decompressed" || \
        log "WARN: failed to bind-mount unencrypted APEX decompression dir"
}

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

# Mount the real Android userdata partition on /data before droid-hal-init
# starts. This gives apexd a real filesystem to decompress compressed APEXes
# into, instead of the 64 MB tmpfs that droid-hal-startup.sh would otherwise
# create.
mount_real_data
ensure_apex_decompression_unencrypted

# /data/misc is FBE-encrypted in SailfishOS, so init.rc post-fs-data actions that
# create /data/misc/camera and /data/misc/cameraserver fail with
# "Required key not available". CameraService and the camera HAL need these
# directories. Mount a writable overlay on /data/misc before droid-hal-init
# parses vendor RC files and starts the camera provider.
ensure_misc_overlay() {
    [ -d /data/misc ] || return 0
    if mountpoint -q /data/misc 2>/dev/null; then
        log "/data/misc overlay already mounted"
        return 0
    fi
    mkdir -p /tmp/misc-upper /tmp/misc-work
    mount -t overlay overlay \
        -o lowerdir=/data/misc,upperdir=/tmp/misc-upper,workdir=/tmp/misc-work \
        /data/misc && \
        log "Mounted overlay on /data/misc (FBE workaround)" || \
        log "WARN: failed to mount /data/misc overlay"
}
ensure_misc_overlay

# Android 15 APEX resolution: bionic libs and linker live in
# /apex/com.android.runtime/ which is mounted by apexd. Use a tmpfs on /apex
# so apexd can bind-mount the activated APEX modules here.
if ! mountpoint -q /apex 2>/dev/null; then
    log "Mounting tmpfs on /apex for Android 15 APEX"
    mkdir -p /apex
    mount -t tmpfs -o mode=0755,size=128m tmpfs /apex
fi

# Populate a bootstrap APEX fallback in the service namespace. Android tools
# such as chcon/setprop/logcat are dynamically linked to /apex/com.android.runtime
# and must work before apexd runs. apexd will bind-mount the real APEX modules
# over these directories inside the same namespace once droid-hal-init starts.
if [ ! -f /apex/com.android.runtime/lib64/bionic/libc.so ]; then
    log "Populating APEX runtime fallback from bootstrap bionic"
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
        log "Populating com.android.i18n APEX fallback"
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
        log "Populating com.android.conscrypt APEX fallback"
        mkdir -p /apex/com.android.conscrypt/lib64
        mkdir -p /apex/com.android.conscrypt/lib
        for f in libcrypto.so libssl.so; do
            [ -f "/system/lib64/$f" ] && cp "/system/lib64/$f" "/apex/com.android.conscrypt/lib64/$f"
            [ -f "/system/lib/$f" ] && cp "/system/lib/$f" "/apex/com.android.conscrypt/lib/$f"
        done
    fi

    log "APEX fallback populated: $(ls /apex/com.android.runtime/lib64/bionic/ 2>/dev/null | wc -w) lib64, $(ls /apex/com.android.runtime/bin/ 2>/dev/null | wc -w) bin"
fi

# Pre-build a patched mediaswcodec.32rc with stdio_to_kmsg.  droid-hal-startup.sh
# will race apexd to bind-mount this over the real APEX file before droid-hal-init
# parses it; pre-building here keeps the critical path inside the race loop down
# to poll + mount --bind only.
prebuild_mediaswcodec_kmsg_rc() {
    local dir=/run/hybris-mediaswcodec-etc
    local out="$dir/mediaswcodec.32rc"
    mkdir -p "$dir"
    cat > "$out" <<'EOF'
##  for SDK releases >= 32
##
service media.swcodec /apex/com.android.media.swcodec/bin/mediaswcodec
    class main
    user mediacodec
    group camera drmrpc mediadrm
    ioprio rt 4
    task_profiles ProcessCapacityHigh
    stdio_to_kmsg
EOF
    chmod 0644 "$out"
    log "Pre-built patched mediaswcodec.32rc at $out"
}
prebuild_mediaswcodec_kmsg_rc

# Linkerconfig: use the full Android-generated config saved from a previous
# Android boot. That config properly isolates vendor/system namespaces and
# prevents vendor HALs from loading a conflicting /system/lib64/libbinder.so.
# Only fall back to the minimal config if no persisted full config exists.
ensure_mp /linkerconfig
PERSIST_LDCFG=/mnt/vendor/persist/ld.config.txt
if [ -f "$PERSIST_LDCFG" ] && [ "$(stat -c %s "$PERSIST_LDCFG" 2>/dev/null || echo 0)" -ge 100000 ]; then
    log "Restoring full linkerconfig from persist ($(stat -c %s "$PERSIST_LDCFG") bytes)"
    # Apply hybris patches in one awk pass:
    #  1. Prepend dir.system for /usr/libexec/droid-hybris/ (minimediaservice namespace)
    #  2. Add droid-hybris lib search path after namespace.default.search.paths = /system/${LIB}
    #  3. Add /system/${LIB} search + /system permitted to [vendor] namespace (qcrild, HALs)
    awk '
      BEGIN {
          done_dir = 0
          done_hybris = 0
          invendor = 0
      }
      /^\[/ { invendor = ($0 == "[vendor]") }
      /^dir\.system = \/usr\/libexec\/droid-hybris\/$/ {
          # Idempotent: only emit if not already at the top
          if (!done_dir) { print; done_dir = 1 }
          next
      }
      FNR == 1 && !done_dir {
          print "dir.system = /usr/libexec/droid-hybris/"
          done_dir = 1
      }
      { print }
      !done_hybris && /^namespace\.default\.search\.paths = \/system\/\$\{LIB\}$/ {
          print "namespace.default.search.paths += /usr/libexec/droid-hybris/system/${LIB}"
          done_hybris = 1
      }
      invendor && /^namespace\.default\.search\.paths \+= \/vendor\/\$\{LIB\}\/egl$/ &&
          !done_vendor_search {
          print "namespace.default.search.paths += /system/${LIB}"
          done_vendor_search = 1
      }
      invendor && /^namespace\.default\.permitted\.paths \+= \/system\/vendor$/ &&
          !done_vendor_permit {
          print "namespace.default.permitted.paths += /system"
          done_vendor_permit = 1
      }
    ' "$PERSIST_LDCFG" > /linkerconfig/ld.config.txt \
        && log "linkerconfig: patched $(wc -l < /linkerconfig/ld.config.txt) lines into bootstrap" \
        || { log "WARN: linkerconfig awk patch failed — copying unpatched persist"; cp -f "$PERSIST_LDCFG" /linkerconfig/ld.config.txt; }
    # Also save to /run/ so startup.sh can re-mount it after SetupMountNamespaces buries
    # /linkerconfig/bootstrap (bootstrap/ is inside /linkerconfig — the new tmpfs hides it).
    cp -f /linkerconfig/ld.config.txt /run/droid-linkerconfig.txt \
        && log "linkerconfig: saved patched copy to /run/droid-linkerconfig.txt" \
        || log "WARN: failed to save linkerconfig to /run"
elif [ -f /linkerconfig/ld.config.txt ] && [ "$(stat -c %s /linkerconfig/ld.config.txt 2>/dev/null || echo 0)" -ge 100000 ]; then
    log "Using existing full linkerconfig (no persist copy available)"
else
    rm -f /linkerconfig/ld.config.txt
    log "Generating minimal linkerconfig fallback for Android 15"
    cat > /linkerconfig/ld.config.txt <<'LDCFG'
dir.system = /usr/libexec/droid-hybris/
dir.system = /system/bin
dir.vendor = /vendor/bin

[system]
additional.namespaces = default
namespace.default.isolated = false
namespace.default.search.paths = /usr/libexec/droid-hybris/system/lib64
namespace.default.search.paths += /system/lib64/bootstrap:/system/lib64:/system/lib64/hw:/system_ext/lib64:/product/lib64:/odm/lib64:/apex/com.android.runtime/lib64:/apex/com.android.i18n/lib64:/apex/com.android.conscrypt/lib64
namespace.default.permitted.paths = /system:/vendor:/system_ext:/product:/odm:/apex:/data:/usr/libexec/droid-hybris
namespace.default.asan.search.paths = /system/lib64

[vendor]
additional.namespaces = default
namespace.default.isolated = false
namespace.default.search.paths = /vendor/lib64:/vendor/lib64/hw:/system/lib64:/system/lib64/bootstrap:/system/lib64/hw:/system_ext/lib64:/product/lib64:/odm/lib64:/apex/com.android.runtime/lib64:/apex/com.android.i18n/lib64:/apex/com.android.conscrypt/lib64
namespace.default.permitted.paths = /system:/vendor:/system_ext:/product:/odm:/apex:/data
namespace.default.asan.search.paths = /vendor/lib64
LDCFG
fi
log "linkerconfig: bootstrap ready — $(wc -l < /linkerconfig/ld.config.txt 2>/dev/null || echo 0) lines"

log "Done: system=$(mountpoint -q /system && echo ok || echo FAIL) vendor=$(mountpoint -q /vendor && echo ok || echo FAIL) apex_tmpfs=$(mountpoint -q /apex && echo ok || echo FAIL)"
