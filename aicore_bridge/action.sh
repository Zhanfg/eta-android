#!/system/bin/sh
MODDIR=${0%/*}
OUTDIR=/sdcard/AICoreBridge
mkdir -p "$OUTDIR"

adopt_pkg() {
  PKG="$1"
  DEST="$2"
  mkdir -p "$MODDIR/system/priv-app/$DEST"
  rm -f "$MODDIR/system/priv-app/$DEST/"*.apk

  pm path "$PKG" 2>/dev/null | while IFS= read -r LINE; do
    SRC=$(echo "$LINE" | sed 's/^package://')
    [ -f "$SRC" ] || continue
    cp -af "$SRC" "$MODDIR/system/priv-app/$DEST/$(basename "$SRC")"
  done

  if ls "$MODDIR/system/priv-app/$DEST/"*.apk >/dev/null 2>&1; then
    chmod 0755 "$MODDIR/system/priv-app/$DEST"
    chmod 0644 "$MODDIR/system/priv-app/$DEST/"*.apk
    echo "[OK] adopted $PKG"
  else
    rmdir "$MODDIR/system/priv-app/$DEST" 2>/dev/null || true
    echo "[MISS] $PKG is not currently installed"
  fi
}

echo "AICore Bridge action"
echo "--------------------"
adopt_pkg com.google.android.aicore AICore
adopt_pkg com.google.android.as.oss PrivateComputeServices
adopt_pkg com.google.android.as AndroidSystemIntelligence

STAMP=$(date +%Y%m%d-%H%M%S)
REPORT="$OUTDIR/report-$STAMP.txt"

{
  echo "AICore Bridge diagnostic report"
  echo "date=$(date)"
  echo
  echo "[BUILD]"
  getprop | grep -Ei 'ro.product|ro.build.fingerprint|ro.soc|hardware|npu' || true
  echo
  echo "[BOOT / INTEGRITY HINTS]"
  getprop ro.boot.verifiedbootstate || true
  getprop ro.boot.vbmeta.device_state || true
  getprop ro.boot.flash.locked || true
  echo
  echo "[FEATURES]"
  pm list features | grep -Ei 'AICORE|NPU|ASI|ON_DEVICE' || true
  echo
  echo "[PACKAGES]"
  for PKG in com.google.android.aicore com.google.android.as.oss com.google.android.as com.google.android.gms com.android.vending; do
    echo "--- $PKG ---"
    pm path "$PKG" 2>&1 || true
    dumpsys package "$PKG" 2>/dev/null | grep -E 'versionName=|versionCode=|codePath=|pkgFlags=|privateFlags=|granted=true|MANAGE_VIRTUAL_MACHINE|USE_ON_DEVICE_INTELLIGENCE|WRITE_SECURE_SETTINGS|READ_DEVICE_CONFIG|ACCESS_NPU' || true
  done
  echo
  echo "[SERVICES]"
  service list | grep -Ei 'aicore|on.device|intelligence|private.compute' || true
  echo
  echo "[QUALCOMM / NPU FILES]"
  find /vendor /odm /system_ext -maxdepth 4 -type f 2>/dev/null | grep -Ei '/(lib|bin).*(qnn|htp|npu|aicore)' | head -n 200 || true
  echo
  echo "[RECENT LOGS]"
  logcat -d -t 1200 2>/dev/null | grep -Ei 'aicore|gemini.?nano|ondeviceintelligence|private.?compute|com.google.android.as.oss' | tail -n 300 || true
} > "$REPORT"

chmod 0644 "$REPORT" 2>/dev/null || true
echo
echo "Diagnostic report: $REPORT"
echo "If any package was newly adopted, reboot before testing AICore."
