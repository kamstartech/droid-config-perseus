#!/bin/sh
# One-shot post-boot diagnostic collector for the open SailfishOS TRD issues.
# Runs once ~75s after boot (after UI + HAL services settle) and writes targeted
# info per TRD to $OUT, which is pulled from Android afterward. Each section is
# independent and best-effort; failures never abort the rest. Remove once diagnosed.
OUT=/var/log/sfos-diag.log
OUT_DIR=/var/log

# Supplementary detail logs (pulled alongside the main log).
RADIO_LOG=$OUT_DIR/sfos-diag-radio.log
SENSORS_LOG=$OUT_DIR/sfos-diag-sensors.log
AUDIO_LOG=$OUT_DIR/sfos-diag-audio.log
CONTACTS_LOG=$OUT_DIR/sfos-diag-contacts.log
RNDIS_LOG=$OUT_DIR/sfos-diag-rndis.log
JOURNAL_LOG=$OUT_DIR/sfos-diag-journal.log
FS_LOG=$OUT_DIR/sfos-diag-fs.log

sleep 75                      # let lipstick, droid-hal HALs, oFono, apps settle
exec >"$OUT" 2>&1

echo "===== sfos-diag $(date) ====="
uptime 2>/dev/null

pid_of() { /usr/bin/pgrep -f "$1" 2>/dev/null | head -1; }

# Helper: run a command and tee both to stdout (main log) and a detail file.
# Usage: tee_section <detail-file> <section-title> <command> [args...]
tee_section() {
    _file=$1; shift
    _title=$1; shift
    echo; echo "########## $_title ##########"
    echo "(full detail also in $_file)"
    "$@" 2>&1 | tee "$_file"
}

# Helper: dump a command only to a detail file, with a header.
# If the first argument is not an executable command, only the header is written.
detail() {
    _file=$1; shift
    echo "===== $* =====" >> "$_file"
    if [ -n "$1" ] && command -v "$1" >/dev/null 2>&1; then
        "$@" >> "$_file" 2>&1 || true
    fi
    echo >> "$_file"
}

# Clear/detail-init supplementary logs (best-effort; don't fail if ro).
for f in "$RADIO_LOG" "$SENSORS_LOG" "$AUDIO_LOG" "$CONTACTS_LOG" "$RNDIS_LOG" "$JOURNAL_LOG" "$FS_LOG"; do
    : > "$f" 2>/dev/null || true
done

echo; echo "########## TRD-022: GPU driver — zink/Turnip (HW) vs llvmpipe (SW) ##########"
echo "--- processes with /dev/kgsl-3d0 open (= hardware GPU users; SW rendering opens none) ---"
for p in /proc/[0-9]*; do
    if ls -l "$p/fd" 2>/dev/null | grep -q 'kgsl'; then
        echo "  $(cat "$p/comm" 2>/dev/null) [$(basename "$p")]"
    fi
done
LPID=$(pid_of /usr/bin/lipstick)
echo "--- lipstick ($LPID) GL/driver libs mapped (look for libgallium / libvulkan_freedreno = zink/Turnip; llvmpipe = software) ---"
[ -n "$LPID" ] && grep -oE 'lib(gallium_dri|vulkan_freedreno|EGL|GLESv2|gallium-[0-9]+)[^ ]*\.so[^ ]*|llvmpipe|swrast' /proc/"$LPID"/maps 2>/dev/null | sort -u
echo "--- DRI_PRIME/MESA env actually seen by lipstick ---"
[ -n "$LPID" ] && tr '\0' '\n' < /proc/"$LPID"/environ 2>/dev/null | grep -iE 'MESA|EGL|QT_QPA|GALLIUM|ZINK'

echo; echo "########## TRD-010: modem / qcrild IRadio not registered ##########"
echo "--- modem remoteproc state (the 'No pas_id found' lead: is MSS actually booted?) ---"
for rp in /sys/class/remoteproc/remoteproc*; do
    [ -d "$rp" ] && echo "  $(cat "$rp/name" 2>/dev/null) = $(cat "$rp/state" 2>/dev/null)"
done
QPID=$(pid_of qcrild)
echo "--- qcrild pid=$QPID ---"
if [ -n "$QPID" ]; then
    grep -E 'State|Uid' /proc/"$QPID"/status 2>/dev/null
    echo "  open sockets/qmi/hwbinder fds:"
    ls -l /proc/"$QPID"/fd 2>/dev/null | grep -iE 'socket|qmux|qmi|hwbinder|smd|qrtr' | head -20
fi
echo "--- qmux_radio socket + rmt_storage + qrtr ---"
ls -l /dev/socket/qmux_radio 2>/dev/null
echo "  rmt_storage pid: $(pid_of rmt_storage)   qrtr-ns pid: $(pid_of qrtr)"
echo "--- IRadio registration attempt via getprop ril state ---"
/system/bin/getprop 2>/dev/null | grep -iE 'ril|radio|modem|vendor.qcrild' | head -20

echo; echo "########## TRD-010a: logd / logcat health (qcril visibility) ##########"
LOGD_PID=$(pid_of logd)
echo "  logd pid: $LOGD_PID"
if [ -n "$LOGD_PID" ]; then
    echo "  logd status:"
    grep -E 'State|Pid|PPid' /proc/"$LOGD_PID"/status 2>/dev/null
    echo "  Recent radio buffer (logcat -d -b radio -t 200):"
    if command -v /system/bin/logcat >/dev/null 2>&1; then
        /system/bin/logcat -d -b radio -t 200 > "$RADIO_LOG" 2>&1
    else
        echo "  /system/bin/logcat not found" > "$RADIO_LOG"
    fi
    if [ -s "$RADIO_LOG" ]; then
        head -n 30 "$RADIO_LOG"
        echo "  (... full radio log in $RADIO_LOG)"
    else
        echo "  (radio buffer empty or logd not responding)"
    fi
else
    echo "  WARNING: logd is NOT running — qcril QMI/IRadio logs are lost."
fi

echo; echo "########## TRD-011: sensors (sensorfwd plugins) ##########"
SHPID=$(pid_of android.hardware.sensors)
SFPID=$(pid_of sensorfwd)
echo "  sensors HAL pid=$SHPID   sensorfwd pid=$SFPID"
echo "--- /dev/hwbinder context + sensor input devices ---"
ls -lZ /dev/hwbinder 2>/dev/null
ls /sys/class/sensors/ 2>/dev/null | head
echo "--- sensorfwd reachable test: list its open fds (hwbinder/sensor nodes?) ---"
[ -n "$SFPID" ] && ls -l /proc/"$SFPID"/fd 2>/dev/null | grep -iE 'hwbinder|sensor|input|binder' | head

# Detail: sensorfwd plugin debug and test_sensors
detail "$SENSORS_LOG" "sensorfwd service status"
systemctl status sensorfwd --no-pager >> "$SENSORS_LOG" 2>&1 || true
detail "$SENSORS_LOG" "sensorfw configs"
ls -la /etc/sensorfw/ >> "$SENSORS_LOG" 2>&1 || true
cat /etc/sensorfw/primaryuse.conf >> "$SENSORS_LOG" 2>&1 || true
detail "$SENSORS_LOG" "test_sensors output"
/usr/bin/test_sensors >> "$SENSORS_LOG" 2>&1 || true
detail "$SENSORS_LOG" "sensorfwd journal tail"
journalctl -u sensorfwd --no-pager -n 50 >> "$SENSORS_LOG" 2>&1 || true
echo "  (sensor detail in $SENSORS_LOG)"

echo; echo "########## TRD-018: libbinder system/vendor mismatch (Parcel SYST/VNDR) ##########"
echo "--- REAL mix: processes mapping BOTH /system AND /vendor libbinder.so ---"
echo "    (matches the FULL libbinder.so only; libbinder_ndk.so from /system is legitimate and NOT counted)"
_realmix=0
for p in /proc/[0-9]*; do
    m="$p/maps"
    [ -r "$m" ] || continue
    sys=$(grep -c '/system/.*libbinder\.so' "$m" 2>/dev/null)
    ven=$(grep -c '/vendor/.*libbinder\.so' "$m" 2>/dev/null)
    if [ "${sys:-0}" -gt 0 ] && [ "${ven:-0}" -gt 0 ]; then
        echo "  REAL-MIX: $(cat "$p/comm" 2>/dev/null) [$(basename "$p")] /system libbinder.so=$sys /vendor libbinder.so=$ven"
        _realmix=$((_realmix+1))
    fi
done
[ "$_realmix" -eq 0 ] && echo "  none — no process maps two full libbinder.so copies (SYST/VNDR mix resolved)"
echo "--- per-process libbinder*.so origin (TRD-018 fix target: qcrild/qseecomd should show /vendor libbinder.so + /system libbinder_ndk.so ONLY) ---"
for proc in qcrild qcrild2 qcrild3 qseecomd; do
    pp=$(pid_of "$proc"); [ -n "$pp" ] && { echo "  $proc [$pp]:"; grep -oE '/(system|vendor|apex)[^ ]*libbinder[^ ]*\.so' /proc/"$pp"/maps 2>/dev/null | sort -u | sed 's/^/      /'; }
done
echo "--- booster/pulseaudio libbinder origin ---"
for proc in booster-silica-media pulseaudio invoker; do
    pp=$(pid_of "$proc"); [ -n "$pp" ] && { echo "  $proc [$pp]:"; grep -oE '/(system|vendor)/[^ ]*libbinder[^ ]*\.so' /proc/"$pp"/maps 2>/dev/null | sort -u; }
done

echo; echo "########## TRD-019: loudspeaker amp (WSA881x / TAS2557) ##########"
echo "--- SoundWire + amp state ---"
ls /sys/bus/soundwire/devices/ 2>/dev/null
cat /sys/kernel/debug/asoc/*/dapm/* 2>/dev/null | head -1
echo "--- tas2557 firmware now present in rootfs? ---"
ls -l /lib/firmware/tas2557_uCDSP.bin 2>/dev/null

# Detail: kernel audio/firmware messages
detail "$AUDIO_LOG" "dmesg tas2557/wsa881x/firmware"
dmesg | grep -iE 'tas2557|wsa881x|soundwire|firmware' >> "$AUDIO_LOG" 2>&1 || true
detail "$AUDIO_LOG" "loaded audio modules"
lsmod | grep -iE 'tas2557|wsa881x|snd|audio' >> "$AUDIO_LOG" 2>&1 || true
detail "$AUDIO_LOG" "firmware helper paths"
ls -la /lib/firmware/tas2557* /vendor/firmware/tas2557* /vendor/firmware_mnt/ >> "$AUDIO_LOG" 2>&1 || true
echo "  (audio detail in $AUDIO_LOG)"

echo; echo "########## TRD-013: contacts qtcontacts-sqlite semaphore ##########"
echo "NOTE: apps have a private /tmp (firejail) — this is the GLOBAL /tmp, may differ."
ls -ld /tmp 2>/dev/null
ls -l /tmp/qtcontacts-sqlite-semaphore 2>/dev/null || echo "  (no global /tmp/qtcontacts-sqlite-semaphore)"
echo "  contactsd pid: $(pid_of contactsd)"
ls -ld /home/defaultuser/.local/share/system/Contacts 2>/dev/null

# Detail: contactsd status and private tmp
detail "$CONTACTS_LOG" "contactsd status"
systemctl status contactsd --no-pager >> "$CONTACTS_LOG" 2>&1 || true
detail "$CONTACTS_LOG" "contacts journal tail"
journalctl -u contactsd --no-pager -n 50 >> "$CONTACTS_LOG" 2>&1 || true
detail "$CONTACTS_LOG" "app private /tmp (firejail)"
for app in jolla-messages voicecall-ui; do
    ap=$(pid_of "$app" | head -1)
    [ -n "$ap" ] && {
        echo "--- $app [$ap] root /tmp ---" >> "$CONTACTS_LOG"
        ls -la /proc/"$ap"/root/tmp 2>&1 >> "$CONTACTS_LOG" || true
    }
done
detail "$CONTACTS_LOG" "contacts data dir"
ls -la /home/defaultuser/.local/share/system/Contacts >> "$CONTACTS_LOG" 2>&1 || true
echo "  (contacts detail in $CONTACTS_LOG)"

echo; echo "########## TRD-007: USB RNDIS L3 (post-connman-blacklist) ##########"
/usr/sbin/ip addr show rndis0 2>/dev/null | grep -E 'inet|state'
echo "--- routes for 192.168.2.0/24 ---"
/usr/sbin/ip route 2>/dev/null | grep '192.168.2'
echo "--- firewall (is anything dropping rndis0?) ---"
/usr/sbin/iptables -S 2>/dev/null | grep -iE 'rndis|DROP|REJECT|INPUT' | head -20
echo "  sshd.socket: $(systemctl is-active sshd.socket 2>/dev/null)   connman ignores rndis? $(grep NetworkInterfaceBlacklist /etc/connman/main.conf 2>/dev/null)"

# Detail: RNDIS/SSH end-to-end verification
detail "$RNDIS_LOG" "sshd listening sockets"
ss -ltnp 2>/dev/null | grep ':22' >> "$RNDIS_LOG" || true
detail "$RNDIS_LOG" "usb gadget configfs"
ls -la /sys/kernel/config/usb_gadget/g1/ >> "$RNDIS_LOG" 2>&1 || true
cat /sys/kernel/config/usb_gadget/g1/UDC 2>/dev/null >> "$RNDIS_LOG" || true
detail "$RNDIS_LOG" "usb gadget functions"
ls -la /sys/kernel/config/usb_gadget/g1/functions/ >> "$RNDIS_LOG" 2>&1 || true
detail "$RNDIS_LOG" "usb rndis function config"
ls -la /sys/kernel/config/usb_gadget/g1/functions/gsi.rndis* 2>/dev/null >> "$RNDIS_LOG" || true
detail "$RNDIS_LOG" "udhcpd status"
systemctl status udhcpd --no-pager >> "$RNDIS_LOG" 2>&1 || true
ps | grep -i udhcpd >> "$RNDIS_LOG" 2>&1 || true
echo "  (RNDIS/SSH detail in $RNDIS_LOG)"

# Cross-cutting: binder interface registration
echo; echo "########## Binder interface snapshot ##########"
if command -v binder-list >/dev/null 2>&1; then
    echo "--- IRadio ---"
    binder-list -d /dev/hwbinder 2>/dev/null | grep -i 'IRadio' | head -10
    echo "--- ISensors ---"
    binder-list -d /dev/hwbinder 2>/dev/null | grep -i 'ISensors' | head -10
else
    echo "  binder-list not found in PATH"
fi

# Cross-cutting: journal snapshot for key services
echo; echo "########## Journal snapshot for key services ##########"
journalctl -b --no-pager -u lipstick -u sensorfwd -u ofono -u contactsd -u sshd.socket -u usb-rndis-up -u droid-hal-init -u droid-hal-startup -n 200 > "$JOURNAL_LOG" 2>&1
if [ -s "$JOURNAL_LOG" ]; then
    echo "  Captured $(wc -l < "$JOURNAL_LOG") journal lines to $JOURNAL_LOG"
    echo "  First/last timestamps:"
    head -n 1 "$JOURNAL_LOG"
    tail -n 1 "$JOURNAL_LOG"
else
    echo "  No journal entries captured (journaling not persistent or service names differ)"
fi

# Cross-cutting: filesystem and mount state
echo; echo "########## Filesystem and mount state ##########"
detail "$FS_LOG" "mount output"
mount >> "$FS_LOG" 2>&1 || true
detail "$FS_LOG" "disk free"
df -h >> "$FS_LOG" 2>&1 || true
detail "$FS_LOG" "fstab"
cat /etc/fstab >> "$FS_LOG" 2>&1 || true

detail "$FS_LOG" "key directory tree (depth 2)"
for dir in /system /vendor /apex /lib/firmware /tmp /home/defaultuser /data /var/log; do
    if [ -d "$dir" ]; then
        echo "--- $dir ---" >> "$FS_LOG"
        if command -v tree >/dev/null 2>&1; then
            tree -L 2 "$dir" 2>/dev/null >> "$FS_LOG" || true
        else
            find "$dir" -maxdepth 2 -print 2>/dev/null | head -n 100 >> "$FS_LOG" || true
        fi
        echo >> "$FS_LOG"
    fi
done

detail "$FS_LOG" "firmware and HAL binaries (depth 3)"
for dir in /vendor/firmware_mnt /vendor/bin/hw /system/bin/hw; do
    if [ -d "$dir" ]; then
        echo "--- $dir (depth 3) ---" >> "$FS_LOG"
        if command -v tree >/dev/null 2>&1; then
            tree -L 3 "$dir" 2>/dev/null >> "$FS_LOG" || true
        else
            find "$dir" -maxdepth 3 -print 2>/dev/null | head -n 200 >> "$FS_LOG" || true
        fi
        echo >> "$FS_LOG"
    fi
done

echo "  (filesystem detail in $FS_LOG)"

echo; echo "===== sfos-diag END ====="
