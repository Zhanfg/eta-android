#!/system/bin/sh
MODDIR=${0%/*}
OUTDIR=/sdcard/AICoreBridge
mkdir -p "$OUTDIR"

pkg_is_system() {
  PKG="$1"
  if dumpsys package "$PKG" 2>/dev/null | grep -m1 -E 'pkgFlags=.*SYSTEM|flags=.*SYSTEM' >/dev/null 2>&1; then
    return 0
  fi
  pm path "$PKG" 2>/dev/null | grep -Eq '^package:/(system|product|system_ext|vendor|odm|my_[^/]+|apex)/'
}

adopt_if_user() {
  PKG="$1"
  DEST="$2"
  LABEL="$3"
  if pkg_is_system "$PKG"; then
    echo "[KEEP] $LABEL is already a system package"
    return 0
  fi
  if ! pm path "$PKG" >/dev/null 2>&1; then
    echo "[MISS] $LABEL ($PKG) is not installed"
    return 1
  fi

  mkdir -p "$DEST"
  rm -f "$DEST"/*.apk
  pm path "$PKG" 2>/dev/null | while IFS= read -r LINE; do
    SRC=$(echo "$LINE" | sed 's/^package://')
    [ -f "$SRC" ] || continue
    cp -af "$SRC" "$DEST/$(basename "$SRC")"
  done
  if ls "$DEST"/*.apk >/dev/null 2>&1; then
    chmod 0755 "$DEST"
    chmod 0644 "$DEST"/*.apk
    echo "[ADOPT] promoted $LABEL to product priv-app; reboot required"
    return 0
  fi
  rmdir "$DEST" 2>/dev/null || true
  return 1
}

PROOT="$MODDIR/system/product"
echo "AICore Bridge 0.2 action"
echo "------------------------"
adopt_if_user com.google.android.aicore "$PROOT/priv-app/AICore" AICore || true
adopt_if_user com.google.android.as.oss "$PROOT/priv-app/PrivateComputeServices" "Private Compute Services" || true
echo "[INFO] Android System Intelligence is probe-only and is never auto-adopted."

STAMP=$(date +%Y%m%d-%H%M%S)
REPORT="$OUTDIR/report-$STAMP.txt"

{
  echo "AICore Bridge 0.2 diagnostic report"
  echo "date=$(date)"
  echo
  echo "[BUILD / HARDWARE]"
  getprop | grep -Ei 'ro.product|ro.build.fingerprint|ro.soc|ro.hardware|ro.boot.hardware|ro.vendor|oplus|oneplus' || true
  echo
  echo "[BOOT / VERIFIED BOOT]"
  echo "verifiedbootstate=$(getprop ro.boot.verifiedbootstate)"
  echo "vbmeta_device_state=$(getprop ro.boot.vbmeta.device_state)"
  echo "flash_locked=$(getprop ro.boot.flash.locked)"
  echo
  echo "[PARTITIONS / OEM GOOGLE LAYOUT]"
  mount 2>/dev/null | grep -E ' /(|system|product|system_ext|vendor|odm|my_[^ ]+) ' || true
  for D in /product /system/product /system_ext /my_bigball /my_stock /my_heytap /my_region; do
    if [ -e "$D" ]; then
      echo "--- $D ---"
      ls -ldZ "$D" 2>/dev/null || true
      find "$D" -maxdepth 4 \( -iname '*AICore*' -o -iname '*PrivateCompute*' -o -iname '*AndroidSystemIntelligence*' -o -iname '*GmsConfigOverlayASI*' \) 2>/dev/null | head -n 120
    fi
  done
  echo
  echo "[FEATURES]"
  pm list features 2>/dev/null | grep -Ei 'AICORE|NPU|ASI|ON_DEVICE' || true
  echo
  echo "[PACKAGE CLASSIFICATION]"
  for PKG in com.google.android.aicore com.google.android.as.oss com.google.android.as com.google.android.inputmethod.latin com.google.android.gms com.android.vending; do
    echo "===== $PKG ====="
    if pm path "$PKG" >/dev/null 2>&1; then
      if pkg_is_system "$PKG"; then echo "class=SYSTEM"; else echo "class=USER/DATA"; fi
      pm path "$PKG" 2>&1 || true
      dumpsys package "$PKG" 2>/dev/null | grep -E 'versionName=|versionCode=|codePath=|resourcePath=|pkgFlags=|privateFlags=|signatures=|Signing|grantedPermissions:|MANAGE_VIRTUAL_MACHINE|PROVIDE_PRIVATE_COMPUTE_SERVICES|USE_ON_DEVICE_INTELLIGENCE|WRITE_SECURE_SETTINGS|READ_DEVICE_CONFIG|ACCESS_NPU_MODEL_MANAGER_API|BIND_SERVICE' | head -n 160 || true
    else
      echo "class=ABSENT"
    fi
  done
  echo
  echo "[AICORE VARIANT CHECK]"
  AIVER=$(dumpsys package com.google.android.aicore 2>/dev/null | sed -n 's/.*versionName=//p' | head -n 1)
  echo "versionName=$AIVER"
  case "$AIVER" in
    *samsungslsi*|*qc8650*|*qc8635*) echo "variant_status=WRONG_FOR_ONEPLUS13_SM8750" ;;
    *qc8750*) echo "variant_status=EXACT_SM8750_FAMILY" ;;
    *qc.prod_aicore*) echo "variant_status=ONEPLUS_OOS_COMMUNITY_MATCH" ;;
    "") echo "variant_status=NO_AICORE" ;;
    *) echo "variant_status=UNKNOWN_VERIFY_MANUALLY" ;;
  esac
  echo
  echo "[OVERLAYS]"
  cmd overlay list 2>/dev/null | grep -Ei 'GmsConfig|ASI|AICore|PrivateCompute|Google' | head -n 250 || true
  echo
  echo "[STATIC CONFIG REFERENCES]"
  for D in /product/etc /system/product/etc /system_ext/etc /system/etc /vendor/etc /odm/etc /my_bigball/etc /my_stock/etc /my_heytap/etc /my_region/etc; do
    [ -d "$D" ] || continue
    echo "--- scan $D ---"
    grep -R -I -n -E 'AICORE_QC|android.hardware.npu|com.google.android.aicore|com.google.android.as.oss|GmsConfigOverlayASI' "$D" 2>/dev/null | head -n 160 || true
  done
  echo
  echo "[SERVICES / BINDERS]"
  service list 2>/dev/null | grep -Ei 'aicore|on.device|intelligence|private.compute|virtualization' || true
  dumpsys activity services com.google.android.aicore 2>/dev/null | head -n 260 || true
  echo
  echo "[AICORE / PCS DATA SIZE]"
  du -sh /data/user/0/com.google.android.aicore /data/user_de/0/com.google.android.aicore /data/user/0/com.google.android.as.oss /data/user_de/0/com.google.android.as.oss 2>/dev/null || true
  echo
  echo "[PKVM / VM]"
  ls -lZ /dev/kvm /dev/vfio 2>/dev/null || true
  getprop | grep -Ei 'virtualization|hypervisor|pkvm' || true
  echo
  echo "[QUALCOMM QNN / HTP / NPU]"
  find /vendor /odm /system_ext -maxdepth 6 -type f 2>/dev/null | grep -Ei '/[^/]*(qnn|htp|npu|aiboost|llm)[^/]*\.(so|bin|elf)$' | head -n 350 || true
  echo
  echo "[SELINUX]"
  getenforce 2>/dev/null || true
  for PKG in com.google.android.aicore com.google.android.as.oss com.google.android.as; do
    pm path "$PKG" 2>/dev/null | while IFS= read -r LINE; do
      P=$(echo "$LINE" | sed 's/^package://')
      ls -lZ "$P" 2>/dev/null || true
    done
  done
  dmesg 2>/dev/null | grep -Ei 'avc:.*(aicore|google.android.as|npu|qnn|htp|virt|vm)' | tail -n 250 || true
  logcat -b all -d -t 5000 2>/dev/null | grep -Ei 'avc:.*(aicore|google.android.as|npu|qnn|htp|virt|vm)' | tail -n 250 || true
  echo
  echo "[RECENT AICORE / MODEL LOGS]"
  logcat -b all -d -t 5000 2>/dev/null | grep -Ei 'aicore|gemini.?nano|ondeviceintelligence|private.?compute|model.?download|feature_not_found|binding_failure|606|601' | tail -n 700 || true
} > "$REPORT"

chmod 0644 "$REPORT" 2>/dev/null || true
echo
echo "Diagnostic report: $REPORT"
echo "If AICore/PCS was newly adopted, reboot before testing Gboard AICore backend."
