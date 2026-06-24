#!/bin/sh
LOGF=/var/log/droid-hal-debug.log
KMSGF=/var/log/droid-hal-kmsg.log
log() { echo "$(date '+%H:%M:%S') startup: $*" >> $LOGF; echo "droid-hal-startup: $*" > /dev/kmsg 2>/dev/null; }

log "startup.sh running"
echo 0 > /proc/sys/kernel/printk_ratelimit 2>/dev/null
echo 0 > /proc/sys/kernel/printk_ratelimit_burst 2>/dev/null
echo on > /proc/sys/kernel/printk_devkmsg 2>/dev/null && log "devkmsg unlimited"
echo 7 > /proc/sys/kernel/printk 2>/dev/null && log "printk level set to 7 (debug)"

# Android mounts /proc with hidepid=2,gid=3009 (readproc) for app isolation.
# SailfishOS relies on reading /proc/<pid>/status freely (libdbusaccess, ps, etc.),
# and Sailjail handles app sandboxing instead. Undo the Android restriction now,
# before any user-session services start.
mount -o remount,hidepid=0 /proc 2>/dev/null && log "Remounted /proc without hidepid" \
    || log "WARN: failed to remount /proc without hidepid"

# droid-mount-setup.service mounts /dev tmpfs before this service starts.
# We only need to ensure /dev/socket exists, then add hardware-specific nodes.
mkdir -p /dev/socket
chmod 0755 /dev/socket
chown root:root /dev/socket
log "Created /dev/socket"

# Fix /tmp permissions early. systemd tmp.mount leaves /tmp with the wrong
# mode on this device (0771 shell shell), breaking contacts/app semaphores.
chmod 1777 /tmp 2>/dev/null || true
chown root:root /tmp 2>/dev/null || true
log "Fixed /tmp permissions: $(stat -c '%a %U:%G' /tmp 2>/dev/null || echo 'unknown')"

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

# TRD-010/TRD-016: un-gate the libselinux banking spoof for the hybris container.
# external/selinux/libselinux security_getenforce() is hardcoded to report ENFORCING
# (NetHunter banking/Play-Integrity stealth). servicemanager/hwservicemanager do their
# { add } access check in USERSPACE via that function, so the spoof makes them DENY
# vendor-HAL registration here even though the kernel is permissive → HAL SIGABRTs, no
# IRadio, crash-loops. This marker tells the patched security_getenforce() to return the
# REAL kernel state inside SFOS only. Android never creates it, so banking is unaffected.
# Must exist before droid-hal-init starts servicemanager.
touch /dev/.hybris_selinux_real 2>/dev/null \
    && log "Created /dev/.hybris_selinux_real (libselinux reports real enforce state in SFOS)" \
    || log "WARN: could not create /dev/.hybris_selinux_real (HAL registration may stay blocked)"

# Label binder nodes with correct SELinux contexts. In Android these are set by
# ueventd/binderfs; in hybris we create them manually so we must label them.
# MUST run after selinuxfs is mounted (above) — chcon needs /sys/fs/selinux.
/system/bin/chcon u:object_r:binder_device:s0 /dev/binder 2>/dev/null || log "WARN: chcon /dev/binder failed"
/system/bin/chcon u:object_r:hwbinder_device:s0 /dev/hwbinder 2>/dev/null || log "WARN: chcon /dev/hwbinder failed"
/system/bin/chcon u:object_r:vndbinder_device:s0 /dev/vndbinder 2>/dev/null || log "WARN: chcon /dev/vndbinder failed"

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
        -e '/[[:space:]]start odsign$/d' \
        -e '/[[:space:]]start derive_classpath$/d' \
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
# NOTE: patch_rc_disable_service is defined later in this script (after line 362).
# vold is disabled via disabled_services.rc static override instead (works at init parse time).
# The patch_rc_disable_service call is intentionally omitted here to avoid calling
# an undefined function.
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

# Audio HAL service handling.
#
# Primary mode (current): the 64-bit HIDL compat wrapper binds over
# /vendor/lib64/hw/audio.primary.sdm845.so and forwards PulseAudio's calls to
# the 32-bit vendor.audio-hal service. The 32-bit vendor blob then drives the
# audio hardware with the ADM topologies the sdm845 DSP accepts.
#
# Fallback mode: if no wrapper is present, vendor.audio-hal stays disabled and
# PulseAudio loads the 64-bit CAF HAL directly. That path sends unsupported
# ADM commands (ADSP_EUNSUPPORTED), so the wrapper is required for working
# audio.
AUDIO_HIDL_COMPAT_WRAPPER_DROIDHYBRIS=/usr/libexec/droid-hybris/system/lib64/hw/audio.hidl_compat.default.so
AUDIO_HIDL_COMPAT_WRAPPER_VENDOR=/usr/libexec/droid-hybris/vendor/lib64/hw/audio.hidl_compat.default.so
AUDIO_HIDL_COMPAT_WRAPPER_SYSTEM=/system/lib64/hw/audio.hidl_compat.default.so
AUDIO_HIDL_COMPAT_WRAPPER=""
AUDIO_PRIMARY_64=/vendor/lib64/hw/audio.primary.sdm845.so

if [ -f "$AUDIO_HIDL_COMPAT_WRAPPER_DROIDHYBRIS" ]; then
    AUDIO_HIDL_COMPAT_WRAPPER="$AUDIO_HIDL_COMPAT_WRAPPER_DROIDHYBRIS"
elif [ -f "$AUDIO_HIDL_COMPAT_WRAPPER_VENDOR" ]; then
    AUDIO_HIDL_COMPAT_WRAPPER="$AUDIO_HIDL_COMPAT_WRAPPER_VENDOR"
elif [ -f "$AUDIO_HIDL_COMPAT_WRAPPER_SYSTEM" ]; then
    AUDIO_HIDL_COMPAT_WRAPPER="$AUDIO_HIDL_COMPAT_WRAPPER_SYSTEM"
fi

patch_rc_audio_hal() {
    local orig="$1"
    [ -f "$orig" ] || return 0
    local tmp
    tmp=$(mktemp -t hybris-rc.XXXXXX) || return 1
    if [ -f "$AUDIO_HIDL_COMPAT_WRAPPER" ]; then
        # Keep vendor.audio-hal enabled (do not inject 'disabled').
        # Remove task_profiles/audioserver onrestart lines that reference
        # services we do not run in SailfishOS.
        sed -e '/task_profiles/d' \
            -e '/onrestart restart audioserver/d' \
            "$orig" > "$tmp"
        mount --bind "$tmp" "$orig" && log "Patched audio HAL $(basename $orig): hidl_compat wrapper mode (enabled)" \
            || log "WARN: failed to bind-mount audio HAL patch for $orig"
    else
        # Legacy direct-HAL mode: vendor.audio-hal must stay disabled.
        sed -e '/task_profiles/d' \
            -e '/onrestart restart audioserver/d' \
            -e '/^service vendor\.audio-hal /a\    override\n    disabled' \
            "$orig" > "$tmp"
        mount --bind "$tmp" "$orig" && log "Patched audio HAL $(basename $orig): direct 64-bit CAF HAL mode (vendor.audio-hal disabled)" \
            || log "WARN: failed to bind-mount audio HAL patch for $orig"
    fi
}
patch_rc_audio_hal /vendor/etc/init/android.hardware.audio.service.rc

# Null-mount sound_trigger.primary.sdm845.so so the audio HAL's sound trigger
# extension (audio_extn_sound_trigger) cannot load it. Without this, the SVA
# Sound Trigger HAL initializes a session and registers a callback with the
# audio HAL. When vendor.audio-hal's WriteThread calls start_output_stream →
# enable_audio_route, the callback fires on a destroyed mutex → SIGABRT.
# The SoundTriggerHw service doesn't run in SailfishOS so the session is never
# properly torn down. Nulling the library keeps st_dev=NULL so the callback
# path is skipped entirely.
SOUND_TRIGGER_HAL=/vendor/lib/hw/sound_trigger.primary.sdm845.so
if [ -f "$SOUND_TRIGGER_HAL" ]; then
    mount --bind /dev/null "$SOUND_TRIGGER_HAL" \
        && log "Null-mounted $SOUND_TRIGGER_HAL (prevents SVA mutex crash)" \
        || log "WARN: failed to null-mount sound trigger HAL"
fi

# Bind-mount the 64-bit HIDL compat wrapper over the broken 64-bit CAF HAL.
# This must happen before droid-hal-init starts class hal (and thus
# vendor.audio-hal) and before PulseAudio opens the audio device.
if [ -f "$AUDIO_HIDL_COMPAT_WRAPPER" ] && [ -f "$AUDIO_PRIMARY_64" ]; then
    mount --bind "$AUDIO_HIDL_COMPAT_WRAPPER" "$AUDIO_PRIMARY_64" \
        && log "Bind-mounted audio.hidl_compat.default -> $AUDIO_PRIMARY_64" \
        || log "WARN: failed to bind-mount audio HIDL compat wrapper"

fi

# Patch audio policy config: add AUDIO_FORMAT_PCM_16_BIT profiles to primary output
# and deep_buffer ports so pulseaudio module-droid-card finds a compatible format.
# The vendor config only declares AUDIO_FORMAT_PCM_24_BIT_PACKED which is not in
# pulseaudio-modules-droid's supported format list, causing droid-sink to fail to open.
AUDIO_POLICY_PATCH=/usr/share/perseus-audio-policy/audio_policy_configuration.xml
if [ -f "$AUDIO_POLICY_PATCH" ] && [ -f /vendor/etc/audio_policy_configuration.xml ]; then
    mount --bind "$AUDIO_POLICY_PATCH" /vendor/etc/audio_policy_configuration.xml \
        && log "Patched audio_policy_configuration.xml: added PCM_16_BIT to primary output and deep_buffer" \
        || log "WARN: audio policy config patch failed"
fi

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

# Android init.rc sets /tmp to 0771 shell shell, which breaks SailfishOS
# app semaphores (qtcontacts-sqlite, etc.). Patch it to 1777 root:root.
patch_rc_init_tmp() {
    local orig="$1"
    [ -f "$orig" ] || return 0
    local tmp
    tmp=$(mktemp -t hybris-rc.XXXXXX) || return 1
    sed -e 's/^    chown shell shell \/tmp$/    chown root root \/tmp/' \
        -e 's/^    chmod 0771 \/tmp$/    chmod 1777 \/tmp/' \
        "$orig" > "$tmp"
    if diff -q "$orig" "$tmp" >/dev/null 2>&1; then
        rm -f "$tmp"
        return 0
    fi
    mount --bind "$tmp" "$orig" && log "Patched $(basename $orig): /tmp -> 1777 root:root" \
        || log "WARN: failed to bind-mount init.rc tmp patch for $orig"
}
patch_rc_init_tmp /usr/libexec/droid-hybris/system/etc/init/hw/init.rc

# HADK FAQ 13.9: Devices with qseecomd usually have issues getting to UI.
# Disabled by default to prevent restart loops.
# TRD-010 DIAGNOSTIC (2026-06-11): qseecomd is required for modem PIL
# firmware authentication. To capture why it crashes, we temporarily enable
# it with a stderr wrapper and stdio_to_kmsg. Revert to the disable patch
# once the crash is understood.
patch_rc_qseecomd_disable() {
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

patch_rc_qseecomd_enable() {
    local orig="$1"
    [ -f "$orig" ] || return 0
    local tmp
    tmp=$(mktemp -t hybris-rc.XXXXXX) || return 1
    # NOTE: /system/lib64 is REQUIRED here. qseecomd dlopens /system/lib64/libc++.so,
    # which is NOT present in /vendor/lib64. Removing /system/lib64 causes
    # `CANNOT LINK EXECUTABLE "/vendor/bin/qseecomd": library "libc++.so" not accessible`
    # → exit status 1 → crash loop (verified 2026-06-12, and it takes qcrild down with it).
    # Do NOT strip /system/lib64 from qseecomd to chase the TRD-018 libbinder mix —
    # qseecomd is not a confirmed source of the SYST/VNDR mismatch (the real offenders
    # are vendor HALs provider@2.4 and vendor.display.color@1.0). TRD-018 must be fixed
    # at those HALs, not here.
    sed -e '/start vendor.qseecomd/d' \
        -e '/^service vendor.qseecomd /a\    stdio_to_kmsg' \
        -e '/^service vendor.qseecomd /a\    setenv LD_LIBRARY_PATH /apex/com.android.i18n/lib64:/apex/com.android.conscrypt/lib64:/apex/com.android.runtime/lib64:/vendor/lib64:/system/lib64' \
        "$orig" > "$tmp"
    mount --bind "$tmp" "$orig" \
        && log "Patched $(basename $orig): enabled qseecomd with LD_LIBRARY_PATH + stdio_to_kmsg" \
        || log "WARN: failed to bind-mount qseecomd enable patch for $orig"
}

# TRD-010: qseecomd is required for modem PIL firmware authentication.
# It needs the same APEX LD_LIBRARY_PATH injection we already use for qcrild
# (libandroidicu.so lives in /apex/com.android.i18n/lib64). Keep the original
# binary path to avoid SELinux label issues; capture stderr via stdio_to_kmsg.
patch_rc_qseecomd_enable /vendor/etc/init/qseecomd.rc
# To disable qseecomd again, replace the above with:
# patch_rc_qseecomd_disable /vendor/etc/init/qseecomd.rc

# Force qcrild to run in the rild domain. ComputeContextFromExecutable computes
# the correct domain but never calls setexeccon with it — it only uses the result
# for socket labels. Without an explicit seclabel, qcrild stays in init domain.
#
# TRD-010 FIX: inject `setenv LD_LIBRARY_PATH` so qcrild can resolve libandroidicu.so.
# qcrild links /system/lib64/libsqlite.so, which needs libandroidicu.so — that lib
# lives only in the i18n APEX (/apex/com.android.i18n/lib64), and the linker does
# not search it from the default namespace, so qcrild fails with
# "CANNOT LINK EXECUTABLE ... libandroidicu.so not found" and exits status 1.
# Adding the APEX lib dirs to the search path resolves it. (This is what the old
# bind-mount wrapper's LD_LIBRARY_PATH did; the rc setenv is cleaner — no wrapper,
# no /tmp copy, no SELinux relabel, and it applies pre-unshare like the seclabel.)
#
# DIAGNOSTIC (TRD-010, temporary): `stdio_to_kmsg` redirects qcrild stdout/stderr
# to /dev/kmsg (captured into $KMSGF). Keep for one boot to confirm the link error
# is gone, then remove.
patch_rc_qcrild() {
    local orig="$1"
    [ -f "$orig" ] || return 0
    local tmp
    tmp=$(mktemp -t hybris-rc.XXXXXX) || return 1
    # AIRTIGHT (TRD-018): do NOT inject LD_LIBRARY_PATH. qcrild's entire dependency
    # tree is vendor-resolvable. Its NEEDED libs (libcutils, liblog, libril-qc-hal-qmi,
    # libhardware_legacy, libutils, libc++, libc, libm, libdl) all live in /vendor, and the
    # transitive libsqlite pulled via libril-qc-hal-qmi resolves to the SELF-CONTAINED
    # /vendor/lib64/libsqlite.so (NEEDED: liblog,libc++,libc,libm,libdl — NO libandroidicu,
    # NO libbinder). The /system libsqlite needs libandroidicu, which is the chain that
    # dragged in /system/lib64/libbinder.so → "Mixing copies of libbinder" Parcel aborts.
    # Injecting the apex search paths is precisely what let the /system side win. With pure
    # vendor-namespace resolution qcrild stays airtight: vendor libsqlite + vendor libc++ +
    # vendor libbinder only. No /system, no mix — and no libbinder bind-mount needed.
    sed -e "/^service vendor\.qcrild /a\\    seclabel u:r:rild:s0" \
        -e "/^service vendor\.qcrild2 /a\\    seclabel u:r:rild:s0" \
        -e "/^service vendor\.qcrild3 /a\\    seclabel u:r:rild:s0" \
        -e "/^service vendor\.qcrild /a\\    stdio_to_kmsg" \
        -e "/^service vendor\.qcrild2 /a\\    stdio_to_kmsg" \
        -e "/^service vendor\.qcrild3 /a\\    stdio_to_kmsg" \
        "$orig" > "$tmp"
    mount --bind "$tmp" "$orig" && log "Patched $(basename $orig): seclabel + stdio_to_kmsg (NO LD_LIBRARY_PATH — airtight vendor resolution, TRD-018)" \
        || log "WARN: failed to bind-mount qcrild patch for $orig"
}
patch_rc_qcrild /vendor/etc/init/qcrild.rc

# Generic patch: inject 'override' + 'disabled' into every service block in the file.
# Use for Android-only services that have no SailfishOS consumer and just crash-loop.
patch_rc_disable_service() {
    local orig="$1"
    [ -f "$orig" ] || return 0
    local tmp
    tmp=$(mktemp -t hybris-rc.XXXXXX) || return 1
    sed -e '/^service /a\    override\n    disabled' "$orig" > "$tmp"
    mount --bind "$tmp" "$orig" && log "Patched $(basename $orig): disabled all services" \
        || log "WARN: failed to bind-mount disable patch for $orig"
}

# SailfishOS does not use Android keystore, wifi HAL, or capability config store.
# Disabling them stops the crash-loop spam and reduces boot CPU.
patch_rc_disable_service /system/etc/init/keystore2.rc
patch_rc_disable_service /vendor/etc/init/android.hardware.wifi-service.rc
patch_rc_disable_service /vendor/etc/init/vendor.qti.hardware.capabilityconfigstore@1.0-service.rc

# vendor.display.color@1.0-service: 64-bit Android-30 vintage (libhidltransport), no SFOS consumer.
# camera.provider@2.4-service: re-enabled for camera bring-up (2026-06-16).
# The old SYST/VNDR libbinder mix concern (TRD-018) no longer applies now that linkerconfig
# is fully restored from persist and the vendor namespace resolves cleanly.
patch_rc_disable_service /vendor/etc/init/vendor.display.color@1.0-service.rc

# Clean up stale init state
[ -e /dev/kmsg_debug ] && rm -f /dev/kmsg_debug && log "Removed stale /dev/kmsg_debug"
[ -d /dev/dm-user ]   && rmdir /dev/dm-user    && log "Removed stale /dev/dm-user"
if [ -d /dev/__properties__ ]; then
    rm -rf /dev/__properties__ && log "Removed stale /dev/__properties__"
fi

# Ensure SELinux is permissive
echo 0 > /sys/fs/selinux/enforce 2>/dev/null && log "SELinux set to permissive"

# Android 11+ uses /linkerconfig for dynamic linker configuration.
# /etc/droid-hybris/ld.config.txt is a pre-built patched version of the Android-generated
# linkerconfig that adds droid-hybris binary paths and vendor /system namespace access.
# It is bind-mounted after droid-hal-init's SetupMountNamespaces (see below).
LIVE_LDCFG=/linkerconfig/ld.config.txt
mkdir -p /linkerconfig
log "linkerconfig: bootstrap patched in early-init — will re-mount after SetupMountNamespaces"

# Ensure /data exists for HAL services that expect Android data paths.
# TRD-010: qcrild and droid-hal-init need Android /data/property (persist
# properties) and /data/vendor/modem_config. The Sailfish rootfs lives on the
# userdata partition, and after switch_root the original Android /data directory
# is no longer visible. Android /data is also FBE-encrypted, so it cannot simply
# be bind-mounted. We keep a tmpfs /data and populate the specific files that
# the modem stack needs from the firmware partition and a pre-captured snapshot.
if ! mountpoint -q /data 2>/dev/null; then
    mkdir -p /data
    mount -t tmpfs -o mode=0755,size=64m tmpfs /data && log "Mounted tmpfs on /data"
fi

# TRD-010: If Android's decrypted /data/vendor tree is not available (e.g.
# FBE-encrypted userdata), qcrild still needs a populated /data/vendor/modem_config
# to boot the modem. Copy the mcfg files from the firmware partition.
populate_modem_config() {
    local src=/vendor/firmware_mnt/image/modem_pr/mcfg/configs
    local dst=/data/vendor/modem_config
    if [ -d "$dst/mcfg_sw" ] && [ -n "$(ls -A "$dst/mcfg_sw" 2>/dev/null)" ]; then
        log "modem_config already populated"
        return 0
    fi
    if [ ! -d "$src" ]; then
        log "WARN: modem config source $src not found"
        return 1
    fi
    mkdir -p "$dst"
    cp -a "$src"/* "$dst/" 2>/dev/null && \
        log "Populated $dst from $src ($(find "$dst" -type f 2>/dev/null | wc -l) files)" \
        || log "WARN: failed to populate $dst"
    chown -R radio:root "$dst" 2>/dev/null || true
    chmod -R 0440 "$dst" 2>/dev/null || true
    find "$dst" -type d -exec chmod 0550 {} + 2>/dev/null || true
}
populate_modem_config

# TRD-010: Android's /data/property is FBE-encrypted and not directly readable
# from Sailfish. Copy the persist property snapshot taken from Android into the
# legacy /data/property directory so droid-hal-init loads them for qcrild.
populate_persist_properties() {
    local src=/etc/hybridos/persist-props.txt
    local bin_src=/etc/hybridos/persistent_properties
    local dst=/data/property
    mkdir -p "$dst"

    # Android 10+ stores persist props in a single binary file; copy it verbatim
    # if available so droid-hal-init's property service loads it natively.
    if [ -f "$bin_src" ]; then
        cp -a "$bin_src" "$dst/persistent_properties" 2>/dev/null \
            && log "Copied $bin_src -> $dst/persistent_properties" \
            || log "WARN: failed to copy $bin_src"
        chmod 600 "$dst/persistent_properties" 2>/dev/null || true
    fi

    if [ ! -f "$src" ]; then
        log "WARN: persist property snapshot $src not found"
        return 1
    fi
    # droid-hal-init legacy mode: one file per property, filename = property name
    while IFS='=' read -r key value; do
        [ -z "$key" ] && continue
        # Skip keys with invalid characters for a filename
        if printf '%s' "$key" | grep -q '[/"\\]'; then
            continue
        fi
        printf '%s' "$value" > "$dst/$key" 2>/dev/null || true
    done < "$src"
    # droid-hal-init reads these as root; keep ownership permissive
    chmod -R 600 "$dst" 2>/dev/null || true
    log "Populated $dst with $(find "$dst" -maxdepth 1 -type f 2>/dev/null | wc -l) persist properties from $src"
}
populate_persist_properties

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

# Stub SurfaceFlinger and bootanimation — libhybris EGL renders directly
# via HWComposer so SF must not run. HWComposer itself is NOT stubbed.
STUB_BIN=/tmp/hybris-stub
echo '#!/bin/sh' > $STUB_BIN
echo 'exit 0' >> $STUB_BIN
chmod 755 $STUB_BIN

mount_stub() {
    local target="$1"
    [ -x "$target" ] || return 0
    mount --bind $STUB_BIN "$target" && log "Stubbed $target"
}

mount_stub /system/bin/surfaceflinger
mount_stub /system/bin/bootanimation
mount_stub /system/bin/vdc

# Pre-flight checks for Android 15 HAL prerequisites
if [ -f /linkerconfig/ld.config.txt ]; then
    log "Linkerconfig: OK ($(wc -l < /linkerconfig/ld.config.txt) lines)"
else
    log "WARN: /linkerconfig/ld.config.txt missing"
fi

# TRD-018: qcrild (and other vendor HALs) end up loading both
# /system/lib64/libbinder.so and /vendor/lib64/libbinder.so. The two copies
# have different build IDs and libbinder's runtime header check aborts IPC
# transactions with "Mixing copies of libbinder". Force every process in the
# Android container to use the vendor copy by bind-mounting it over the system
# path. This is safe because the vendor variant is a superset of the system ABI.
for libdir in lib lib64; do
    sys="/system/${libdir}/libbinder.so"
    ven="/vendor/${libdir}/libbinder.so"
    if [ -f "$sys" ] && [ -f "$ven" ]; then
        mount --bind "$ven" "$sys" 2>/dev/null \
            && log "TRD-018: bound $ven -> $sys" \
            || log "WARN: failed to bind $ven -> $sys"
    fi
done

# KGSL loads a630_sqe.fw + a630_gmu.bin via request_firmware() when the GPU
# powers on. systemd-udev searches /lib/firmware/ — symlink from /vendor/firmware/.
mkdir -p /lib/firmware
for fw in a630_sqe.fw a630_gmu.bin a630_zap.mdt a630_zap.b00 a630_zap.b01 a630_zap.b02 a630_zap.elf; do
    src="/vendor/firmware/$fw"
    [ -f "$src" ] && ln -sf "$src" "/lib/firmware/$fw" 2>/dev/null
done
log "GPU firmware: $(ls /lib/firmware/a630* 2>/dev/null | wc -l) a630 files linked"

# TAS2557 smart-amp DSP firmware (loudspeaker PA): NOT symlinked here. The kernel
# requests tas2557_uCDSP.bin at i2c coldplug — far earlier than this script and before
# /vendor is mounted — so a runtime symlink is always too late and would clobber the
# real file. Instead the firmware ships as a real file in the rootfs at
# /lib/firmware/tas2557_uCDSP.bin (droid-configs sparse tree), which the kernel's direct
# loader finds on the SailfishOS udev re-trigger regardless of /vendor mount timing (TRD-017).

# Ensure qcrild runtime environment exists before droid-hal-init triggers it.
# init.qcom.rc's post-fs-data block creates these, but in the hybris namespace
# it may run too late (or not at all), causing qcrild to exit status 1.
# Create modem block-device nodes and by-name symlinks for qcril/rmt_storage.
# ueventd in the hybris namespace cannot read uevents ("Uevent Fd: I/O error"),
# so /dev/block is never populated and the by-name directory does not exist.
# qcrild opens modemst1/modemst2 (EFS/NV storage) on init and exits status 1
# when they are missing. We create only the radio partitions qcril needs.
# major:minor values are perseus/sdm845-specific (read from Android /dev/block).
setup_modem_block_nodes() {
    local byname=/dev/block/platform/soc/1d84000.ufshc/by-name
    mkdir -p "$byname" /dev/block/bootdevice
    ln -sf platform/soc/1d84000.ufshc/by-name /dev/block/bootdevice/by-name 2>/dev/null
    # node            type maj min   partition
    create_node /dev/block/sde46 b 259 37   # modem
    create_node /dev/block/sdf6  b 8   86   # modemst1
    create_node /dev/block/sdf7  b 8   87   # modemst2
    create_node /dev/block/sde36 b 259 27   # fsg
    create_node /dev/block/sdf1  b 8   81   # fsc
    ln -sf /dev/block/sde46 "$byname/modem"    2>/dev/null
    ln -sf /dev/block/sdf6  "$byname/modemst1" 2>/dev/null
    ln -sf /dev/block/sdf7  "$byname/modemst2" 2>/dev/null
    ln -sf /dev/block/sde36 "$byname/fsg"      2>/dev/null
    ln -sf /dev/block/sdf1  "$byname/fsc"      2>/dev/null
    log "modem block nodes: $(ls $byname 2>/dev/null | tr '\n' ' ')"
}

ensure_qcrild_env() {
    setup_modem_block_nodes
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

    mkdir -p /mnt/vendor/persist/radio
    chown radio:radio /mnt/vendor/persist/radio
    chmod 0770 /mnt/vendor/persist/radio

    log "qcrild env: /data/vendor/radio and /mnt/vendor/persist/radio prepared"
}

ensure_qcrild_env

# APEX baseline fix: create the device-mapper control node so apexd can activate
# APEX packages the normal Android way. Each APEX is a dm-verity/dm-linear device;
# apexd opens /dev/device-mapper (the Android path — dmsetup/LVM use the same
# device via /dev/mapper/control). Without this node, apexd-bootstrap fails with
# "Failed to open device-mapper: No such file or directory" → DM_DEV_CREATE fails
# for every package → NO APEX activates, including com.android.runtime (which holds
# the linkerconfig binary). That is the root cause of the hand-faked /apex fixture
# and the frozen /linkerconfig snapshot. The misc minor is dynamic — read it from
# /proc/misc. Created pre-unshare so it's visible in droid-hal-init's namespace
# (shared /dev devtmpfs). Additive: if this fails, the persist-restore fallback
# (droid-hal-early-init) still provides a working linkerconfig.
if [ ! -e /dev/device-mapper ]; then
    dm_minor=$(awk '$2=="device-mapper"{print $1}' /proc/misc 2>/dev/null)
    if [ -n "$dm_minor" ]; then
        mknod /dev/device-mapper c 10 "$dm_minor" && chmod 600 /dev/device-mapper \
            && log "Created /dev/device-mapper (c 10 $dm_minor) for apexd" \
            || log "WARN: mknod /dev/device-mapper failed"
    else
        log "WARN: device-mapper minor not in /proc/misc — apexd APEX activation will fail"
    fi
fi

# droid-hal-init (or the Android 15 base used here) does not set
# ro.property_service.version before clients connect. Without it, libhybris
# setprop falls back to the old protocol and fails to set droid.late_start.
# Inject the property into /system/build.prop so droid-hal-init loads it
# during PropertyLoadBootDefaults (before any setprop client runs).
patch_build_prop_property_version() {
    local orig=/system/build.prop
    [ -f "$orig" ] || return 0
    if grep -q '^ro.property_service.version=' "$orig" 2>/dev/null; then
        log "$orig: ro.property_service.version already present"
        return 0
    fi
    local tmp
    tmp=$(mktemp -t build.prop.XXXXXX) || return 1
    cat "$orig" > "$tmp"
    printf '%s\n' 'ro.property_service.version=2' >> "$tmp"
    mount --bind "$tmp" "$orig" \
        && log "Patched $orig: added ro.property_service.version=2" \
        || log "WARN: failed to bind-mount $orig patch"
}
patch_build_prop_property_version

log "Starting droid-hal-init (HWComposer mode)..."
# Run droid-hal-init in the same mount namespace as this service. APEX mounts
# made by apexd will then be visible to the startup script, allowing setprop,
# logcat and other dynamically-linked Android tools to resolve the runtime APEX.

/sbin/droid-hal-init >> $LOGF 2>&1 &
INIT_PID=$!
log "droid-hal-init PID=$INIT_PID"

# Wait for hwservicemanager process to be running before qcrild starts.
# lshal is unusable here — SELinux denies service_manager find in u:r:init:s0
# even in permissive mode (permissive=0 on that AVC). Process presence is enough:
# hwservicemanager registers the hwbinder socket on startup before accepting clients.
log "Waiting for hwservicemanager to be ready..."
HWSM_READY=0
for i in $(seq 1 15); do
    if pgrep -f hwservicemanager >/dev/null 2>&1; then
        log "hwservicemanager ready (process detected after ${i}s)"
        HWSM_READY=1
        break
    fi
    sleep 1
done
if [ "$HWSM_READY" -eq 0 ]; then
    log "WARNING: hwservicemanager not detected after 15s, starting qcrild anyway"
fi

# DIAGNOSTICS: SELinux runtime state and process domains.
# hwservicemanager may fail silently if its domain is wrong or if the
# kernel is actually enforcing despite security_setenforce(0) success.
log "DIAG: /sys/fs/selinux/enforce = $(cat /sys/fs/selinux/enforce 2>/dev/null || echo 'N/A')"
HWSM_PID=$(pgrep -f hwservicemanager 2>/dev/null | head -1)
if [ -n "$HWSM_PID" ] && [ -f /proc/$HWSM_PID/attr/current ]; then
    log "DIAG: hwservicemanager PID $HWSM_PID domain = $(cat /proc/$HWSM_PID/attr/current 2>/dev/null || echo 'N/A')"
fi
INIT_CTX_PID=$(pgrep -f droid-hal-init 2>/dev/null | head -1)
if [ -n "$INIT_CTX_PID" ] && [ -f /proc/$INIT_CTX_PID/attr/current ]; then
    log "DIAG: droid-hal-init PID $INIT_CTX_PID domain = $(cat /proc/$INIT_CTX_PID/attr/current 2>/dev/null || echo 'N/A')"
fi

# TRD-018: Finish APEX setup. apexd bind-mounts activated APEX at /apex/<name>;
# compressed APEX (conscrypt) fails to decompress, so we populate a minimal
# fallback. This must run before qcrild starts so its APEX LD_LIBRARY_PATH
# resolves.
if [ -x /usr/bin/droid/apex-post-setup.sh ]; then
    log "Running APEX post-setup"
    if /usr/bin/droid/apex-post-setup.sh >> $LOGF 2>&1; then
        log "APEX post-setup completed"
    else
        log "WARN: APEX post-setup failed (rc=$?)"
    fi
else
    log "WARN: apex-post-setup.sh not found"
fi

# Wait for droid-hal-init's SetupMountNamespaces to replace /linkerconfig with a
# fresh tmpfs. Detect it via /proc/mounts — the moment tmpfs appears on /linkerconfig
# the early-init bind-mount (bootstrap) is buried and we can re-mount our patched copy.
log "Waiting for SetupMountNamespaces (/linkerconfig tmpfs)..."
_lc_detected=0
for _i in $(seq 1 30); do
    if grep -q 'tmpfs /linkerconfig ' /proc/mounts 2>/dev/null; then
        log "SetupMountNamespaces: /linkerconfig tmpfs detected after ${_i}s"
        _lc_detected=1
        break
    fi
    sleep 1
done
[ "$_lc_detected" -eq 0 ] && log "WARN: /linkerconfig tmpfs not seen after 30s — proceeding"

# Re-mount the patched linkerconfig saved in /run/ by early-init.
# /linkerconfig/bootstrap/ is inside /linkerconfig — SetupMountNamespaces buries it
# along with everything else under /linkerconfig. /run/ is a separate tmpfs, unaffected.
mount --bind /run/droid-linkerconfig.txt "$LIVE_LDCFG" \
    && log "linkerconfig: re-mounted from /run/ ($(wc -l < /run/droid-linkerconfig.txt) lines)" \
    || log "WARN: failed to re-mount linkerconfig from /run/ — vendor HALs may fail"

# Wait for Android property service, then for vendor RC files to be parsed.
# SetupMountNamespaces fires BEFORE RC parsing in Android 15 init's sequence.
# We must wait for property_service to come up before getprop is meaningful,
# then wait for init to set init.svc.vendor.qcrild (set on RC parse, before start).
log "Waiting for property service socket..."
for _i in $(seq 1 15); do
    [ -e /dev/socket/property_service ] && { log "property_service up after ${_i}s"; break; }
    sleep 1
done
log "Waiting for vendor RC parsing (init.svc.vendor.qcrild)..."
for _i in $(seq 1 30); do
    _svc=$(getprop init.svc.vendor.qcrild 2>/dev/null)
    if [ -n "$_svc" ]; then
        log "vendor RC parsed after ${_i}s (init.svc.vendor.qcrild=${_svc})"
        break
    fi
    sleep 1
done

# Explicitly start HAL services that were disabled by class_start main removal.
# Audio, vibrator, radio and WiFi/BT are in class main/late_start/hal, so they don't auto-start.
# minimedia (class main) registers media.audio_policy and media.camera.
for svc in vendor.nv_mac vendor.cnss-daemon vendor.qti.vibrator vendor.qcrild vendor.qcrild2 vendor.adsprpcd minimedia; do
    if [ -x /system/bin/setprop ]; then
        /system/bin/setprop ctl.start "$svc" 2>/dev/null && log "Started $svc via setprop"
    elif [ -x /vendor/bin/setprop ]; then
        /vendor/bin/setprop ctl.start "$svc" 2>/dev/null && log "Started $svc via setprop"
    else
        log "setprop not found, cannot start $svc"
    fi
done

# Wait for HWComposer to be available before signalling READY.
# Sending READY only after HWComposer is registered ensures that
# compositor services (startup wizard, lipstick) which have
# After=droid-hal.service start AFTER the HIDL service exists.
# This prevents the Qt hwcomposer plugin from falling back to the
# passthrough HAL path (which would create a second HWCSession and
# fight the binderized service for DRM master, causing BAD_DISPLAY).
log "Waiting for HWComposer service..."
HWC_READY=0
for i in $(seq 1 20); do
    if pgrep -f "android.hardware.graphics.composer" >/dev/null 2>&1; then
        log "HWComposer ready after ${i}s"
        HWC_READY=1
        break
    fi
    sleep 1
done
if [ "$HWC_READY" -eq 0 ]; then
    log "WARNING: HWComposer not detected after 20s — sending READY anyway"
fi
# Fix vibrator sysfs permissions before ngfd starts via defaultuser session.
# Android ueventd sets /sys/class/leds/vibrator/ to 0664 system:system, which
# blocks ngfd's droid-vibrator plugin (runs as defaultuser) from writing to
# duration/activate/state. chmod here runs after ueventd (well within the
# hwservicemanager wait above) and before systemd-notify sends READY, which
# is the trigger for the defaultuser session (and ngfd) to start.
for node in activate duration state brightness; do
    [ -e "/sys/class/leds/vibrator/$node" ] && \
        chmod 0666 "/sys/class/leds/vibrator/$node" 2>/dev/null
done
log "Vibrator sysfs permissions: $(ls -la /sys/class/leds/vibrator/activate 2>/dev/null | awk '{print $1,$3,$4}' || echo 'node not found')"

# Notify systemd that droid-hal-init and HWComposer are up. ADSP audio is NOT
# included in the READY gate — PulseAudio is gated separately via a drop-in
# (50-adsp-wait.conf ExecStartPre) that blocks PA until t=120s when APR is ready.
# All other services (lipstick, ofono, sensorfwd) start immediately.
systemd-notify --ready 2>/dev/null && log "Sent sd_notify READY (HWComposer up, droid-card loaded via droid-card-delayed.service)"

# TAS2557 SmartPA boot-recovery:
# PA starts at t=120s; module-droid-card is loaded from droid.pa at PA startup.
# The first tas2557_enable() fires at t=~121s: firmware not loaded → safe-guard failure
# → I2C chip restart → firmware reloads → fw_ready power-up with s1_0 config.
# The chip needs ~14s to settle after GPIO reset. We fire at t=136s (absolute
# uptime) to do a full PowerCtrl cycle with the correct s3_6 config.
# PowerCtrl=0 → mbPowerUp=false; Configuration=10 (s3_6); PowerCtrl=1 → full
# startup+unmute sequence with calibration data loaded. Without this the speaker
# uses the s1_0 tuning-mode profile which produces no audio output.
(
    target=136
    cur=$(awk '{print int($1)}' /proc/uptime)
    [ "$cur" -lt "$target" ] && sleep $((target - cur))
    if [ -x /system/bin/tinymix ]; then
        /system/bin/tinymix "PowerCtrl" 0 2>/dev/null
        sleep 0.2
        /system/bin/tinymix "Configuration" 10 2>/dev/null
        /system/bin/tinymix "PowerCtrl" 1 2>/dev/null
        log "SmartPA re-enable via PowerCtrl (s3_6) at uptime=$(awk '{print int($1)}' /proc/uptime)s"
    fi
) &

# Wait for qcrild to start. lshal is blocked by SELinux (service_manager find
# denied in u:r:init:s0 even with permissive=0), so we detect by process presence.
# oFono queries the HIDL registry directly via hwbinder — it does not depend on
# lshal. Process presence is a sufficient proxy for the service being up.
log "Waiting for qcrild to start..."
QCRILD_READY=0
for i in $(seq 1 20); do
    if pgrep -f qcrild >/dev/null 2>&1; then
        log "qcrild process detected after ${i}s"
        QCRILD_READY=1
        break
    fi
    sleep 1
done
QCRILD_PID=$(pgrep -f qcrild 2>/dev/null | head -1)
if [ -n "$QCRILD_PID" ] && [ -f /proc/$QCRILD_PID/attr/current ]; then
    log "DIAG: qcrild PID $QCRILD_PID domain = $(cat /proc/$QCRILD_PID/attr/current 2>/dev/null || echo 'N/A')"
fi
log "DIAG: /dev/hwbinder context = $(/system/bin/ls -Z /dev/hwbinder 2>/dev/null | awk '{print $5}' || echo 'N/A')"

# TRD-010 Part 2 DIAGNOSTIC (temporary): qcrild runs but never registers
# android.hardware.radio@1.4::IRadio, so oFono times out. qcril logs operationally
# via Android liblog -> logd (not stderr), so stdio_to_kmsg shows nothing. Start logd
# explicitly (its `start logd` is stripped by patch_rc_init_hybris) and capture the
# radio/system buffers to a file we can pull from Android. Remove once diagnosed.
if /system/bin/setprop ctl.start logd 2>/dev/null; then
    log "TRD-010 diag: started logd"
    sleep 2
    /system/bin/logcat -b radio -b system -b main -v time > /var/log/qcril-logcat.log 2>&1 &
    log "TRD-010 diag: logcat capture -> /var/log/qcril-logcat.log (PID $!)"
else
    log "TRD-010 diag: could not start logd (logcat capture skipped)"
fi

if [ "$QCRILD_READY" -eq 0 ]; then
    log "WARNING: qcrild not detected after 20s, attempting restart..."
    /system/bin/setprop ctl.stop vendor.qcrild 2>/dev/null
    sleep 1
    /system/bin/setprop ctl.start vendor.qcrild 2>/dev/null && log "Restarted vendor.qcrild"
    sleep 5
    if pgrep -f qcrild >/dev/null 2>&1; then
        log "qcrild started after restart"
    else
        log "WARNING: qcrild still not running after restart, oFono may fail to find IRadio"
    fi
fi

# Wait for droid-hal-init to exit
wait $INIT_PID
INIT_RET=$?
log "droid-hal-init EXITED code=$INIT_RET"
