#!/bin/sh
# Force RNDIS USB developer mode on perseus, independent of usb-moded (TRD-007).
#
# In the switch_root cold-boot environment, usb-moded's MCE cable detection is
# unreliable and it tries the wrong configfs function (rndis_bam.rndis) instead of
# the SDM845 gsi.rndis, so developer mode never activates. The 10-usb-configfs.conf
# drop-in builds the gadget *structure* (g1 + config b.1 + gsi.rndis function) but
# never links the function into the config or binds the UDC, so nothing enumerates.
#
# This service completes the gadget using the exact attributes the working Android
# gadget uses (read from a live Android boot: gsi.rndis has no dev_addr/host_addr;
# functions link as f1; os_desc b_vendor_code=0x1), binds the DWC3 UDC, brings up
# rndis0 with the standard Jolla device IP, and serves DHCP to the host.
G=/config/usb_gadget/g1
UDCDEV=a600000.dwc3
DEV_IP=192.168.2.15
LOGF=/var/log/usb-rndis.log
log() { echo "$(date '+%H:%M:%S') usb-rndis: $*" >> "$LOGF"; echo "usb-rndis: $*" > /dev/kmsg 2>/dev/null; }

i=0
while [ ! -d /config/usb_gadget ] && [ $i -lt 30 ]; do sleep 1; i=$((i+1)); done
[ -d /config/usb_gadget ] || { log "usb_gadget root never appeared — aborting"; exit 0; }

# --- Build the gadget (idempotent; mirrors the working Android gsi.rndis setup) ---
mkdir -p "$G/strings/0x409" "$G/configs/b.1/strings/0x409" "$G/functions/gsi.rndis"
printf '0x05C6'   > "$G/idVendor"
printf '0xF00E'   > "$G/idProduct"
printf '0x0200'   > "$G/bcdUSB"
printf 'Xiaomi'   > "$G/strings/0x409/manufacturer"
printf 'Mi Mix 3' > "$G/strings/0x409/product"
printf 'perseus'  > "$G/strings/0x409/serialnumber"
printf '900'      > "$G/configs/b.1/MaxPower"
printf 'rndis'    > "$G/configs/b.1/strings/0x409/configuration"

# Unbind the UDC before editing config links — the kernel rejects edits while bound.
[ -s "$G/UDC" ] && echo "" > "$G/UDC" 2>/dev/null

# Replace whatever function is currently linked (e.g. ffs.adb) with gsi.rndis as f1.
for l in "$G"/configs/b.1/f*; do
    [ -L "$l" ] && rm -f "$l"
done
ln -s "$G/functions/gsi.rndis" "$G/configs/b.1/f1" 2>/dev/null

# Windows RNDIS auto-install descriptors (values from the working Android gadget).
echo 1       > "$G/os_desc/use" 2>/dev/null
echo 0x1     > "$G/os_desc/b_vendor_code" 2>/dev/null
echo MSFT100 > "$G/os_desc/qw_sign" 2>/dev/null
[ -e "$G/os_desc/b.1" ] || ln -s "$G/configs/b.1" "$G/os_desc/b.1" 2>/dev/null

# Bind to the DWC3 controller. Cold-boot: bind now, don't wait for a cable event.
# Retry: the bind intermittently fails (boot 01:28) — usually because the config has
# no function linked yet (kernel rejects an empty config with EINVAL) or the UDC is
# transiently busy. Each attempt re-asserts the f1 link, clears the UDC, and rebinds.
UDC=$(ls /sys/class/udc 2>/dev/null | grep -Fx "$UDCDEV" || ls /sys/class/udc 2>/dev/null | head -1)
BOUND=0
for attempt in 1 2 3 4 5; do
    # Ensure the function is linked into the config before binding (empty config => EINVAL).
    [ -L "$G/configs/b.1/f1" ] || ln -s "$G/functions/gsi.rndis" "$G/configs/b.1/f1" 2>/dev/null
    echo "" > "$G/UDC" 2>/dev/null   # clear any stale/partial binding
    if echo "$UDC" > "$G/UDC" 2>/dev/null; then
        log "bound gsi.rndis to UDC $UDC (attempt $attempt)"
        BOUND=1
        break
    fi
    log "UDC bind attempt $attempt failed (UDC='$UDC', f1=$(readlink "$G/configs/b.1/f1" 2>/dev/null)); retrying"
    sleep 1
done
[ "$BOUND" -eq 1 ] || log "WARN: UDC bind failed after 5 attempts (UDC='$UDC')"

# --- Bring up rndis0 ---
i=0
while [ ! -d /sys/class/net/rndis0 ] && [ $i -lt 10 ]; do sleep 1; i=$((i+1)); done
if [ ! -d /sys/class/net/rndis0 ]; then
    log "WARN: rndis0 did not appear after UDC bind — RNDIS function may not have instantiated"
    exit 0
fi
/usr/sbin/ip addr add "${DEV_IP}/24" dev rndis0 2>/dev/null
/usr/sbin/ip link set rndis0 up
log "rndis0 up at ${DEV_IP}/24"

# Open the firewall for the dev RNDIS link. Disabling usb-moded removed the
# developer_mode firewall opening, so incoming traffic on rndis0 (ICMP, SSH) is
# otherwise dropped (ARP resolves but connections time out). Accept all input on
# rndis0 so SSH to ${DEV_IP} works. Idempotent (check-then-insert).
if [ -x /sbin/iptables ]; then
    /sbin/iptables -C INPUT -i rndis0 -j ACCEPT 2>/dev/null \
        || /sbin/iptables -I INPUT -i rndis0 -j ACCEPT 2>/dev/null
    log "firewall: accept input on rndis0 ($(/sbin/iptables -C INPUT -i rndis0 -j ACCEPT 2>/dev/null && echo ok || echo '?'))"
fi

# --- DHCP for the host (best-effort; lets the SDK/host auto-configure) ---
if [ -x /usr/sbin/udhcpd ]; then
    cat > /tmp/udhcpd-rndis.conf <<EOF
interface rndis0
start 192.168.2.20
end 192.168.2.29
option subnet 255.255.255.0
option router ${DEV_IP}
option lease 3600
lease_file /tmp/udhcpd-rndis.leases
pidfile /tmp/udhcpd-rndis.pid
EOF
    : > /tmp/udhcpd-rndis.leases
    if /usr/sbin/udhcpd /tmp/udhcpd-rndis.conf 2>/dev/null; then
        log "udhcpd serving 192.168.2.20-29 on rndis0"
    else
        log "WARN: udhcpd start failed (host can use a static 192.168.2.x address)"
    fi
fi
exit 0
