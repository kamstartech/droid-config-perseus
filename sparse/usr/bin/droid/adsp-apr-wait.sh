#!/bin/sh
# Wait until ADSP audio APR is ready before PulseAudio starts.
# SDM845: adsprpcd opens /dev/adsprpc-smd at t~42s; APR link comes UP ~61s later
# at t~103s. t=120s gives a 17s safety margin.
TARGET=120
u=$(awk '{print int($1)}' /proc/uptime)
remaining=$((TARGET - u))
if [ "$remaining" -gt 0 ]; then
    logger -t adsp-apr-wait "boot=${u}s — sleeping ${remaining}s for ADSP APR"
    sleep "$remaining"
fi
logger -t adsp-apr-wait "APR ready — releasing PulseAudio (boot=$(awk '{print int($1)}' /proc/uptime)s)"
