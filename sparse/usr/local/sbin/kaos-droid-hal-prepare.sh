#!/bin/sh
# kaos-droid-hal-prepare.sh -- mounts, APEX bootstrap fallback, linkerconfig,
# and rc patches needed before the real (hybris-patched) droid-hal-init can
# run, under switch_root cold boot. Runs as its own oneshot systemd service
# (kaos-droid-hal-prepare.service), ordered Before=kaos-droid-hal-init.service
# -- split out 2026-09-24 to match SailfishOS's own two-service shape
# (droid-hal-prepare.service -> droid-hal-early-init.sh, then
# droid-hal-init.service -> droid-hal-startup.sh), instead of doing
# everything in one monolithic script/process the way this file used to.
#
# /vendor, /system, and /vendor/firmware_mnt are NOT mounted here.  An
# earlier version of this script mounted them itself with plain `mount`
# calls and hit persistent, unexplained problems doing it by hand: the
# "modem" partition's sysfs PARTNAME sometimes wasn't found even after 5s of
# retrying, and separately /system (mounted straight from /run/droid/system)
# was seen with /system/bin nearly empty even though the same partition,
# mounted the same way outside the real boot, had full content. Root cause:
# this device is system-as-root -- the "system" dm-linear partition's OWN
# top-level /bin is a near-empty compat stub; the real /system/bin lives
# nested one level deeper, at <system-partition-root>/system/bin. Plain
# `mount /run/droid/system /system` was mounting the WRONG level.
#
# SailfishOS already has this exactly right, via native systemd .mount units
# (hybris/droid-configs/sparse/usr/lib/systemd/system/): system_root.mount
# mounts the raw partition at /system_root, and system.mount bind-mounts
# /system_root/system onto /system. vendor.mount mounts /vendor directly
# (vendor isn't system-as-root, so no nesting there). vendor-firmware_mnt.mount
# mounts the "modem" partition onto /vendor/firmware_mnt. These are generic
# facts about this device's Android partition layout, not anything
# SailfishOS-specific, so build-rootfs.sh installs the exact same unit files
# for every distro (byte-identical, all WantedBy=local-fs.target) instead of
# this script re-deriving them by hand.
#
# This script (and kaos-droid-hal-init.sh/.service after it) only runs
# After=local-fs.target, the same way SailfishOS's own droid-hal-prepare.
# service is ordered -- by the time it runs, systemd's own local-fs.target
# dependency tracking guarantees every WantedBy=local-fs.target mount unit,
# including all four above, already completed successfully.

LOGF=/var/log/kaos-droid-hal-init.log
log() { echo "$(date '+%H:%M:%S') prepare: $*" >> "$LOGF"; echo "kaos-droid-hal-prepare: $*" > /dev/kmsg 2>/dev/null; }

log "=== START === vendor-mounted=$(mountpoint -q /vendor && echo yes || echo no) system-mounted=$(mountpoint -q /system && echo yes || echo no) firmware_mnt-mounted=$(mountpoint -q /vendor/firmware_mnt && echo yes || echo no) system-bin-count=$(ls /system/bin 2>&1 | wc -l)"

# /data: opt out of droid-hal-init's own MountRealDataIfNeeded()
# (system/core/init/init.cpp:959) mounting the REAL, FBE-encrypted Android
# userdata partition onto /data. Confirmed live this is why every single
# `mkdir /data/misc/...` in init.rc's post-fs-data actions failed with
# "Required key not available" (ENOKEY -- those directories need a real
# fscrypt key vold/keystore would normally derive from user credentials,
# which never happens here), and plausibly part of why keystore2/
# keymaster-4-0/gatekeeper-1-0 then crashed with SIGABRT (real hardware-
# backed keystore code hitting a real-but-inconsistent encrypted /data it
# never properly unlocked). init.cpp's own check is exactly the hook this
# needs: `if (IsMountPointFor(proc_mounts, "/data")) { ... skip real-data
# mount ... }` -- if /data is ALREADY a mount point by the time
# MountRealDataIfNeeded() runs, it skips the real partition entirely, no
# source change needed. Bind-mount a plain directory on this distro's own
# (unencrypted) rootfs instead -- persists across boots like any other
# rootfs path, but carries no fscrypt policy at all, so every one of those
# mkdirs should just succeed normally.
mkdir -p /android_data /data
if ! mountpoint -q /data 2>/dev/null; then
    mount --bind /android_data /data 2>/dev/null \
        && log "bind-mounted /android_data onto /data (opts out of droid-hal-init's real userdata mount)" \
        || log "WARN: /android_data bind-mount onto /data failed"
fi

# dhcpcd's own privsep sandbox chroots itself into /usr/lib/dhcpcd and tries
# to mknod its own private /dev/null there. /data (this whole rootfs) is
# nodev-mounted, so that mknod silently fails and dhcpcd dies instantly with
# "open /dev/null: Permission denied" -- confirmed live 2026-09-24, same bug
# class as the ad-hoc-build-chroot /dev/null issue found earlier this
# project. wlan0 itself associates fine (confirmed: "connected to Access
# Point", DHCP lease acknowledged) -- this is the only thing blocking WiFi.
# Give dhcpcd's sandbox a real, working /dev via bind mount instead of
# letting it try to create one itself.
mkdir -p /usr/lib/dhcpcd/dev
if ! mountpoint -q /usr/lib/dhcpcd/dev 2>/dev/null; then
    mount --bind /dev /usr/lib/dhcpcd/dev 2>/dev/null \
        && log "bind-mounted /dev onto /usr/lib/dhcpcd/dev (dhcpcd privsep sandbox needs a real /dev/null)" \
        || log "WARN: /dev bind-mount onto /usr/lib/dhcpcd/dev failed"
fi

# Diagnostic: does this switch_root environment's own fresh devtmpfs
# auto-populate loop devices the same way Android's own boot does (confirmed
# live there: CONFIG_BLK_DEV_LOOP=y, built-in, /dev/loop-control +
# /dev/block/loop0..35 all present via plain devtmpfs, no modprobe/udev
# needed), or does apexd-bootstrap's failure here trace back to missing loop
# devices instead -- the same class of gap the separate LXC/libhybris path's
# mount.sh had to work around by hand (that guest never gets its own
# devtmpfs at all, unlike this real switch_root).
log "diag loop-control=$(ls -la /dev/loop-control 2>&1) dev-loop-count=$(ls /dev/loop[0-9]* 2>/dev/null | wc -l) dev-block-loop-count=$(ls /dev/block/loop[0-9]* 2>/dev/null | wc -l)"

# Confirmed live: this environment's own devtmpfs already has /dev/loop0..N
# (CONFIG_BLK_DEV_LOOP=y, built-in) -- backwards from Android's own
# convention, which only ever populates /dev/block/loopN, never bare
# /dev/loopN (an Android-specific devtmpfs behavior our plain switch_root
# distro doesn't get). apexd is a real AOSP binary written for Android's own
# device layout and almost certainly opens /dev/block/loopN specifically --
# which genuinely doesn't exist here, a path mismatch rather than a missing
# driver. Symlink the real nodes into place under the path apexd expects.
if [ ! -e /dev/block/loop0 ]; then
    mkdir -p /dev/block
    n=0
    for l in /dev/loop[0-9]*; do
        [ -b "$l" ] || continue
        ln -sf "../${l#/dev/}" "/dev/block/${l#/dev/}"
        n=$((n + 1))
    done
    log "symlinked $n /dev/block/loopN -> ../loopN"
fi

# --- Firmware-loader udev rule: mask the distro's stock 50-firmware.rules
# stub (ATTR{loading}="-1" on every request) and install a real handler,
# ported from SailfishOS's own droid-load-firmware.sh. -----------------------
if [ -d /etc/udev/rules.d ] && [ ! -e /etc/udev/rules.d/998-kaos-firmware.rules ]; then
    mkdir -p /usr/local/bin
    : > /etc/udev/rules.d/50-firmware.rules
    cat > /usr/local/bin/kaos-load-firmware.sh <<'FWEOF'
#!/bin/sh
# Reimplements ueventd's firmware fallback loader (Android has no equivalent
# running under switch_root).
FOLDERS="/vendor/firmware /vendor/firmware_mnt/image /odm/firmware /firmware/image"
[ -e "/sys$DEVPATH/loading" ] || exit 1
for d in $FOLDERS; do
    [ -e "$d/$FIRMWARE" ] || continue
    echo 1 > "/sys$DEVPATH/loading"
    cat "$d/$FIRMWARE" > "/sys$DEVPATH/data"
    echo 0 > "/sys$DEVPATH/loading"
    exit 0
done
echo -1 > "/sys$DEVPATH/loading"
exit 1
FWEOF
    chmod +x /usr/local/bin/kaos-load-firmware.sh
    echo 'SUBSYSTEM=="firmware", ACTION=="add", RUN+="/usr/local/bin/kaos-load-firmware.sh"' \
        > /etc/udev/rules.d/998-kaos-firmware.rules
    log "installed firmware-loader udev rule, masked stock stub"
    # systemd-udevd starts well before this script runs (this service is
    # After=local-fs.target; udevd is part of sysinit.target, much earlier)
    # and only reads rule files from disk at its own startup -- dropping a
    # new rule file in afterward does nothing until udevd is explicitly told
    # to reload. Never called anywhere in this script before 2026-09-25,
    # which means this custom firmware-loader rule was very likely invisible
    # to udevd for every single boot this whole session, silently. Whether
    # this is why vendor.cnss-daemon's own firmware load never completed
    # (icnss never progresses past "Platform driver probed successfully",
    # no QMI handshake seen) is unconfirmed, but it's a genuine, separately
    # broken mechanism regardless of WLAN specifically.
    if command -v udevadm >/dev/null 2>&1; then
        udevadm control --reload-rules 2>/dev/null \
            && log "udevadm control --reload-rules (firmware rule now live)" \
            || log "WARN: udevadm control --reload-rules failed"
        udevadm trigger --subsystem-match=firmware --action=add 2>/dev/null \
            && log "udevadm trigger --subsystem-match=firmware (re-fire any pending firmware requests)" \
            || log "WARN: udevadm trigger firmware re-fire failed"
    else
        log "WARN: udevadm not found -- firmware-loader rule may not be live this boot"
    fi
fi

# --- Real Android init, not a reimplementation. droid-hal-init is a
# hybris-patched build of system/core/init/ itself (hybris/hybris-boot/
# Android.mk's droid_hal_init target), now shipped on the real system
# partition (kaos/kaos.mk PRODUCT_PACKAGES, 2026-09-22). Running it gives
# real apexd, real property service, and real per-service SELinux domain
# transitions for the vendor rc-declared daemons (qrtr-ns, pd-mapper,
# pm-service/pm-proxy, cnss-daemon) that actually bring up WLAN -- this is
# exactly what SailfishOS's droid-hal-startup.sh already does
# (TODO-sfos-verification.md confirms it's what makes `iw wlan0 link` show a
# working AP association there). -----------------------------------------
[ -x /system/bin/droid-hal-init ] || { log "/system/bin/droid-hal-init missing -- skipping"; exit 0; }

# droid-hal-init's MountExtraFilesystems() (system/core/init/builtins.cpp)
# mounts a tmpfs at /linkerconfig for its own GenerateLinkerConfiguration()
# to write into once apexd activates (mirrors the mount hook the LXC/
# libhybris path already does for the same reason -- kaos/apps/phosh-app/
# .../SetupManager.java's mount.sh). mount(2) needs the target directory to
# already exist; confirmed live this was fatal ("mount(\"tmpfs\",
# \"/linkerconfig\", ...) failed.: No such file or directory", process exits
# 6/NOTCONFIGURED immediately after) -- /linkerconfig doesn't exist anywhere
# in a plain Debian/Ubuntu rootfs. /debug_ramdisk and /second_stage_resources
# get harmless "Failed to umount: No such file or directory" for the same
# reason (droid-hal-init unconditionally tries to unmount them, non-fatal),
# created here too so those go quiet.
mkdir -p /linkerconfig /debug_ramdisk /second_stage_resources

# APEX bootstrap fallback + linkerconfig, ported from SailfishOS's own
# droid-hal-early-init.sh. Confirmed live this was the real blocker past the
# earlier fixes: droid-hal-init's OWN attempt to generate
# /linkerconfig/ld.config.txt via `perform_apex_config --bootstrap` fails
# ("failed to execute linkerconfig (exit 127)") because apexd-bootstrap
# itself failed to properly activate the real runtime APEX in this
# environment (no real loop-device APEX activation attempted here, unlike
# the separate LXC/libhybris path's mount.sh) -- and every dynamically-linked
# binary droid-hal-init then tries to start (lmkd, vndservicemanager,
# vendor.wifi_hal_legacy, ...) fails execv with ENOENT because neither
# /apex/com.android.runtime/ nor /linkerconfig/ld.config.txt exists at all.
# SailfishOS's fix doesn't wait on real APEX activation: it builds a fallback
# /apex/com.android.runtime/ by hand from the same bootstrap bionic files
# already confirmed present on /system (libc.so/libm.so/libdl.so under
# /system/lib64/bootstrap, linker64 under /system/bin/bootstrap), and writes
# /linkerconfig/ld.config.txt from a full config saved from a real Android
# boot (/mnt/vendor/persist/ld.config.txt, confirmed present, 231318 bytes)
# instead of depending on the linkerconfig tool ever running. The
# hybris-specific /usr/libexec/droid-hybris/ awk patches SailfishOS applies
# to that persisted config are skipped here -- that directory is part of the
# separate LXC/libhybris path's layout, which this distro doesn't have.
if ! mountpoint -q /apex 2>/dev/null; then
    mkdir -p /apex
    mount -t tmpfs -o mode=0755,size=128m tmpfs /apex 2>/dev/null \
        && log "mounted tmpfs on /apex" || log "WARN: /apex tmpfs mount failed"
fi

# /tmp: this switch_root environment's own /tmp is never given a fresh
# tmpfs -- it's whatever was left in the underlying rootfs directory,
# which turned out (confirmed live 2026-09-25) to be a leftover Android
# directory entirely: owned by uid/gid 2000 (Android's own "shell" user),
# mode 0771, SELinux type shell_data_file. defaultuser (uid 1000) gets
# neither read nor write on it, so anything needing real temp files
# (meson/ninja builds, and presumably plenty of ordinary apps) fails with
# permission denied the moment it touches /tmp. A fresh, properly-owned
# tmpfs is the standard fix, matching /apex's own treatment just above.
if ! mountpoint -q /tmp 2>/dev/null; then
    mount -t tmpfs -o mode=1777 tmpfs /tmp 2>/dev/null \
        && log "mounted tmpfs on /tmp (was leftover Android-owned dir, mode 0771 uid 2000)" \
        || log "WARN: /tmp tmpfs mount failed"
fi
if [ ! -f /apex/com.android.runtime/lib64/bionic/libc.so ]; then
    mkdir -p /apex/com.android.runtime/lib64/bionic /apex/com.android.runtime/lib/bionic /apex/com.android.runtime/bin
    for f in libc.so libm.so libdl.so libdl_android.so libclang_rt.hwasan-aarch64-android.so; do
        src="/system/lib64/bootstrap/$f"
        [ -f "$src" ] && cp "$src" "/apex/com.android.runtime/lib64/bionic/$f"
    done
    for f in libc.so libm.so libdl.so libdl_android.so; do
        [ -f "/apex/com.android.runtime/lib64/bionic/$f" ] && \
            ln -sf "bionic/$f" "/apex/com.android.runtime/lib64/$f"
    done
    for f in libc.so libm.so libdl.so libdl_android.so; do
        src="/system/lib/bootstrap/$f"
        [ -f "$src" ] && cp "$src" "/apex/com.android.runtime/lib/bionic/$f"
        [ -f "/apex/com.android.runtime/lib/bionic/$f" ] && \
            ln -sf "bionic/$f" "/apex/com.android.runtime/lib/$f"
    done
    for b in linker64 linker linker_asan linker_asan64 linker_hwasan64; do
        src="/system/bin/bootstrap/$b"
        [ -f "$src" ] && cp "$src" "/apex/com.android.runtime/bin/$b"
    done
    if [ ! -f /apex/com.android.i18n/lib64/libicuuc.so ]; then
        mkdir -p /apex/com.android.i18n/lib64 /apex/com.android.i18n/lib /apex/com.android.i18n/etc
        [ -d /system/usr/icu ] && ln -sf /system/usr/icu /apex/com.android.i18n/etc/icu
        for f in libicuuc.so libicui18n.so libicu.so libandroidicu.so; do
            for d in /system/lib64 /system/lib64/bootstrap; do
                [ -f "$d/$f" ] && cp "$d/$f" "/apex/com.android.i18n/lib64/$f" && break
            done
            for d in /system/lib /system/lib/bootstrap; do
                [ -f "$d/$f" ] && cp "$d/$f" "/apex/com.android.i18n/lib/$f" && break
            done
        done
    fi
    if [ ! -f /apex/com.android.conscrypt/lib64/libcrypto.so ]; then
        mkdir -p /apex/com.android.conscrypt/lib64 /apex/com.android.conscrypt/lib
        for f in libcrypto.so libssl.so; do
            [ -f "/system/lib64/$f" ] && cp "/system/lib64/$f" "/apex/com.android.conscrypt/lib64/$f"
            [ -f "/system/lib/$f" ] && cp "/system/lib/$f" "/apex/com.android.conscrypt/lib/$f"
        done
    fi
    log "APEX fallback populated: $(ls /apex/com.android.runtime/lib64/bionic/ 2>/dev/null | wc -w) lib64, $(ls /apex/com.android.runtime/bin/ 2>/dev/null | wc -w) bin"
fi

PERSIST_LDCFG=/mnt/vendor/persist/ld.config.txt
if [ -f "$PERSIST_LDCFG" ] && [ "$(stat -c %s "$PERSIST_LDCFG" 2>/dev/null || echo 0)" -ge 100000 ]; then
    cp -f "$PERSIST_LDCFG" /linkerconfig/ld.config.txt \
        && log "linkerconfig: restored full config from persist ($(stat -c %s "$PERSIST_LDCFG") bytes)" \
        || log "WARN: linkerconfig restore from persist failed"
elif [ -f /linkerconfig/ld.config.txt ] && [ "$(stat -c %s /linkerconfig/ld.config.txt 2>/dev/null || echo 0)" -ge 100000 ]; then
    log "linkerconfig: using existing full config (no persist copy available)"
else
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
namespace.default.search.paths = /vendor/lib64:/vendor/lib64/hw:/system/lib64:/system/lib64/bootstrap:/system/lib64/hw:/system_ext/lib64:/product/lib64:/odm/lib64:/apex/com.android.runtime/lib64:/apex/com.android.i18n/lib64:/apex/com.android.conscrypt/lib64
namespace.default.permitted.paths = /system:/vendor:/system_ext:/product:/odm:/apex:/data
namespace.default.asan.search.paths = /vendor/lib64
LDCFG
    log "linkerconfig: wrote minimal fallback config"
fi

# Route our own hybris-dependent binaries (phoc/phosh, plain /usr/bin/*, not
# an Android path) into the real [system] namespace instead of bionic's
# built-in fallback for callers that match no dir.XXX prefix rule at all.
# Same mechanism SailfishOS's droid-hal-early-init.sh uses for lipstick,
# just pointed at our own binaries' real location.
#
# NOTE this early copy is only a defensive bootstrap value in case anything
# reads /linkerconfig/ld.config.txt before droid-hal-init's first real
# linkerconfig call -- it is NOT confirmed to be what fixes phoc's namespace
# access on its own (see kaos-droid-hal-init.sh and
# /usr/libexec/droid-hybris/system/bin/linkerconfig for the HYBRIS_BUILD
# stub-binary mechanism this project is now also using, and
# kaos-droid-hal-init.service's Type=notify + HWComposer-readiness gate for
# the other half of the 2026-09-24 fix -- phoc may simply have been starting
# before droid-hal-init's own boot had reached a consistent state at all).
if ! grep -q '^dir\.system = /usr/bin/\?$' /linkerconfig/ld.config.txt 2>/dev/null; then
    sed -i '1i dir.system = /usr/bin/' /linkerconfig/ld.config.txt \
        && log "linkerconfig: added dir.system = /usr/bin/ (routes phoc/phosh into [system] namespace)" \
        || log "WARN: failed to patch dir.system rule into linkerconfig"
fi

# selinuxfs: confirmed live this kernel's SELinux really is enforcing and
# /sys/fs/selinux exists as a kernel-provided mountpoint directory
# regardless -- but nothing in this distro's own boot ever mounts the
# selinuxfs filesystem there (ubuntu itself doesn't use SELinux), and each
# mount namespace needs its own explicit mount of it, it isn't part of the
# generic sysfs tree. Without it, droid-hal-init's own libselinux calls have
# nothing to query: confirmed live as "security_setenforce(0) failed --
# kernel may stay enforcing: No such file or directory" immediately followed
# by "Could not get process context" on every single service/exec start it
# then attempts (gatekeeper-1-0, keymaster-4-0, fsverity_init, apexd, ...).
if ! mountpoint -q /sys/fs/selinux 2>/dev/null; then
    mount -t selinuxfs selinuxfs /sys/fs/selinux 2>/dev/null \
        && log "mounted selinuxfs" || log "WARN: selinuxfs mount failed"
fi

# Deterministic core dump capture, paired with phosh.service's own
# LimitCORE=infinity (kaos.init). kernel.core_pattern is a single global
# sysctl (this cold-boot environment is real PID 1, not a nested pid
# namespace, so this applies system-wide for the rest of this boot) --
# default "core" writes to the crashing process's own cwd, which is why an
# earlier SIGSEGV investigation (2026-09-24) found nothing anywhere. Give
# it a fixed, persistent, always-findable target instead.
mkdir -p /var/crash
chmod 1777 /var/crash
echo '/var/crash/core.%e.%p.%t' > /proc/sys/kernel/core_pattern 2>/dev/null \
    && log "set kernel.core_pattern -> /var/crash/core.%e.%p.%t" \
    || log "WARN: failed to set kernel.core_pattern"

# kernel.suid_dumpable: separate from RLIMIT_CORE (LimitCORE=infinity on
# phosh.service itself) and defaults to 0 on most systems. The kernel
# automatically clears a process's own "dumpable" flag whenever it changes
# UID/GID or drops capabilities -- exactly what happens here: systemd forks
# phosh.service as root and drops to User=1000, then capsh --noamb further
# manipulates capabilities before exec'ing phosh-session. A non-dumpable
# process produces NO core dump at all regardless of RLIMIT_CORE. Confirmed
# live 2026-09-25: after adding LimitCORE=infinity + this same core_pattern
# and disabling apport (which was overwriting core_pattern), phoc's crash
# still produced zero core file, and systemd's own accounting changed from
# "code=dumped" (seen in EARLIER tests, before any of today's core-dump
# fixes, when RLIMIT_CORE defaulted to 0) to "code=killed" (WCOREDUMP not
# set at all) -- the signature of a non-dumpable process, not an RLIMIT
# problem. 2 (suidsafe) rather than 1 (debug): dumps end up owned by root,
# appropriate since we read them via gdb as root over adb, not as
# defaultuser.
echo 2 > /proc/sys/kernel/suid_dumpable 2>/dev/null \
    && log "set kernel.suid_dumpable=2 (suidsafe)" \
    || log "WARN: failed to set kernel.suid_dumpable"

# kernel.yama.ptrace_scope: this rootfs ships /etc/sysctl.d/10-ptrace.conf
# setting scope=1 ("restricted" -- attach only from a direct ancestor, or a
# process with CAP_SYS_PTRACE). Confirmed live 2026-09-24: phosh.service's
# own base unit has User=1000 (not root), so our gdb-catch diagnostic script
# -- a sibling of phoc in the process tree, not its ancestor -- ran as the
# same uid 1000 with no CAP_SYS_PTRACE, and every attach attempt failed with
# "ptrace: Inappropriate ioctl for device" before gdb ever held the process.
# Scope 0 allows any same-uid attach regardless of ancestry, which is all
# this single-user dev device needs for gdb to actually catch phoc's crash.
echo 0 > /proc/sys/kernel/yama/ptrace_scope 2>/dev/null \
    && log "set kernel.yama.ptrace_scope=0 (unrestricted same-uid attach)" \
    || log "WARN: failed to set kernel.yama.ptrace_scope"

# SAFETY, not optional: droid-hal-init holds CAP_SYS_BOOT. An unpatched
# vendor rc file with reboot_on_failure whose service fails here hard-reboots
# the physical device, not just this container. apexd's own reboot_on_failure
# is already neutralized at build time (apexd-hybris.rc's `override`); these
# three are only ever neutralized at runtime, same as droid-hal-startup.sh
# does for SailfishOS.
patch_rc_no_reboot() {
    local orig="$1" tmp
    [ -f "$orig" ] || return 0
    tmp=$(mktemp -t kaos-rc.XXXXXX) || return 1
    grep -v 'reboot_on_failure' "$orig" > "$tmp"
    mount --bind "$tmp" "$orig" && log "patched $(basename "$orig") (removed reboot_on_failure)" \
        || log "WARN failed to patch $orig"
}
patch_rc_no_reboot /vendor/etc/init/boringssl_self_test.rc

# Real surfaceflinger was found genuinely running and crash-looping this
# whole time (2026-09-24), fighting phoc for the same exclusive HWComposer
# HAL connection -- root-caused via a live journal capture showing
# droid-hal-init repeatedly starting/killing it (SIGABRT -> SIGKILL,
# 5+ times) throughout every single "failed to create composer client"
# episode we'd been chasing all session, and phoc's eventual SIGSEGV landed
# in the exact same second real surfaceflinger finally won the race and
# registered itself with servicemanager (triggering bootanim). None of our
# init.rc patches ever stopped it: surfaceflinger.rc declares
# `class core animation`, not `main`/`late_start` (the only classes our
# init.rc sed strips class_start for) -- "core" is deliberately left alone
# since that's also where the real WLAN/vendor HAL services we DO want
# (qrtr-ns, pd-mapper, cnss-daemon) live, so a class-level strip can't
# distinguish the two.
#
# SailfishOS's own droid-hal-startup.sh already solved this exact class of
# problem via disabled_services.rc (hybris/droid-configs/sparse/usr/libexec/
# droid-hybris/system/etc/init/disabled_services.rc, override+disabled
# idiom) -- but that file is installed at, and only takes effect at,
# /usr/libexec/droid-hybris/system/etc/init/, because SailfishOS's own
# droid-hal-init is pointed at that whole mirrored /usr/libexec/droid-hybris/
# system/ tree instead of the real /system/ (confirmed: droid-hal-startup.sh
# itself patches /usr/libexec/droid-hybris/system/etc/init/hw/init.rc, not
# /system/etc/init/hw/init.rc). Our cold-boot droid-hal-init has no such
# remapping -- confirmed live via its own log, "Parsing file /system/etc/
# init/surfaceflinger.rc..." -- it reads the real /system/etc/init/ tree
# directly, so dropping Sailfish's file in at their path would never be
# read at all here. Following the same disabled_services.rc idiom (all the
# same services, 2026-09-24), but applied the way this cold-boot path
# already patches other real rc files: bind-mount-replace each one directly,
# reusing patch_rc_no_reboot's proven mechanism instead of adding a
# same-directory override file whose parse-order-wins semantics were never
# proven against this specific droid-hal-init/rc tree. update_engine.rc
# doesn't exist on this build at all (grep across every /**/etc/init/ found
# nothing under any name) -- nothing to disable, skipped rather than
# guessed at. vold and netbpfload (bpfloader) were previously only patched
# via patch_rc_no_reboot (reboot_on_failure removal, letting them still run)
# -- upgraded here to full disable, matching Sailfish's own list exactly,
# since a disabled service can't crash-loop or contend for resources at all.
# Parameterized by service name only, not by file path: gpu's real rc file
# is gpuservice.rc and bpfloader's is netbpfload.rc -- neither filename
# matches its own service name, which only surfaced by manually grepping
# each one on-device. Hardcoding those paths would silently go stale if a
# future AOSP/vendor update renames or relocates any of these (the
# [ -f "$orig" ] guard would just skip it without complaint). Instead,
# search the real, currently-shipped init directories for whichever file
# actually declares "service $name" and patch that one -- reusing whatever
# ships with this build rather than assuming a path.
patch_rc_disable_service() {
    # $1 = service name (both the thing we search for and the fake exec
    # path/log message).
    local name="$1" orig tmp
    orig=$(grep -rl "^service $name " \
        /system/etc/init /vendor/etc/init /system_ext/etc/init \
        /product/etc/init /odm/etc/init 2>/dev/null | head -n1)
    [ -n "$orig" ] || { log "skip disabling $name (no rc file declares it on this build)"; return 0; }
    tmp=$(mktemp -t kaos-rc.XXXXXX) || return 1
    cat > "$tmp" <<EOF
service $name /system/bin/${name}_HYBRIS_DISABLED
    disabled
EOF
    mount --bind "$tmp" "$orig" && log "patched $(basename "$orig") (disabled $name -- matches SailfishOS's own disabled_services.rc)" \
        || log "WARN failed to patch $orig"
}
for _svc in surfaceflinger cameraserver audioserver netd installd lmkd \
            storaged bootanim gpu mediaextractor mediametrics bpfloader vold \
            display-color-hal-1-0 vendor.wifi_hal_legacy wpa_supplicant \
            wifidisplayhalservice wificond; do
    patch_rc_disable_service "$_svc"
done
# Disabling the last 4 above matches SailfishOS's own droid-hal-startup.sh
# ("SailfishOS does not use Android keystore, wifi HAL, or capability
# config store" -- it explicitly disables android.hardware.wifi-service.rc)
# -- we never had an equivalent for WiFi at all. Confirmed live 2026-09-25:
# with these still running, vendor.cnss-daemon's first launch immediately
# SIGABRTs and a later instance's icnss "Root PD" shuts down after ~2
# minutes -- Android's own wificond + vendor HAL wpa_supplicant (literally
# named "wpa_supplicant", same as ours) were independently driving the same
# wlan0/firmware resources our own kaos-wlan.service/cnss-daemon also try
# to own, at the same time.

# Display HAL fixes, ported directly from droid-hal-startup.sh's own
# patch_rc_display_hal() (2026-09-25). Three real, previously-unaddressed
# gaps this closes:
#
# 1. onrestart restart surfaceflinger: vendor.hwcomposer-2-3's own rc
#    declares this. Confirmed live this device's hwcomposer-2-3 DOES
#    restart during boot -- every restart re-triggers an explicit `restart
#    surfaceflinger` action, and an explicit restart/start command can
#    still start a `disabled` service (disabled only blocks *automatic*
#    starts via class_start). So the surfaceflinger-disable fix above was
#    likely only holding until the first HWComposer restart, not
#    permanently -- this closes that backdoor at the source.
# 2. task_profiles removed: this device's cpuset hierarchy isn't fully set
#    up in this switch_root environment (confirmed live: droid-hal-init's
#    own `copy /dev/cpuset/cpus ...` actions fail with "No such file or
#    directory" for every class). task_profiles assignment depends on that
#    same cpuset infrastructure; leaving it in risks the service failing
#    to start cleanly for a reason unrelated to the HAL itself.
# 3. class hal animation -> class hal: removes ONLY the "animation" class
#    tag (not a full disable) so the service still starts normally via
#    class_start hal, just without whatever animation-class-triggered
#    start/restart behavior this Android 15 vintage no longer expects in a
#    hybris environment.
#
# vendor.display.color@1.0 (HAL, not this rc-level fix) is deliberately
# NOT included here -- disabled entirely above instead (display-color-
# hal-1-0), matching SailfishOS's own conclusion it has no real consumer on
# this kind of userspace. surfaceflinger.rc is also deliberately excluded:
# it's already fully replaced by patch_rc_disable_service above (a minimal
# 2-line stub with none of these three problems), so re-patching it here
# would be a no-op at best.
patch_rc_display_hal() {
    local orig="$1" tmp
    [ -f "$orig" ] || return 0
    tmp=$(mktemp -t kaos-rc.XXXXXX) || return 1
    sed -e '/onrestart.*surfaceflinger/d' \
        -e '/^service vendor.hwcomposer-2-3 /a\    override' \
        -e '/task_profiles/d' \
        -e 's/class hal animation/class hal/' \
        "$orig" > "$tmp"
    mount --bind "$tmp" "$orig" && log "patched $(basename "$orig") (display HAL fixes -- matches SailfishOS's own patch_rc_display_hal)" \
        || log "WARN failed to patch $orig"
}
patch_rc_display_hal /vendor/etc/init/android.hardware.graphics.composer@2.3-service.rc
patch_rc_display_hal /vendor/etc/init/vendor.qti.hardware.display.allocator@1.0-service.rc
patch_rc_display_hal /vendor/etc/init/android.hardware.sensors@1.0-service.rc

# Also not optional: strip class_start main/late_start and trigger
# zygote-start, or droid-hal-init tries to boot an entire second Android
# userspace (zygote, system_server, app framework) inside the container
# alongside it, not just the early hal/core-class vendor daemons we want.
orig=/system/etc/init/hw/init.rc
if [ -f "$orig" ]; then
    tmp=$(mktemp -t kaos-rc.XXXXXX)
    # wait_for_prop odsign.key.done 1: confirmed live this was the actual
    # deadlock past every earlier fix. It's the very next post-fs-data
    # action after `start odsign` (already stripped below, on the same
    # reasoning as logd) -- but nothing ever removed the wait paired with
    # it, so init's single-threaded command queue blocked here forever
    # (4+ minutes of total silence observed, not a timeout). Since
    # `on late-init` fires post-fs-data/load-bpf-programs/zygote-start/
    # boot as sequential `trigger` lines in ONE action list, this one
    # blocking wait_for_prop stalled everything after it too, including
    # `trigger boot` -> `on boot` -> `class_start core`, the actual trigger
    # for qrtr-ns/pd-mapper/cnss-daemon. Not stripping the matching
    # odsign.verification.done wait in `on zygote-start` -- that whole
    # block never runs at all now (nothing triggers zygote-start once its
    # own trigger line below is gone), so it's moot there.
    #
    # init_user0 (bare builtin command, line ~1066, not a text match for
    # any "vdc"/"exec" pattern -- it's a compiled-in init action that makes
    # its own blocking Binder call into vold to initialize user 0's
    # storage): confirmed live 2026-09-24, right after upgrading vold from
    # patch_rc_no_reboot (left it running) to a full disable (matching
    # SailfishOS's own disabled_services.rc list) -- with vold now genuinely
    # not running, this call has nothing to answer it and stalls for ~57s
    # before giving up, which was long enough to push vendor.hwcomposer-2-3's
    # own later class_start past our own 20s HWComposer-readiness poll
    # window in kaos-droid-hal-init.sh. Stripping it here, same as the other
    # vdc-touching lines above.
    sed -e '/reboot_on_failure/d' \
        -e '/[[:space:]]start logd$/d' \
        -e '/[[:space:]]start logd-reinit$/d' \
        -e '/[[:space:]]start odsign$/d' \
        -e '/wait_for_prop odsign\.key\.done 1$/d' \
        -e '/[[:space:]]start derive_classpath$/d' \
        -e '/[[:space:]]exec_start bpfloader$/d' \
        -e '/exec.*vdc.*checkpoint/d' \
        -e '/exec.*vdc.*keymaster/d' \
        -e '/^[[:space:]]*init_user0$/d' \
        -e '/[[:space:]]class_start main$/d' \
        -e '/[[:space:]]class_start late_start$/d' \
        -e '/trigger zygote-start/d' \
        "$orig" > "$tmp"
    mount --bind "$tmp" "$orig" && log "patched $(basename "$orig") (hybris fixes)" \
        || log "WARN failed to patch $orig"
fi

# keystore2/keymaster-4-0 were seen crash-looping continuously (SIGABRT
# every ~5s). A prior version of this script disabled them outright rather
# than diagnose -- root-caused properly instead: the real tombstone
# (persisted under /android_data/tombstones/, readable straight off Android
# since it's just this distro's own rootfs) gave the actual abort message:
# "Could not register service for Keymaster 4.0 (-2147483648)" -- -2147483648
# is INT32_MIN, exactly how Android defines UNKNOWN_ERROR. Cross-referenced
# with "Command 'start hwservicemanager' ... failed: service hwservicemanager
# not found" -- hwservicemanager.rc only exists under
# /system_ext/etc/init/, a separate dm-linear partition this script never
# mounted (only /system and /vendor), so droid-hal-init's init.rc directory
# scan never found it at all, no HIDL service manager ever ran, and every
# HIDL registration attempt failed. Fixed at the source by mounting
# /system_ext (+ /product, /odm for the same reason) via the matching
# SailfishOS-proven units -- see kaos-droid-hal-init.service's ordering and
# build-rootfs.sh's mount-unit install list.

# droid-hal-init's own first-stage internally re-execs itself via the
# hardcoded path /sbin/droid-hal-init (confirmed live: "execv(\"/sbin/
# droid-hal-init\") failed: No such file or directory" right after "init
# first stage started!") -- it's built (hybris/hybris-boot/Android.mk)
# assuming it will be installed there directly, matching how SailfishOS's
# own droid-hal RPM deploys it. We ship it via the Android system partition
# instead (kaos/kaos.mk PRODUCT_PACKAGES, so every distro's cold boot can
# reach one shared build through the same /system mount), so give it the
# self-reference it expects.
[ -e /sbin/droid-hal-init ] || ln -sf /system/bin/droid-hal-init /sbin/droid-hal-init

# TRD-010/TRD-016: this ROM's system-wide /system/lib64/libselinux.so has
# security_getenforce() hardcoded to always report ENFORCING (deliberate
# banking-app/Play-Integrity anti-tampering spoof). servicemanager/
# hwservicemanager -- which droid-hal-init is about to start -- do their own
# { add } access check in USERSPACE via that same function, so the spoof
# makes them self-deny vendor-HAL/composer registration even when the
# kernel's actual policy would allow it. droid-hal-startup.sh (SailfishOS's
# own equivalent of this script) already solved this: the patched
# security_getenforce() checks for this exact marker and reports the real
# kernel state instead, but only for processes that can see it. Must exist
# before droid-hal-init starts servicemanager -- this is the last line
# before this service exits for exactly that reason. Confirmed live
# 2026-09-24: without it, phoc's composer client creation failed every
# restart ("failed to create composer client", repeating) even after fixing
# the separate EGL/libhybris-vs-Mesa library collision.
touch /dev/.hybris_selinux_real 2>/dev/null \
    && log "created /dev/.hybris_selinux_real (real enforce state for hybris HAL registration)" \
    || log "WARN: could not create /dev/.hybris_selinux_real -- HAL/composer registration may stay blocked"

# --- Real APEX activation, ported from SailfishOS's droid-hal-startup.sh
# (2026-09-24) --------------------------------------------------------------
#
# Our /apex above is still just the hand-rolled bootstrap fallback -- real
# apexd needs /dev/device-mapper to activate anything at all (each APEX is a
# dm-verity/dm-linear device; apexd opens this exact Android-specific path,
# not /dev/mapper/control). Without it, apexd-bootstrap fails immediately
# ("Failed to open device-mapper"), NO APEX ever activates -- including
# com.android.runtime, which holds the real `linkerconfig` binary.
if [ ! -e /dev/device-mapper ]; then
    dm_minor=$(awk '$2=="device-mapper"{print $1}' /proc/misc 2>/dev/null)
    if [ -n "$dm_minor" ]; then
        mknod /dev/device-mapper c 10 "$dm_minor" && chmod 600 /dev/device-mapper \
            && log "created /dev/device-mapper (c 10 $dm_minor) for apexd" \
            || log "WARN: mknod /dev/device-mapper failed"
    else
        log "WARN: device-mapper minor not in /proc/misc -- apexd APEX activation will fail"
    fi
fi

log "=== DONE ==="
