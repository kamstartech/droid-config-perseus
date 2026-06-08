#!/bin/sh
# droid-dm-setup.sh — Create dm-linear mappings for retro-fitted dynamic partitions.
#
# Perseus was originally Android 9 (system/vendor as raw partitions) and was
# retro-fitted with Android 15 dynamic partitions. The logical partitions
# (system, vendor, product, odm, system_ext) are carved out of the original
# sde48 (system) / sde47 (vendor) / sda19 blocks via dm-linear. Android's
# first-stage init creates these mappings on every boot. In SailfishOS cold
# boot they are absent, so we must recreate them before mount units run.
#
# Tables were captured from Android dmctl output on perseus.

log() {
    echo "[droid-dm-setup] $*" > /dev/kmsg 2>/dev/null
    echo "[droid-dm-setup] $*"
}

ensure_block_dev() {
    local name="$1"
    local path="/dev/block/$name"
    [ -b "$path" ] && return 0
    mkdir -p /dev/block
    local major minor id
    id=$(cat "/sys/class/block/$name/dev" 2>/dev/null) || return 1
    major=${id%%:*}
    minor=${id#*:}
    mknod "$path" b "$major" "$minor" 2>/dev/null
    [ -b "$path" ]
}

wait_for_block() {
    local name="$1"
    for i in $(seq 1 100); do
        [ -e "/sys/class/block/$name" ] && return 0
        sleep 0.05
    done
    return 1
}

create_or_reload() {
    local name="$1"
    shift
    local table
    table=$(printf '%s\n' "$@")
    if [ -e "/dev/mapper/$name" ]; then
        # Already present (warm reboot from Android) — verify name matches
        local dm_name
        dm_name=$(cat "/sys/block/dm-$(stat -c %T /dev/mapper/$name)/dm/name" 2>/dev/null)
        if [ "$dm_name" = "$name" ]; then
            log "$name already present, skipping"
            return 0
        fi
        dmsetup remove "$name" 2>/dev/null || true
    fi
    echo "$table" | dmsetup create "$name" -- 2>&1 | while read -r line; do
        log "$name: $line"
    done
    if [ -e "/dev/mapper/$name" ]; then
        log "OK $name"
        return 0
    else
        log "FAIL $name"
        return 1
    fi
}

refresh_nodes() {
    mkdir -p /dev/block/mapper /dev/mapper /run/droid
    for p in /sys/block/dm-*/dm/name; do
        [ -f "$p" ] || continue
        local n dm_num major minor id
        n=$(cat "$p")
        [ -n "$n" ] || continue
        dm_num=$(basename "$(dirname "$(dirname "$p")")" | sed 's/dm-//')
        id=$(cat "/sys/block/dm-$dm_num/dev" 2>/dev/null)
        major=${id%%:*}
        minor=${id#*:}
        [ -b "/dev/block/dm-$dm_num" ] || mknod "/dev/block/dm-$dm_num" b "$major" "$minor" 2>/dev/null
        ln -sf "../../block/dm-$dm_num" "/dev/mapper/$n" 2>/dev/null || true
        ln -sf "/dev/mapper/$n" "/run/droid/$n" 2>/dev/null || true
        # Re-emit uevent so systemd-udevd (which started after Android init created
        # these dm devices) notices them and populates dev-dm-X.device units.
        printf add > "/sys/block/dm-$dm_num/uevent" 2>/dev/null && log "uevent add dm-$dm_num ($n)"
    done
}

log "=== START ==="

# Wait for the underlying raw block devices to appear
for part in sde48 sde47 sda19; do
    if ! wait_for_block "$part"; then
        log "FATAL: /sys/class/block/$part never appeared"
        exit 1
    fi
    if ! ensure_block_dev "$part"; then
        log "FATAL: cannot create /dev/block/$part"
        exit 1
    fi
    log "READY /dev/block/$part"
done

# Create dm-linear mappings. The tables are static for perseus.
create_or_reload system  "0 2246232 linear /dev/block/sde48 2048"
create_or_reload vendor  "0 1332640 linear /dev/block/sde48 2249328"
create_or_reload product \
    "0 3758064 linear /dev/block/sde48 3581968" \
    "3758064 1636512 linear /dev/block/sde47 2048"
create_or_reload odm     "0 3000 linear /dev/block/sde47 1638304"
create_or_reload system_ext \
    "0 446144 linear /dev/block/sde47 1641312" \
    "446144 619912 linear /dev/block/sda19 1040928"

# Make sure /dev/block/dm-N and /dev/mapper/<name> nodes exist for mount units
refresh_nodes

log "=== DONE ==="
ls -la /dev/mapper/ > /dev/kmsg 2>&1 || true
