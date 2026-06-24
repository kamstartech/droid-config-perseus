#!/bin/sh
# apex-post-setup.sh — runs in the droid-hal-init.service namespace after
# apexd has activated the bootstrap APEX modules.
#
# Android 15 apexd mounts activated APEX at /apex/<name>@<version> and then
# bind-mounts /apex/<name> to that version. Compressed APEX (conscrypt on
# perseus) fails to decompress in the hybris environment, so we provide a
# minimal fallback population from /system/lib64.

LOG_TAG="apex-post-setup"
log() { echo "$LOG_TAG: $*" > /dev/kmsg 2>/dev/null; }

# Wait for apexd to finish activation. In bootstrap mode this happens early;
# the property is set by apexd once all bootstrap packages are processed.
wait_apexd() {
    local i
    for i in $(seq 1 30); do
        if [ "$(/system/bin/getprop apexd.status 2>/dev/null)" = "activated" ]; then
            log "apexd activated after ${i}s"
            return 0
        fi
        sleep 1
    done
    log "WARN: apexd.status != activated after 30s, continuing anyway"
    return 1
}

# Populate a minimal com.android.conscrypt APEX fallback. The real .capex
# cannot be decompressed by apexd in this environment (I/O error writing to
# tmpfs decompression dir). qcrild only needs libcrypto.so/libssl.so from it.
populate_conscrypt_fallback() {
    local active=/apex/com.android.conscrypt
    local versioned
    # If apexd already activated it (unlikely for .capex here), nothing to do.
    [ -d "$active" ] && [ -f "$active/lib64/libcrypto.so" ] && return 0

    # Prefer a versioned mount point if one exists.
    versioned=$(ls -d /apex/com.android.conscrypt@* 2>/dev/null | head -n1)
    if [ -n "$versioned" ] && [ -f "$versioned/lib64/libcrypto.so" ]; then
        log "conscrypt already available at $versioned"
        return 0
    fi

    log "Populating com.android.conscrypt fallback from /system/lib64"
    mkdir -p "$active/lib64" "$active/lib"
    for f in libcrypto.so libssl.so; do
        if [ -f "/system/lib64/$f" ] && [ ! -f "$active/lib64/$f" ]; then
            cp -f "/system/lib64/$f" "$active/lib64/$f" && log "copied lib64/$f"
        fi
        if [ -f "/system/lib/$f" ] && [ ! -f "$active/lib/$f" ]; then
            cp -f "/system/lib/$f" "$active/lib/$f"
        fi
    done
}

# Ensure the active /apex/<name> paths exist. apexd normally bind-mounts these,
# but if a prior run left a directory in the way we may need to recreate it.
ensure_active_apex_paths() {
    local name
    for name in com.android.runtime com.android.i18n com.android.tzdata com.android.conscrypt; do
        local active=/apex/$name
        if [ -L "$active" ]; then
            log "$active is a symlink -> $(readlink "$active" 2>/dev/null)"
            continue
        fi
        if mountpoint -q "$active" 2>/dev/null; then
            log "$active is a mountpoint"
            continue
        fi
        # If the active path is missing but a versioned mount exists, create a
        # bind-mount (same result as apexd's normal activation).
        local versioned
        versioned=$(ls -d /apex/${name}@* 2>/dev/null | head -n1)
        if [ -n "$versioned" ]; then
            mkdir -p "$active"
            if mount --bind "$versioned" "$active" 2>/dev/null; then
                log "bind-mounted $versioned -> $active"
            else
                log "WARN: failed to bind-mount $versioned -> $active"
            fi
        fi
    done
}

log "Starting APEX post-setup"
wait_apexd
populate_conscrypt_fallback
ensure_active_apex_paths

# Diagnostic summary
log "APEX summary: runtime=$(mountpoint -q /apex/com.android.runtime 2>/dev/null && echo ok || echo missing)"
log "APEX summary: i18n=$(mountpoint -q /apex/com.android.i18n 2>/dev/null && echo ok || echo missing)"
log "APEX summary: tzdata=$(mountpoint -q /apex/com.android.tzdata 2>/dev/null && echo ok || echo missing)"
log "APEX summary: conscrypt=$(mountpoint -q /apex/com.android.conscrypt 2>/dev/null && echo ok || [ -f /apex/com.android.conscrypt/lib64/libcrypto.so ] && echo fallback || echo missing)"
log "APEX post-setup done"
