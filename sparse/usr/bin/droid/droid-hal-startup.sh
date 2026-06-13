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
# SailfishOS does not use Android vold; leaving it enabled causes a crash loop
# on this Android 15 base because /system/bin/vold links a libbinder symbol that
# is missing after the TRD-018 vendor libbinder bind-mount.
patch_rc_disable_service /system/etc/init/vold.rc
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

# Audio HAL service: remove task_profiles and audioserver onrestart, and mark disabled.
# vendor.audio-hal is in class hal — class_start hal fires it even though we remove
# class_start main/late_start. Injecting 'disabled' prevents auto-start via any trigger.
# pulseaudio-modules-droid uses libhardware directly and does NOT need this HIDL service.
patch_rc_audio_hal() {
    local orig="$1"
    [ -f "$orig" ] || return 0
    local tmp
    tmp=$(mktemp -t hybris-rc.XXXXXX) || return 1
    sed -e '/task_profiles/d' \
        -e '/onrestart restart audioserver/d' \
        -e '/^service vendor\.audio-hal /a\    override\n    disabled' \
        "$orig" > "$tmp"
    mount --bind "$tmp" "$orig" && log "Patched audio HAL $(basename $orig): hybris fixes (disabled)" \
        || log "WARN: failed to bind-mount audio HAL patch for $orig"
}
patch_rc_audio_hal /vendor/etc/init/android.hardware.audio.service.rc

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

# TRD-018 (TEMPORARY — disabled to silence the libbinder SYST/VNDR mix; proper fix TBD).
# These two vendor HALs are version-mismatched and each map BOTH /system and /vendor
# libbinder.so → "Parcel: Expecting header VNDR but found SYST. Mixing copies of
# libbinder?" (~51×/boot, to kmsg). Confirmed via sfos-diag TRD-018 precise check 2026-06-12:
#   - android.hardware.camera.provider@2.4-service : 32-bit (Android 35) — 32-bit libbinder split
#   - vendor.display.color@1.0-service             : 64-bit but Android-30 vintage (libhidltransport)
# Neither is used by SailfishOS today (HWComposer drives display; the QTI color HAL is unused).
# ---- WHEN FIXING LATER ----
# * display.color@1.0 is safe to leave disabled (SFOS has no consumer).
# * camera.provider@2.4 is the SFOS camera HAL (jolla-camera→gst-droid→droidmedia talk to it
#   directly; this is SEPARATE from the disabled libhybris camera compat layer). RE-ENABLE this
#   line before any camera bring-up, and instead fix the 32-bit libbinder resolution (or use a
#   64-bit camera provider if one exists for perseus).
patch_rc_disable_service /vendor/etc/init/android.hardware.camera.provider@2.4-service.rc
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

# The linkerconfig must be the full Android-generated one with ${LIB} substitution
# so that both 32-bit and 64-bit vendor binaries (e.g. HIDL audio HAL) can find
# their libraries in /vendor/lib and /vendor/lib64 respectively.
# A copy is kept at /mnt/vendor/persist/ld.config.txt so it survives Android→SailfishOS
# reboots (Android regenerates /linkerconfig on each boot; switch_root discards it).
PERSIST_LDCFG=/mnt/vendor/persist/ld.config.txt
LIVE_LDCFG=/linkerconfig/ld.config.txt
mkdir -p /linkerconfig
lc_size="$(stat -c %s $LIVE_LDCFG 2>/dev/null || echo 0)"
if [ "$lc_size" -ge 100000 ]; then
    # Full Android-generated linkerconfig is present — save a backup for next boot
    cp -f $LIVE_LDCFG $PERSIST_LDCFG 2>/dev/null \
        && log "linkerconfig ok (${lc_size}b): saved backup to persist" \
        || log "linkerconfig ok (${lc_size}b): backup save failed"
elif [ -f $PERSIST_LDCFG ] && [ "$(stat -c %s $PERSIST_LDCFG 2>/dev/null || echo 0)" -ge 100000 ]; then
    # Restore from last good copy saved from Android boot
    cp -f $PERSIST_LDCFG $LIVE_LDCFG \
        && log "linkerconfig restored from persist ($(wc -c < $LIVE_LDCFG)b)" \
        || log "WARN: linkerconfig restore from persist failed"
else
    log "WARN: no full linkerconfig available (${lc_size}b) — vendor 32-bit HALs may fail to load"
    log "  To fix: boot into Android once to regenerate /linkerconfig, then reboot to SailfishOS"
fi
log "linkerconfig: $(wc -c < $LIVE_LDCFG 2>/dev/null || echo '?')b, ${LIB}-capable: $(grep -c '\${LIB}' $LIVE_LDCFG 2>/dev/null || echo 0) paths"

# qcrild/vendor-HAL fix: the persisted Android linkerconfig isolates the [vendor]
# namespace from /system (permitted.paths lacks /system). But vendor binaries
# (qcrild, qseecomd, and many HALs) dlopen /system/lib64/libc++.so — the runtime
# APEX only symlinks libc++.so back to /system, it ships no own copy. Without
# /system access they fail "CANNOT LINK ... libc++.so not accessible for namespace
# (default)" and crash-loop. We append /system/${LIB} to the [vendor] default
# namespace, placed AFTER /vendor/${LIB} so libbinder.so still resolves to /vendor
# FIRST (single copy in one namespace → no SYST/VNDR "Mixing copies of libbinder").
# Patches the LIVE config only (persist stays pristine — backed up above). Idempotent.
patch_vendor_linkerconfig() {
    local cfg=$LIVE_LDCFG
    [ -f "$cfg" ] || { log "WARN: no linkerconfig to patch for /system access"; return 0; }
    if awk '/^\[/{s=$0} s=="[vendor]" && /^namespace\.default\.search\.paths \+= \/system\/\$\{LIB\}/{f=1} END{exit !f}' "$cfg"; then
        log "vendor linkerconfig already grants /system access — skipping"
        return 0
    fi
    local tmp; tmp=$(mktemp -t ldcfg.XXXXXX) || return 1
    awk '
      /^\[/ { invendor = ($0=="[vendor]") }
      { print }
      invendor && $0=="namespace.default.search.paths += /vendor/${LIB}/egl" { print "namespace.default.search.paths += /system/${LIB}" }
      invendor && $0=="namespace.default.permitted.paths += /system/vendor" { print "namespace.default.permitted.paths += /system" }
    ' "$cfg" > "$tmp"
    # Verify BOTH lines landed in [vendor] before committing — a partial patch
    # (permitted without search) would still fail to link, so refuse it.
    local got
    got=$(awk '/^\[/{s=$0} s=="[vendor]" && (/^namespace\.default\.search\.paths \+= \/system\/\$\{LIB\}/ || /^namespace\.default\.permitted\.paths \+= \/system$/)' "$tmp" | wc -l)
    if [ "$got" -eq 2 ]; then
        cat "$tmp" > "$cfg" && log "Patched vendor linkerconfig: +/system/\${LIB} search + /system permitted ([vendor] only, after /vendor)" \
            || log "WARN: failed to write patched linkerconfig"
    else
        log "WARN: vendor linkerconfig patch produced $got/2 expected lines — NOT applied (config format drift?)"
    fi
    rm -f "$tmp"
}
patch_vendor_linkerconfig

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

# Notify systemd immediately that droid-hal-init is alive.
# The script continues polling hwservicemanager/qcrild, but systemd
# must know the service is running so it doesn't hit TimeoutSec.
systemd-notify --ready 2>/dev/null && log "Sent sd_notify READY (early)"

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

# Additional stabilization delay: droid-hal-init's post-fs-data action and
# vendor HAL .rc parsing must complete before qcrild starts, otherwise
# RilServiceModule_1_4 races qcril_init dispatch.
sleep 3

# Explicitly start HAL services that were disabled by class_start main removal.
# Audio, vibrator, radio and WiFi/BT are in class main/late_start/hal, so they don't auto-start.
for svc in vendor.nv_mac vendor.cnss-daemon vendor.qti.vibrator vendor.qcrild; do
    if [ -x /system/bin/setprop ]; then
        /system/bin/setprop ctl.start "$svc" 2>/dev/null && log "Started $svc via setprop"
    elif [ -x /vendor/bin/setprop ]; then
        /vendor/bin/setprop ctl.start "$svc" 2>/dev/null && log "Started $svc via setprop"
    else
        log "setprop not found, cannot start $svc"
    fi
done

# Wait for HWComposer to be available — lipstick needs it for display init.
log "Waiting for HWComposer service..."
for i in $(seq 1 20); do
    if pgrep -f "android.hardware.graphics.composer" >/dev/null 2>&1; then
        log "HWComposer ready after ${i}s"
        break
    fi
    sleep 1
done

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
