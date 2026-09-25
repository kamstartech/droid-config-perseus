#!/bin/sh
# kaos-droid-hal-init.sh -- starts the real (hybris-patched) droid-hal-init
# in the background, orchestrates real APEX activation around it, waits for
# real HWComposer readiness, then signals systemd readiness (Type=notify).
#
# Split from a single monolithic script on 2026-09-24 to match SailfishOS's
# own two-service shape: mounts/APEX-fallback/linkerconfig/rc-patches now
# live in kaos-droid-hal-prepare.sh (kaos-droid-hal-prepare.service, Type=
# oneshot, RemainAfterExit=yes, Before=this unit) -- see that file for all of
# that reasoning. This script assumes prepare has already run successfully
# (Requires=kaos-droid-hal-prepare.service on this unit).
#
# The composer-readiness poll + systemd-notify --ready below is the other
# half of the 2026-09-24 fix: this service is now Type=notify/NotifyAccess=
# all instead of Type=simple, matching droid-hal-init.service in
# droid-hal-startup.sh. Six earlier, individually-confirmed-correct fixes
# (persist-restore, real re-mount, real apexd activation, dir.system patch,
# /linkerconfig/default population, HYBRIS_BUILD stub binary) each produced
# zero measurable change to phoc's "not accessible for the namespace
# (default)" EGL error -- all of them were config-CONTENT fixes. The one
# structural difference nothing had tried yet: under Type=simple, systemd
# considers this service (and therefore graphical.target / phoc) "started"
# the instant this script's ExecStart process exists, regardless of whether
# droid-hal-init's own boot has reached a consistent state yet. phoc may
# simply have been racing droid-hal-init itself, not losing to any config
# file content.

LOGF=/var/log/kaos-droid-hal-init.log
log() { echo "$(date '+%H:%M:%S') init: $*" >> "$LOGF"; echo "kaos-droid-hal-init: $*" > /dev/kmsg 2>/dev/null; }

[ -x /system/bin/droid-hal-init ] || { log "/system/bin/droid-hal-init missing -- skipping"; exit 0; }

# Run droid-hal-init in the background (not a final exec) so this script can
# keep orchestrating real APEX activation around it, and later block on
# real HWComposer readiness before telling systemd we're up -- the same
# shape droid-hal-startup.sh uses. This service's own lifetime (systemd
# tracks this script's own PID) now spans droid-hal-init's full run, not
# just the setup steps before it -- see kaos-droid-hal-init.service's
# TimeoutStartSec note.
log "starting droid-hal-init (backgrounded)"
/system/bin/droid-hal-init >> "$LOGF" 2>&1 &
INIT_PID=$!
log "droid-hal-init PID=$INIT_PID"

# Explicitly start HAL services that class_start main/late_start removal
# (kaos-droid-hal-prepare.sh's init.rc patch) leaves disabled. Ported
# directly from droid-hal-startup.sh's own equivalent block, 2026-09-25:
# WLAN (vendor.cnss-daemon) -- the original stated purpose of this whole
# droid-hal-init integration -- turned out to have been silently dead this
# entire time, since it happens to share `class late_start` with a mix of
# other, unrelated hardware daemons (GPS/location, sensor hub, vibrator,
# radio, networking) that our own class-level strip has no way to
# distinguish from actual zygote/app-framework services (those are gated
# separately, via the already-stripped `trigger zygote-start`). Verified
# against this device's own rc tree first (grep -rl "^service <name> " over
# every real init dir) -- vendor.media.omx, vendor.nv_mac, vendor.cnss-
# daemon, vendor.qti.vibrator, vendor.qcrild, vendor.qcrild2, and vendor.
# adsprpcd are all genuinely declared here, so kept. Two of droid-hal-
# startup.sh's own list are NOT: minimedia/minisf are Sailfish's own
# droidmedia package (real binaries confirmed only under their own
# /usr/libexec/droid-hybris/system/bin/, never installed on this Ubuntu
# rootfs or the real Android partition), and media.swcodec isn't a classic
# rc-declared service at all on this device (APEX-provided, activated via
# the per-APEX linkerconfig loop below instead) -- starting either would be
# a silent no-op at best, so left out rather than copied blindly. The
# libminisf.so "not accessible for the namespace (default)" warning seen in
# every phoc log is minisf's absence, not something this loop can fix --
# porting droidmedia itself would be a separate, larger effort.
sleep 2
log "vendor RC parse window elapsed"

# apex-post-setup equivalent: wait for droid-hal-init's own internal apexd
# to finish real activation, then fix up the one package known not to
# decompress here (conscrypt's .capex) and make sure the active
# (non-versioned) /apex/<name> paths exist the way real apexd would leave
# them.
_apexd_activated=0
for _i in $(seq 1 30); do
    if [ "$(/system/bin/getprop apexd.status 2>/dev/null)" = "activated" ]; then
        log "apexd activated after ${_i}s"
        _apexd_activated=1
        break
    fi
    sleep 1
done
[ "$_apexd_activated" -eq 0 ] && log "WARN: apexd.status != activated after 30s -- continuing anyway"

if [ ! -f /apex/com.android.conscrypt/lib64/libcrypto.so ]; then
    conscrypt_versioned=$(ls -d /apex/com.android.conscrypt@* 2>/dev/null | head -n1)
    if [ -n "$conscrypt_versioned" ] && [ -f "$conscrypt_versioned/lib64/libcrypto.so" ]; then
        log "conscrypt already available at $conscrypt_versioned"
    else
        log "populating com.android.conscrypt fallback from /system/lib64 (real .capex doesn't decompress here)"
        mkdir -p /apex/com.android.conscrypt/lib64 /apex/com.android.conscrypt/lib
        for f in libcrypto.so libssl.so; do
            [ -f "/system/lib64/$f" ] && [ ! -f "/apex/com.android.conscrypt/lib64/$f" ] && \
                cp -f "/system/lib64/$f" "/apex/com.android.conscrypt/lib64/$f"
            [ -f "/system/lib/$f" ] && [ ! -f "/apex/com.android.conscrypt/lib/$f" ] && \
                cp -f "/system/lib/$f" "/apex/com.android.conscrypt/lib/$f"
        done
    fi
fi

for _apex_name in com.android.runtime com.android.i18n com.android.tzdata com.android.conscrypt; do
    _active="/apex/$_apex_name"
    [ -L "$_active" ] && continue
    mountpoint -q "$_active" 2>/dev/null && continue
    _versioned=$(ls -d "/apex/${_apex_name}@"* 2>/dev/null | head -n1)
    if [ -n "$_versioned" ]; then
        mkdir -p "$_active"
        mount --bind "$_versioned" "$_active" 2>/dev/null \
            && log "bind-mounted $_versioned -> $_active" \
            || log "WARN: failed to bind-mount $_versioned -> $_active"
    fi
done

# Per-APEX linkerconfig: the global config restored by kaos-droid-hal-
# prepare.sh only covers the top-level system/vendor namespaces. APEX
# binaries (mediaswcodec etc.) also need their own
# /linkerconfig/<apex>/ld.config.txt. Real Android generates these
# automatically during DoLoadApex(); SailfishOS's own experience is that
# this often doesn't happen reliably in a hybris environment, so generate
# them explicitly now that real apexd has (hopefully) activated the runtime
# APEX and its linkerconfig binary.
_real_linkerconfig=/apex/com.android.runtime/bin/linkerconfig
if [ -x "$_real_linkerconfig" ]; then
    _generated=0
    for _apex_bin in /apex/com.*/bin; do
        [ -d "$_apex_bin" ] || continue
        _apex_path=$(dirname "$_apex_bin")
        _apex_name=$(basename "$_apex_path")
        [ "$_apex_name" = "com.android.runtime" ] && continue
        case "$_apex_name" in *@*) continue ;; esac
        if "$_real_linkerconfig" --target /linkerconfig --apex "$_apex_name" --strict >> "$LOGF" 2>&1; then
            log "linkerconfig: generated per-APEX config for $_apex_name"
            _generated=$((_generated + 1))
        else
            log "WARN: linkerconfig failed to generate config for $_apex_name"
        fi
    done
    log "linkerconfig: generated $_generated per-APEX config(s)"
else
    log "linkerconfig: real linkerconfig binary not available, skipping per-APEX generation"
fi

# Explicitly start HAL services that class_start main/late_start removal
# (kaos-droid-hal-prepare.sh's init.rc patch) leaves disabled. Ported
# directly from droid-hal-startup.sh's own equivalent block, 2026-09-25.
# MOVED HERE (2026-09-25, after the apexd-activation wait + per-APEX
# linkerconfig generation above) -- confirmed live this was previously
# running BEFORE apexd even activated (ctl.start at the same second as
# droid-hal-init's own startup, apexd not activated until ~10s later).
# Five of these -- vendor.cnss-daemon, vendor.qti.vibrator, vendor.media.omx,
# vendor.qcrild, vendor.qcrild2 -- all SIGABRT within the same one-second
# window as a result: they're binder/HIDL services that resolve their own
# library dependencies through Mainline APEX namespaces (com.android.art,
# com.android.media, etc.), which do not exist in the linker's view yet at
# that point -- an immediate dynamic-linker abort, not a runtime crash.
# droid-hal-startup.sh's own generate_apex_linkerconfigs() call is
# unconditionally BEFORE its own equivalent ctl.start loop for exactly this
# reason; ours was backwards.
mkdir -p /data/misc/camera
chmod 0771 /data/misc/camera
chown system:camera /data/misc/camera 2>/dev/null
for _svc in vendor.nv_mac vendor.cnss-daemon vendor.qti.vibrator \
            vendor.qcrild vendor.qcrild2 vendor.adsprpcd vendor.media.omx; do
    /system/bin/setprop ctl.start "$_svc" 2>/dev/null \
        && log "started $_svc via setprop ctl.start" \
        || log "WARN: setprop ctl.start $_svc failed"
done

# --- HWComposer readiness gate + systemd-notify --ready (2026-09-24) -------
# Ported directly from droid-hal-startup.sh (SailfishOS): poll for the real
# HIDL/AIDL composer HAL service process, up to 20s, THEN tell systemd this
# service is ready. graphical.target (and therefore phoc/phosh, which this
# unit is Before=) cannot start until this notify fires. Sailfish's own
# process name (android.hardware.graphics.composer) is the standard AOSP
# HAL service binary name and this device runs the same vendor HAL family,
# so the same pgrep pattern is used here rather than guessing a
# distro-specific equivalent.
HWC_READY=0
for _i in $(seq 1 20); do
    if pgrep -f "android.hardware.graphics.composer" >/dev/null 2>&1; then
        log "HWComposer service process found after ${_i}s"
        HWC_READY=1
        break
    fi
    sleep 1
done
[ "$HWC_READY" -eq 0 ] && log "WARN: HWComposer service process not found after 20s -- notifying ready anyway"

if command -v systemd-notify >/dev/null 2>&1; then
    systemd-notify --ready 2>/dev/null \
        && log "sent sd_notify READY (HWComposer ready=$HWC_READY)" \
        || log "WARN: systemd-notify --ready failed"
else
    log "WARN: systemd-notify not found -- Type=notify service will time out"
fi

log "droid-hal-init orchestration done -- waiting for PID $INIT_PID"
wait "$INIT_PID"
_init_rc=$?
log "droid-hal-init exited code=$_init_rc"
exit "$_init_rc"
