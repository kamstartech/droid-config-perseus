#!/bin/sh
# Wait for ADSP CPE to come ONLINE, then load module-droid-card and module-droid-hidl.
#
# SDM845 boot timeline:
#   t=28s  ADSP firmware ready (Power/Clock ready interrupt)
#   t=41s  adsprpcd opens /dev/adsprpc-smd (after startup.sh SetupMountNamespaces wait)
#   t=41+  CPE transitions ONLINE (3s on warm NAND, up to ~61s on cold boot)
#
# /proc/asound/card0/cpe0_state is set ONLINE by the ASoC driver once the WCD9340
# codec DSP APR channel is established. This is the kernel-level readiness event.
# Polling it avoids Q6ASM zombie sessions from premature module-droid-card open.

CPE_STATE=/proc/asound/card0/cpe0_state
MAX_WAIT=120
XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/100000}"
export XDG_RUNTIME_DIR

start=$(awk '{print int($1)}' /proc/uptime)
logger -t droid-card-loader "Waiting for ADSP CPE (boot=${start}s)..."

while true; do
    state=$(cat "$CPE_STATE" 2>/dev/null)
    if [ "$state" = "ONLINE" ]; then
        now=$(awk '{print int($1)}' /proc/uptime)
        logger -t droid-card-loader "CPE ONLINE after $((now - start))s wait (boot=${now}s) — loading droid-card"
        break
    fi
    now=$(awk '{print int($1)}' /proc/uptime)
    if [ "$((now - start))" -ge "$MAX_WAIT" ]; then
        logger -t droid-card-loader "WARN: CPE not ONLINE after ${MAX_WAIT}s (state=${state:-missing}) — loading anyway"
        break
    fi
    sleep 1
done

pactl load-module module-droid-card rate=48000 use_legacy_stream_set_parameters=true \
    && logger -t droid-card-loader "module-droid-card loaded" \
    || { logger -t droid-card-loader "ERROR: module-droid-card failed to load"; exit 1; }

pactl load-module module-droid-hidl 2>/dev/null \
    && logger -t droid-card-loader "module-droid-hidl loaded" \
    || logger -t droid-card-loader "module-droid-hidl not available (skipped)"
