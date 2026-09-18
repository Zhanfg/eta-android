#!/system/bin/sh

ui_print " "
ui_print "========================================"
ui_print " AICore Bridge - OnePlus 13 CN 0.2-dev "
ui_print "========================================"

MODEL=$(getprop ro.product.model)
DEVICE=$(getprop ro.product.device)
PRODUCT=$(getprop ro.product.name)
SOC=$(getprop ro.soc.model)
SDK=$(getprop ro.build.version.sdk)

ui_print "- model:   $MODEL"
ui_print "- device:  $DEVICE"
ui_print "- product: $PRODUCT"
ui_print "- SoC:     $SOC"
ui_print "- API:     $SDK"

if [ "$SDK" -lt 34 ]; then
  abort "! Android 14+ is required by current AICore releases."
fi

case "$ARCH" in
  arm64) ;;
  *) abort "! This module only supports arm64 devices." ;;
esac

case "$MODEL $DEVICE $PRODUCT" in
  *PJZ110*|*CPH2653*|*CPH2649*|*CPH2655*|*dodge*)
    ui_print "- OnePlus 13 family detected."
    ;;
  *)
    ui_print "! Device is not identified as OnePlus 13."
    ui_print "! Probe/install will continue conservatively."
    ;;
esac

case "$SOC" in
  *8750*|*SM8750*|*sm8750*)
    ui_print "- SM8750 detected: qc8750 / OnePlus OOS Qualcomm AICore is preferred."
    ;;
  *)
    ui_print "! SoC string does not explicitly report SM8750: $SOC"
    ;;
esac

if [ "$KSU" = "true" ] && [ ! -e /data/adb/metamodule ]; then
  ui_print "! KernelSU/ReSukiSU requires a metamodule for product/system overlays."
  ui_print "! Install meta-overlayfs (or compatible metamodule) before rebooting."
fi

PROOT="$MODPATH/system/product"
AICORE_DIR="$PROOT/priv-app/AICore"
PCS_DIR="$PROOT/priv-app/PrivateComputeServices"
mkdir -p "$AICORE_DIR" "$PCS_DIR" "$MODPATH/state"

# Capture the untouched ColorOS state before the next boot applies this module.
BASELINE="$MODPATH/state/preinstall-coloros.txt"
{
  echo "AICore Bridge preinstall ColorOS snapshot"
  echo "date=$(date)"
  echo "model=$MODEL"
  echo "device=$DEVICE"
  echo "product=$PRODUCT"
  echo "soc=$SOC"
  echo "sdk=$SDK"
  echo
  echo "[FEATURES BEFORE MODULE]"
  pm list features 2>/dev/null | grep -Ei "AICORE|NPU|ASI|ON_DEVICE" || true
  echo
  echo "[PACKAGES BEFORE MODULE]"
  for PKG in com.google.android.aicore com.google.android.as.oss com.google.android.as com.google.android.inputmethod.latin com.google.android.gms; do
    echo "--- $PKG ---"
    pm path "$PKG" 2>&1 || true
    dumpsys package "$PKG" 2>/dev/null | grep -E "versionName=|versionCode=|codePath=|pkgFlags=|privateFlags=" | head -n 30 || true
  done
  echo
  echo "[OVERLAYS BEFORE MODULE]"
  cmd overlay list 2>/dev/null | grep -Ei "GmsConfig|ASI|AICore|PrivateCompute|Google" | head -n 200 || true
  echo
  echo "[OEM GOOGLE PARTITIONS BEFORE MODULE]"
  for D in /my_bigball /my_stock /my_heytap /my_region /product /system_ext; do
    [ -e "$D" ] || continue
    echo "--- $D ---"
    find "$D" -maxdepth 4 \( -iname "*AICore*" -o -iname "*PrivateCompute*" -o -iname "*AndroidSystemIntelligence*" -o -iname "*GmsConfigOverlayASI*" \) 2>/dev/null | head -n 100
  done
} > "$BASELINE"
ui_print "- saved pre-module ColorOS baseline."

pkg_is_system() {
  PKG="$1"
  if dumpsys package "$PKG" 2>/dev/null | grep -m1 -E 'pkgFlags=.*SYSTEM|flags=.*SYSTEM' >/dev/null 2>&1; then
    return 0
  fi
  if pm path "$PKG" 2>/dev/null | grep -Eq '^package:/(system|product|system_ext|vendor|odm|my_[^/]+|apex)/'; then
    return 0
  fi
  return 1
}

pkg_exists() {
  pm path "$1" >/dev/null 2>&1
}

copy_installed_pkg() {
  PKG="$1"
  DEST="$2"
  LABEL="$3"
  mkdir -p "$DEST"
  rm -f "$DEST"/*.apk

  pm path "$PKG" 2>/dev/null | while IFS= read -r LINE; do
    SRC=$(echo "$LINE" | sed 's/^package://')
    [ -f "$SRC" ] || continue
    cp -af "$SRC" "$DEST/$(basename "$SRC")"
  done

  if ls "$DEST"/*.apk >/dev/null 2>&1; then
    ui_print "- promoted installed $LABEL to product priv-app."
    return 0
  fi
  rmdir "$DEST" 2>/dev/null || true
  return 1
}

import_bundle() {
  SRC="$1"
  DEST="$2"
  LABEL="$3"
  [ -f "$SRC" ] || return 1
  mkdir -p "$DEST"
  rm -f "$DEST"/*.apk
  ui_print "- importing $LABEL bundle: $(basename "$SRC")"
  unzip -oj "$SRC" '*.apk' -d "$DEST" >/dev/null 2>&1
  if ls "$DEST"/*.apk >/dev/null 2>&1; then
    return 0
  fi
  ui_print "! No APK splits found in $SRC"
  rmdir "$DEST" 2>/dev/null || true
  return 1
}

find_bundle() {
  BASE="$1"
  for EXT in apks apkm zip; do
    P="/sdcard/AICoreBridge/$BASE.$EXT"
    [ -f "$P" ] && { echo "$P"; return 0; }
  done
  return 1
}

IMPORT_DIR=/sdcard/AICoreBridge
mkdir -p "$IMPORT_DIR" 2>/dev/null

# AICore: preserve a system/OOS copy if one already exists. Otherwise import the
# official OOS/Google bundle supplied by the user, or promote an installed copy.
if pkg_is_system com.google.android.aicore; then
  ui_print "- AICore already exists as a system package; leaving it untouched."
  rmdir "$AICORE_DIR" 2>/dev/null || true
else
  BUNDLE=$(find_bundle aicore 2>/dev/null)
  if [ -n "$BUNDLE" ] && import_bundle "$BUNDLE" "$AICORE_DIR" AICore; then
    :
  elif pkg_exists com.google.android.aicore; then
    copy_installed_pkg com.google.android.aicore "$AICORE_DIR" AICore || true
  else
    rmdir "$AICORE_DIR" 2>/dev/null || true
    ui_print "! AICore not found."
    ui_print "! Use the OnePlus OOS16-extracted production QC bundle or a Google production qc/qc8750 build."
  fi
fi

# PCS: many OPlus global/GMS builds already ship it (sometimes outside /product,
# e.g. an OEM Google partition). Never shadow an existing system PCS package.
if pkg_is_system com.google.android.as.oss; then
  ui_print "- Private Compute Services already exists as a system package; reusing it."
  rmdir "$PCS_DIR" 2>/dev/null || true
else
  PCS_BUNDLE=$(find_bundle pcs 2>/dev/null)
  if [ -n "$PCS_BUNDLE" ] && import_bundle "$PCS_BUNDLE" "$PCS_DIR" "Private Compute Services"; then
    :
  elif pkg_exists com.google.android.as.oss; then
    copy_installed_pkg com.google.android.as.oss "$PCS_DIR" "Private Compute Services" || true
  else
    rmdir "$PCS_DIR" 2>/dev/null || true
    ui_print "! PCS is not present. Model delivery may fail until an Android-16 PCS build is installed."
  fi
fi

# Android System Intelligence is not required for Gboard->PCS/AICore access and
# is intentionally not injected by the core bridge.
if pkg_exists com.google.android.as; then
  ui_print "- Android System Intelligence detected; leaving it untouched."
else
  ui_print "- Android System Intelligence not detected (optional for this Gboard-focused bridge)."
fi

set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm "$MODPATH/customize.sh" 0 0 0755
set_perm "$MODPATH/service.sh" 0 0 0755
set_perm "$MODPATH/action.sh" 0 0 0755

ui_print " "
ui_print "- Probe-first integration staged."
ui_print "- No fingerprint/Pixel spoofing and no bootloader/integrity bypass is performed."
ui_print "- Reboot, then run the module Action and send the generated report for analysis."
