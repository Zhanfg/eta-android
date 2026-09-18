#!/system/bin/sh
MODDIR=${0%/*}
LOG=/data/adb/aicore-bridge.log

exec >>"$LOG" 2>&1
echo "===== AICore Bridge 0.2 service $(date) ====="

i=0
while [ "$(getprop sys.boot_completed)" != "1" ] && [ "$i" -lt 120 ]; do
  sleep 2
  i=$((i + 1))
done

for PKG in com.google.android.aicore com.google.android.as.oss; do
  if pm path "$PKG" >/dev/null 2>&1; then
    pm enable "$PKG" >/dev/null 2>&1 || true
  fi
done

# PACKAGE_USAGE_STATS is AppOps-backed. This is the only runtime adjustment;
# signature/privileged permissions must come from product priv-app allowlisting.
if pm path com.google.android.aicore >/dev/null 2>&1; then
  appops set com.google.android.aicore GET_USAGE_STATS allow 2>/dev/null || true
fi

echo "-- package paths --"
pm path com.google.android.aicore 2>&1 || true
pm path com.google.android.as.oss 2>&1 || true
pm path com.google.android.as 2>&1 || true

echo "-- versions --"
dumpsys package com.google.android.aicore 2>/dev/null | grep -m1 'versionName=' || true
dumpsys package com.google.android.as.oss 2>/dev/null | grep -m1 'versionName=' || true

echo "-- features --"
pm list features 2>/dev/null | grep -Ei 'AICORE|NPU|ASI|ON_DEVICE' || true

echo "-- privileged grants --"
dumpsys package com.google.android.aicore 2>/dev/null | grep -E 'ACCESS_NPU_MODEL_MANAGER_API|MANAGE_VIRTUAL_MACHINE|USE_ON_DEVICE_INTELLIGENCE|READ_DEVICE_CONFIG|WRITE_SECURE_SETTINGS' || true

echo "-- services --"
service list 2>/dev/null | grep -Ei 'aicore|on.device|intelligence|private.compute|virtualization' || true
