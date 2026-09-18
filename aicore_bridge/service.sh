#!/system/bin/sh
MODDIR=${0%/*}
LOG=/data/adb/aicore-bridge.log

exec >>"$LOG" 2>&1
echo "===== AICore Bridge service $(date) ====="

i=0
while [ "$(getprop sys.boot_completed)" != "1" ] && [ "$i" -lt 120 ]; do
  sleep 2
  i=$((i + 1))
done

for PKG in com.google.android.aicore com.google.android.as.oss com.google.android.as; do
  pm enable "$PKG" >/dev/null 2>&1 || true
done

pm grant com.google.android.aicore android.permission.MANAGE_VIRTUAL_MACHINE 2>/dev/null || true
pm grant com.google.android.as.oss android.permission.MANAGE_VIRTUAL_MACHINE 2>/dev/null || true
appops set com.google.android.aicore GET_USAGE_STATS allow 2>/dev/null || true

echo "-- package paths --"
pm path com.google.android.aicore 2>&1 || true
pm path com.google.android.as.oss 2>&1 || true
pm path com.google.android.as 2>&1 || true

echo "-- features --"
pm list features 2>/dev/null | grep -Ei 'AICORE|NPU|ASI|ON_DEVICE' || true

echo "-- services --"
service list 2>/dev/null | grep -Ei 'aicore|on.device|intelligence|private.compute' || true
