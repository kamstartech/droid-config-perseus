#!/bin/sh
# Wait for the ADSP CPE (Codec Processor Engine) APR channel to be ready before
# PulseAudio starts. Called from pulseaudio.service.d/50-adsp-wait.conf.

CPE_STATE=/proc/asound/card0/cpe0_state
MAX_WAIT=120

start=$(awk '{print int($1)}' /proc/uptime)
logger -t adsp-wait "Waiting for ADSP CPE (boot=${start}s)..."

while true; do
    state=$(cat "$CPE_STATE" 2>/dev/null)
    if [ "$state" = "ONLINE" ]; then
        now=$(awk '{print int($1)}' /proc/uptime)
        logger -t adsp-wait "CPE ONLINE after $((now - start))s wait (boot=${now}s)"
        exit 0
    fi
    now=$(awk '{print int($1)}' /proc/uptime)
    if [ "$((now - start))" -ge "$MAX_WAIT" ]; then
        logger -t adsp-wait "WARN: CPE not ONLINE after ${MAX_WAIT}s (state=${state:-missing}) -- proceeding anyway"
        exit 0
    fi
    sleep 1
done
