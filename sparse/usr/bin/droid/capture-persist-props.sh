#!/system/bin/sh
# capture-persist-props.sh — run from Android (adb shell) to dump /data/property
# into a snapshot that Sailfish can use under /etc/hybridos/persist-props.txt.
# Usage:
#   adb root
#   adb push capture-persist-props.sh /data/local/tmp/
#   adb shell "sh /data/local/tmp/capture-persist-props.sh" > persist-props.txt
#   adb shell "mkdir -p /data/.stowaway/sailfish/etc/hybridos"
#   adb push persist-props.txt /data/.stowaway/sailfish/etc/hybridos/persist-props.txt

PROP_DIR=/data/property
OUT=/data/local/tmp/persist-props.txt

if [ ! -d "$PROP_DIR" ]; then
    echo "ERROR: $PROP_DIR not found" >&2
    exit 1
fi

: > "$OUT"
find "$PROP_DIR" -maxdepth 1 -type f | while read -r f; do
    key=$(basename "$f")
    # skip filenames with characters unsafe for the Sailfish tmpfs path
    case "$key" in
        *[/]*) continue ;;
        *'"'*) continue ;;
    esac
    value=$(cat "$f")
    printf '%s=%s\n' "$key" "$value" >> "$OUT"
done

cat "$OUT"
