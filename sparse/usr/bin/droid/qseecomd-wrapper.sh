#!/system/bin/sh
# Diagnostic wrapper for vendor.qseecomd (TRD-010).
# Captures stderr to a file so we can see why qseecomd exits status 1.
# This is a temporary diagnostic tool; remove once qseecomd is stable.
OUT=/var/log/qseecomd.stderr.log
TS=$(date '+%H:%M:%S')
echo "===== qseecomd wrapper started at $TS =====" >> "$OUT"
echo "argv: $*" >> "$OUT"
echo "PATH: $PATH" >> "$OUT"
ls -lZ /vendor/bin/qseecomd >> "$OUT" 2>&1 || true
ls -lZ /dev/qseecom >> "$OUT" 2>&1 || true
ls -lZ /dev/ion >> "$OUT" 2>&1 || true
exec /vendor/bin/qseecomd "$@" 2>> "$OUT"
