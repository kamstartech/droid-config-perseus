#!/bin/sh
LOGF=/var/log/droid-hal-debug.log
KMSGF=/var/log/droid-hal-kmsg.log
log() { echo "$(date '+%H:%M:%S') startup: $*" >> $LOGF; echo "droid-hal-startup: $*" > /dev/kmsg 2>/dev/null; }

log "startup.sh running"
echo 0 > /proc/sys/kernel/printk_ratelimit 2>/dev/null
echo 0 > /proc/sys/kernel/printk_ratelimit_burst 2>/dev/null
echo on > /proc/sys/kernel/printk_devkmsg 2>/dev/null && log "devkmsg unlimited"
echo 7 > /proc/sys/kernel/printk 2>/dev/null && log "printk level set to 7 (debug)"

# droid-mount-setup.service mounts /dev tmpfs before this service starts.
# We only need to ensure /dev/socket exists, then add hardware-specific nodes.
mkdir -p /dev/socket
chmod 0755 /dev/socket
chown root:root /dev/socket
log "Created /dev/socket"

# usb-moded detects configfs at /sys/kernel/config, but droid-hal's config.mount
# mounts it at /config. Make the standard path available before usb-moded starts.
if mountpoint -q /config 2>/dev/null && ! mountpoint -q /sys/kernel/config 2>/dev/null; then
    mkdir -p /sys/kernel/config
    mount --bind /config /sys/kernel/config 2>/dev/null && log "Bind-mounted /config -> /sys/kernel/config"
fi

create_node() {
    local path="$1"
    local type="$2"
    local major="$3"
    local minor="$4"
    [ -e "$path" ] && return 0
    mkdir -p "$(dirname "$path")"
    mknod "$path" "$type" "$major" "$minor" 2>/dev/null
    chmod 666 "$path"
}

# 1. Populate standard nodes and hardware bridge
create_node /dev/null c 1 3
create_node /dev/zero c 1 5
create_node /dev/full c 1 7
create_node /dev/random c 1 8
create_node /dev/urandom c 1 9
create_node /dev/hw_random c 10 183
create_node /dev/ion c 10 62
create_node /dev/kgsl-3d0 c 238 0
create_node /dev/binder c 10 55
create_node /dev/hwbinder c 10 54
create_node /dev/vndbinder c 10 53
create_node /dev/kmsg c 1 11
mkdir -p /dev/dri
create_node /dev/dri/card0 c 226 0
create_node /dev/dri/renderD128 c 226 128
create_node /dev/dri/controlD64 c 226 64
mkdir -p /dev/pts
mount -t devpts devpts /dev/pts 2>/dev/null

# 2. Populate /dev/input for touch and buttons
log "Populating /dev/input..."
mkdir -p /dev/input
for i in $(seq 0 20); do
    [ -e "/sys/class/input/event$i" ] || continue
    id=$(cat "/sys/class/input/event$i/dev")
    major=${id%:*}
    minor=${id#*:}
    create_node "/dev/input/event$i" c $major $minor
done

log "Partition status: system=$(mountpoint -q /system && echo ok || echo FAIL) vendor=$(mountpoint -q /vendor && echo ok || echo FAIL) system_ext=$(mountpoint -q /system_ext && echo ok || echo FAIL) product=$(mountpoint -q /product && echo ok || echo FAIL) odm=$(mountpoint -q /odm && echo ok || echo FAIL)"
log "Firmware partitions: firmware_mnt=$(mountpoint -q /vendor/firmware_mnt && echo ok || echo FAIL) dsp=$(mountpoint -q /vendor/dsp && echo ok || echo FAIL) persist=$(mountpoint -q /mnt/vendor/persist && echo ok || echo FAIL) bt_fw=$(mountpoint -q /vendor/bt_firmware && echo ok || echo FAIL)"
if ! mountpoint -q /system 2>/dev/null; then
    log "FATAL: /system not mounted (check .mount units)"
    exit 1
fi

# Debug: verify hardware nodes are visible
log "Hardware bridge verification: $(ls -l /dev/hwbinder /dev/input/event0 2>/dev/null | tr '\n' ' ')"

# Pre-exec environment diagnostics
log "=== pre-exec diagnostics ==="
log "  /sys/fs/selinux: $(ls /sys/fs/selinux 2>&1 | head -2 | tr '\n' ' ')"
log "  /dev/__properties__: $(ls /dev/__properties__ 2>&1 | head -2 | tr '\n' ' ')"
log "  /dev/.coldboot_done: $(ls /dev/.coldboot_done 2>&1)"
log "  /system/etc/init: $(ls /system/etc/init 2>&1 | head -3 | tr '\n' ' ')"
log "  /vendor/etc/init: $(ls /vendor/etc/init 2>&1 | head -3 | tr '\n' ' ')"
log "  LD_LIBRARY_PATH: ${LD_LIBRARY_PATH:-(empty)}"
log "=============================="

# Append kmsg (not overwrite) — preserves logs across service restarts
cat /dev/kmsg >> $KMSGF 2>&1 &
KMSG_PID=$!
log "Started kmsg capture (PID $KMSG_PID)"

touch /dev/.coldboot_done
export LD_LIBRARY_PATH=

# selinux_status_open() in libselinux opens /sys/fs/selinux/status and mmap-s it.
# servicemanager/vndservicemanager call it with strict=true → CHECK() → SIGABRT if absent.
# first_stage_init normally mounts selinuxfs; we skip it in hybris, so do it here.
if ! mountpoint -q /sys/fs/selinux 2>/dev/null; then
    mkdir -p /sys/fs/selinux
    mount -t selinuxfs selinuxfs /sys/fs/selinux 2>/dev/null \
        && log "Mounted selinuxfs" \
        || log "WARN: selinuxfs mount failed (kernel may lack CONFIG_SECURITY_SELINUX)"
else
    log "selinuxfs already mounted"
fi

# Remove reboot_on_failure directives from Android init RC files.
# We ensure the Sailfish root is RW as permitted, but /system remains read-only.
mount -o remount,rw / 2>/dev/null

patch_rc_no_reboot() {
    local orig="$1"
    [ -f "$orig" ] || return 0
    local tmp
    tmp=$(mktemp -t hybris-rc.XXXXXX) || return 1
    grep -v 'reboot_on_failure' "$orig" > "$tmp"
    mount --bind "$tmp" "$orig" && log "Patched $(basename $orig): removed reboot_on_failure" \
        || log "WARN: failed to bind-mount patch for $orig"
}

# Patch init.rc: remove reboot_on_failure AND suppress logd start calls.
patch_rc_init_hybris() {
    local orig="$1"
    [ -f "$orig" ] || return 0
    local tmp
    tmp=$(mktemp -t hybris-rc.XXXXXX) || return 1
    sed -e '/reboot_on_failure/d' \
        -e '/[[:space:]]start logd$/d' \
        -e '/[[:space:]]start logd-reinit$/d' \
        -e '/[[:space:]]exec_start bpfloader$/d' \
        -e '/exec.*vdc.*checkpoint/d' \
        -e '/exec.*vdc.*keymaster/d' \
        -e '/[[:space:]]class_start main$/d' \
        -e '/[[:space:]]class_start late_start$/d' \
        -e '/trigger zygote-start/d' \
        "$orig" > "$tmp"
    local before after
    before=$(grep -c 'start logd' "$orig" 2>/dev/null; :)
    after=$(grep -c 'start logd' "$tmp" 2>/dev/null; :)
    local vdc_chk_removed vdc_km_removed
    vdc_chk_removed=$(grep -c 'vdc.*checkpoint' "$orig" 2>/dev/null; :)
    vdc_km_removed=$(grep -c 'vdc.*keymaster' "$orig" 2>/dev/null; :)
    mount --bind "$tmp" "$orig" \
        && log "Patched $(basename $orig): hybris fixes (start logd: ${before:-?}→${after:-?}, vdc checkpoint: ${vdc_chk_removed:-0}, vdc keymaster: ${vdc_km_removed:-0})" \
        || log "WARN: failed to bind-mount hybris patch for $orig"
}

# Display HAL services: strip animation class and task_profiles (Android 15 fix)
patch_rc_display_hal() {
    local orig="$1"
    [ -f "$orig" ] || return 0
    local tmp
    tmp=$(mktemp -t hybris-rc.XXXXXX) || return 1
    sed -e '/onrestart.*surfaceflinger/d' \
        -e '/^service vendor.hwcomposer-2-3 /a\    override' \
        -e '/task_profiles/d' \
        -e 's/class hal animation/class hal/' \
        "$orig" > "$tmp"
    mount --bind "$tmp" "$orig" && log "Patched $(basename $orig): display HAL hybris fixes" \
        || log "WARN: failed to bind-mount display HAL patch for $orig"
}

patch_rc_no_reboot /system/etc/init/vold.rc
patch_rc_no_reboot /system/etc/init/netbpfload.rc
patch_rc_init_hybris /system/etc/init/hw/init.rc
patch_rc_init_hybris /system/etc/init/logd.rc
patch_rc_init_hybris /usr/libexec/droid-hybris/system/etc/init/hw/init.rc
patch_rc_no_reboot /vendor/etc/init/boringssl_self_test.rc
patch_rc_display_hal /vendor/etc/init/android.hardware.graphics.composer@2.3-service.rc
patch_rc_display_hal /vendor/etc/init/vendor.qti.hardware.display.allocator@1.0-service.rc
patch_rc_display_hal /vendor/etc/init/vendor.display.color@1.0-service.rc
patch_rc_display_hal /system/etc/init/surfaceflinger.rc
patch_rc_display_hal /vendor/etc/init/android.hardware.sensors@1.0-service.rc

# Audio HAL service: remove task_profiles and audioserver onrestart to prevent init issues
patch_rc_audio_hal() {
    local orig="$1"
    [ -f "$orig" ] || return 0
    local tmp
    tmp=$(mktemp -t hybris-rc.XXXXXX) || return 1
    sed -e '/task_profiles/d' \
        -e '/onrestart restart audioserver/d' \
        "$orig" > "$tmp"
    mount --bind "$tmp" "$orig" && log "Patched audio HAL $(basename $orig): hybris fixes" \
        || log "WARN: failed to bind-mount audio HAL patch for $orig"
}
patch_rc_audio_hal /vendor/etc/init/android.hardware.audio.service.rc

# USB HAL service: disable it so usb-moded has exclusive gadget control.
# Android's usb-hal fights with usb-moded for /config/usb_gadget/g1.
# Perseus uses android.hardware.usb@1.3-service.dual_role_usb.rc, not init.qcom.usb.rc.
patch_rc_usb_hal() {
    local orig="$1"
    [ -f "$orig" ] || return 0
    local tmp
    tmp=$(mktemp -t hybris-rc.XXXXXX) || return 1
    sed -e '/start vendor.usb-hal/d' \
        -e '/^service vendor.usb-hal-/a\    override\n    disabled' \
        "$orig" > "$tmp"
    mount --bind "$tmp" "$orig" && log "Patched $(basename $orig): disabled USB HAL" \
        || log "WARN: failed to bind-mount USB HAL patch for $orig"
}
# Try both the old qcom RC path and the actual dual-role USB HAL RC on sdm845/perseus.
patch_rc_usb_hal /vendor/etc/init/hw/init.qcom.usb.rc
patch_rc_usb_hal /vendor/etc/init/android.hardware.usb@1.3-service.dual_role_usb.rc

# HADK FAQ 13.9: Devices with qseecomd usually have issues getting to UI.
# Disable it to prevent the restart loop from spamming logs and CPU.
patch_rc_qseecomd() {
    local orig="$1"
    [ -f "$orig" ] || return 0
    local tmp
    tmp=$(mktemp -t hybris-rc.XXXXXX) || return 1
    sed -e '/start vendor.qseecomd/d' \
        -e '/^service vendor.qseecomd /a\    override\n    disabled' \
        "$orig" > "$tmp"
    local removed
    removed=$(grep -c 'start vendor.qseecomd' "$orig" 2>/dev/null; :)
    mount --bind "$tmp" "$orig" \
        && log "Patched $(basename $orig): disabled qseecomd (starts removed: ${removed:-0})" \
        || log "WARN: failed to bind-mount qseecomd patch for $orig"
}
patch_rc_qseecomd /vendor/etc/init/qseecomd.rc

# Clean up stale init state
[ -e /dev/kmsg_debug ] && rm -f /dev/kmsg_debug && log "Removed stale /dev/kmsg_debug"
[ -d /dev/dm-user ]   && rmdir /dev/dm-user    && log "Removed stale /dev/dm-user"
if [ -d /dev/__properties__ ]; then
    rm -rf /dev/__properties__ && log "Removed stale /dev/__properties__"
fi

# Ensure SELinux is permissive
echo 0 > /sys/fs/selinux/enforce 2>/dev/null && log "SELinux set to permissive"

# Android 11+ uses /linkerconfig for dynamic linker configuration.
# The pre-populated ld.config.txt in the SFOS rootfs is often stale (small).
# Regenerate it here to ensure vendor HALs can find their libs.
log "Checking /linkerconfig status..."
if [ -f /linkerconfig/ld.config.txt ]; then
    log "linkerconfig ok: $(wc -c < /linkerconfig/ld.config.txt) bytes"
    log "linkerconfig contents: $(ls -lA /linkerconfig | tr -s ' ' | tr '\n' ' ')"
else
    log "WARN: /linkerconfig/ld.config.txt missing — linker will use defaults"
    log "linkerconfig dir: $(ls -lA /linkerconfig 2>&1 | tr '\n' ' ')"
fi

# Ensure linkerconfig is large enough and contains vendor paths.
# Early-init may have written to the initramfs which gets discarded after switch_root.
if [ ! -f /linkerconfig/ld.config.txt ] || [ "$(stat -c %s /linkerconfig/ld.config.txt 2>/dev/null || echo 0)" -lt 1000 ]; then
    log "Regenerating /linkerconfig/ld.config.txt for Android 15..."
    mkdir -p /linkerconfig
    cat > /linkerconfig/ld.config.txt <<'LDCFG'
dir.system = /system/bin
dir.vendor = /vendor/bin

[system]
additional.namespaces = default
namespace.default.isolated = false
namespace.default.search.paths = /system/lib64/bootstrap:/system/lib64:/system/lib64/hw:/system_ext/lib64:/product/lib64:/odm/lib64:/apex/com.android.runtime/lib64
namespace.default.permitted.paths = /system:/vendor:/system_ext:/product:/odm:/apex:/data

[vendor]
additional.namespaces = default
namespace.default.isolated = false
namespace.default.search.paths = /vendor/lib64:/vendor/lib64/hw:/system/lib64/bootstrap:/system/lib64:/system/lib64/hw:/system_ext/lib64:/product/lib64:/odm/lib64:/apex/com.android.runtime/lib64
namespace.default.permitted.paths = /system:/vendor:/system_ext:/product:/odm:/apex:/data
LDCFG
    log "linkerconfig regenerated: $(wc -c < /linkerconfig/ld.config.txt) bytes"
fi

# Ensure /data exists for HAL services that expect Android data paths
if ! mountpoint -q /data 2>/dev/null; then
    mkdir -p /data
    mount -t tmpfs -o mode=0755,size=64m tmpfs /data && log "Mounted tmpfs on /data"
fi

# Fallback: mount firmware partitions if systemd units failed
if ! mountpoint -q /vendor/firmware_mnt 2>/dev/null; then
    mkdir -p /vendor/firmware_mnt
    mount -t vfat -o ro,shortname=lower,uid=1000,gid=1000,dmask=227,fmask=337 /dev/sde46 /vendor/firmware_mnt 2>/dev/null && log "FALLBACK: mounted /vendor/firmware_mnt" || log "FALLBACK: /vendor/firmware_mnt mount failed"
fi
if ! mountpoint -q /vendor/dsp 2>/dev/null; then
    mkdir -p /vendor/dsp
    mount -t ext4 -o ro,nosuid,nodev,barrier=1 /dev/sde44 /vendor/dsp 2>/dev/null && log "FALLBACK: mounted /vendor/dsp" || log "FALLBACK: /vendor/dsp mount failed"
fi
if ! mountpoint -q /mnt/vendor/persist 2>/dev/null; then
    mkdir -p /mnt/vendor/persist
    mount -t ext4 -o nosuid,nodev,barrier=1 /dev/sda15 /mnt/vendor/persist 2>/dev/null && log "FALLBACK: mounted /mnt/vendor/persist" || log "FALLBACK: /mnt/vendor/persist mount failed"
fi
if ! mountpoint -q /vendor/bt_firmware 2>/dev/null; then
    mkdir -p /vendor/bt_firmware
    mount -t vfat -o ro,shortname=lower,uid=1002,gid=3002,dmask=227,fmask=337 /dev/sde24 /vendor/bt_firmware 2>/dev/null && log "FALLBACK: mounted /vendor/bt_firmware" || log "FALLBACK: /vendor/bt_firmware mount failed"
fi

# Tell systemd we are ready

# Forcibly stop Android's graphics services if they are already running.
# With Mesa KMS we don't need hwcomposer, but we still stub surfaceflinger
# and bootanimation to prevent them from seizing the display.
for svc in surfaceflinger bootanim vendor.hwcomposer-2-3 vendor.livedisplay-sdm; do
    if pgrep -f $svc >/dev/null; then
        log "$svc detected - stopping..."
        stop $svc 2>/dev/null
        killall -9 $svc 2>/dev/null
    fi
done

# Create a persistent stub that returns success immediately.
STUB_BIN=/tmp/hybris-stub
echo '#!/bin/sh' > $STUB_BIN
echo 'exit 0' >> $STUB_BIN
chmod 755 $STUB_BIN

# Stub Android graphics services so they don't compete with Mesa for DRM/KMS.
mount_stub() {
    local target="$1"
    [ -x "$target" ] || return 0
    mount --bind $STUB_BIN "$target" && log "Stubbed $target"
}

mount_stub /system/bin/surfaceflinger
mount_stub /system/bin/bootanimation
mount_stub /system/bin/vdc
# HWC takes DRM master from /dev/dri/card0, blocking Mesa KMS.
# Stub it so droid-hal-init's launch of vendor.hwcomposer-2-3 exits immediately.
mount_stub /vendor/bin/hw/android.hardware.graphics.composer@2.3-service

# Populate /apex tmpfs for Android 15 APEX bionic.
# /system is already mounted by the .mount units before this service runs.
# We populate here, before android_init starts.
if ! mountpoint -q /apex 2>/dev/null; then
    mkdir -p /apex
    mount -t tmpfs -o mode=0755,size=32m tmpfs /apex && log "Mounted tmpfs on /apex"
fi
if [ ! -x /apex/com.android.runtime/bin/linker64 ] && [ -f /system/bin/bootstrap/linker64 ]; then
    log "Populating APEX runtime from /system/bin/bootstrap"
    mkdir -p /apex/com.android.runtime/bin \
              /apex/com.android.runtime/lib64/bionic \
              /apex/com.android.runtime/lib/bionic
    for b in linker64 linker linker_asan linker_asan64 linker_hwasan64; do
        src="/system/bin/bootstrap/$b"
        [ -f "$src" ] && cp "$src" "/apex/com.android.runtime/bin/$b"
    done
    for f in libc.so libdl.so libm.so libdl_android.so; do
        src="/system/lib64/bootstrap/$f"
        if [ -f "$src" ]; then
            cp "$src" "/apex/com.android.runtime/lib64/bionic/$f"
            ln -sf "bionic/$f" "/apex/com.android.runtime/lib64/$f"
        fi
        src="/system/lib/bootstrap/$f"
        if [ -f "$src" ]; then
            cp "$src" "/apex/com.android.runtime/lib/bionic/$f"
            ln -sf "bionic/$f" "/apex/com.android.runtime/lib/$f"
        fi
    done
    log "APEX populated: bin=$(ls /apex/com.android.runtime/bin/ 2>/dev/null | wc -w) lib64=$(ls /apex/com.android.runtime/lib64/bionic/ 2>/dev/null | wc -w)"
fi

# Pre-flight checks for Android 15 HAL prerequisites
if [ -x /apex/com.android.runtime/bin/linker64 ]; then
    log "APEX linker64: OK"
else
    log "WARN: APEX linker64 missing - Android 15 binaries may fail to start"
fi
if [ -f /linkerconfig/ld.config.txt ]; then
    log "Linkerconfig: OK ($(wc -l < /linkerconfig/ld.config.txt) lines)"
else
    log "WARN: /linkerconfig/ld.config.txt missing"
fi

# Mesa KMS mode: we do NOT need HWComposer/hwservicemanager for graphics.
# droid-hal-init still runs for audio, sensors, GPS, etc.
# Ensure DRI driver filenames match what Mesa loader expects.
for dri in msm_drm swrast kms_swrast; do
    target="/usr/lib64/dri/${dri}_dri.so"
    [ -e "$target" ] || ln -sf /usr/lib64/dri/msm_dri.so "$target"
done
log "Mesa DRI symlinks: $(ls /usr/lib64/dri/*_dri.so 2>/dev/null | wc -l) drivers"

# KGSL loads a630_sqe.fw + a630_gmu.bin via request_firmware() when the GPU
# powers on. systemd-udev searches /lib/firmware/ — symlink from /vendor/firmware/.
mkdir -p /lib/firmware
for fw in a630_sqe.fw a630_gmu.bin a630_zap.mdt a630_zap.b00 a630_zap.b01 a630_zap.b02 a630_zap.elf; do
    src="/vendor/firmware/$fw"
    [ -f "$src" ] && ln -sf "$src" "/lib/firmware/$fw" 2>/dev/null
done
log "GPU firmware: $(ls /lib/firmware/a630* 2>/dev/null | wc -l) a630 files linked"

# lipstick setgid removal is handled by systemd ExecStartPre=+/bin/chmod g-s
# in lipstick.service.d/99-mesa-kms.conf. That drop-in runs as root inside the
# SailfishOS namespace, which is reliable. This is a belt-and-suspenders fallback
# that also logs the result unconditionally for diagnosis.
CHMOD_OUT=$(chmod g-s /usr/bin/lipstick 2>&1); CHMOD_RC=$?
log "lipstick setgid: chmod exit=$CHMOD_RC${CHMOD_OUT:+ err: $CHMOD_OUT} perms=$(ls -la /usr/bin/lipstick 2>/dev/null | cut -c1-10 || echo 'not found')"
# Ensure qcrild runtime environment exists before droid-hal-init triggers it.
# init.qcom.rc's post-fs-data block creates these, but in the hybris namespace
# it may run too late (or not at all), causing qcrild to exit status 1.
ensure_qcrild_env() {
    mkdir -p /data/vendor/radio /data/vendor/netmgr /data/vendor/port_bridge \
             /data/vendor/connectivity /data/vendor/modem_config \
             /dev/socket/qmux_radio
    chown system:radio /data/vendor/radio
    chmod 0770 /data/vendor/radio
    chown radio:radio /data/vendor/netmgr /data/vendor/port_bridge /data/vendor/connectivity
    chmod 0770 /data/vendor/netmgr /data/vendor/port_bridge
    chmod 0771 /data/vendor/connectivity
    chown radio:root /data/vendor/modem_config
    chmod 0570 /data/vendor/modem_config
    chown radio:radio /dev/socket/qmux_radio
    chmod 0770 /dev/socket/qmux_radio
    if [ -f /vendor/radio/qcril_database/qcril.db ]; then
        cp -f /vendor/radio/qcril_database/qcril.db /data/vendor/radio/qcril_prebuilt.db
        chown radio:radio /data/vendor/radio/qcril_prebuilt.db
        chmod 0660 /data/vendor/radio/qcril_prebuilt.db
    fi
    printf '%s' '0' > /data/vendor/radio/copy_complete
    chown radio:radio /data/vendor/radio/copy_complete
    chmod 0660 /data/vendor/radio/copy_complete
    printf '%s' '1' > /data/vendor/radio/prebuilt_db_support
    chown radio:radio /data/vendor/radio/prebuilt_db_support
    chmod 0400 /data/vendor/radio/prebuilt_db_support
    printf '%s' '0' > /data/vendor/radio/db_check_done
    chown radio:radio /data/vendor/radio/db_check_done
    chmod 0660 /data/vendor/radio/db_check_done

    # Keep qcrild stderr on the persist partition; tmpfs /data is lost on reboot.
    mkdir -p /mnt/vendor/persist/radio
    chown radio:radio /mnt/vendor/persist/radio
    chmod 0770 /mnt/vendor/persist/radio
    touch /mnt/vendor/persist/radio/qcrild.log
    chown radio:radio /mnt/vendor/persist/radio/qcrild.log
    chmod 0660 /mnt/vendor/persist/radio/qcrild.log

    log "qcrild env: /data/vendor/radio and /mnt/vendor/persist/radio prepared"
}

# Wrap qcrild to capture its stderr. droid-hal-init swallows service stderr by
# default, so we bind-mount a wrapper that logs to the persist partition.
install_qcrild_wrapper() {
    local real=/vendor/bin/hw/qcrild
    local wrap=/tmp/qcrild-wrapper
    local bak=/tmp/qcrild.real
    local logf=/mnt/vendor/persist/radio/qcrild.log
    [ -x "$real" ] || return 0
    cp -af "$real" "$bak" 2>/dev/null || return 0
    cat > "$wrap" <<WRAP
#!/system/bin/sh
# Preserve one prior invocation on the persist partition.
[ -f $logf ] && cp -f $logf ${logf}.prev 2>/dev/null
exec $bak "\$@" > $logf 2>&1
WRAP
    chmod 755 "$wrap"
    mount --bind "$wrap" "$real" 2>/dev/null && log "Wrapped $real -> $wrap (log: $logf)"
}

ensure_qcrild_env
log "Starting droid-hal-init (Mesa KMS mode — no HWC2 required)..."
/sbin/droid-hal-init >> $LOGF 2>&1 &
INIT_PID=$!
log "droid-hal-init PID=$INIT_PID"

# Brief wait for hwservicemanager (needed by audio HIDL and other non-graphics HALs).
log "Waiting for hwservicemanager (non-graphics HALs)..."
for i in $(seq 1 10); do
    if pgrep -f hwservicemanager >/dev/null 2>&1; then
        log "hwservicemanager detected"
        break
    fi
    sleep 1
done

# Give droid-hal-init's post-fs-data action time to run before we start qcrild.
# Starting it too early causes exit status 1 because /data/vendor/radio is not ready.
sleep 2
install_qcrild_wrapper

# Explicitly start HAL services that were disabled by class_start main removal.
# Audio, vibrator and radio are in class main/late_start, so they don't auto-start.
for svc in vendor.audio-hal vendor.qti.vibrator vendor.qcrild; do
    if [ -x /system/bin/setprop ]; then
        /system/bin/setprop ctl.start "$svc" 2>/dev/null && log "Started $svc via setprop"
    elif [ -x /vendor/bin/setprop ]; then
        /vendor/bin/setprop ctl.start "$svc" 2>/dev/null && log "Started $svc via setprop"
    else
        log "setprop not found, cannot start $svc"
    fi
done

# No HWC2 wait needed — Mesa uses DRM/KMS directly.
log "Mesa KMS: skipping HWC2 service wait"

# Tell systemd we are ready
systemd-notify --ready 2>/dev/null && log "Sent sd_notify READY"

# Wait for droid-hal-init to exit
wait $INIT_PID
INIT_RET=$?
log "droid-hal-init EXITED code=$INIT_RET"
