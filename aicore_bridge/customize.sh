#!/system/bin/sh

ui_print " "
ui_print "========================================"
ui_print " AICore Bridge - OnePlus 13 CN 0.1-dev "
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
  *) abort "! This prototype only supports arm64 devices." ;;
esac

case "$MODEL $DEVICE $PRODUCT" in
  *PJZ110*|*CPH2653*|*CPH2649*|*CPH2655*|*dodge*)
    ui_print "- OnePlus 13 family detected."
    ;;
  *)
    ui_print "! Device is not identified as OnePlus 13."
    ui_print "! Integration files will be installed, but hardware compatibility is not assumed."
    ;;
esac

if [ "$KSU" = "true" ] && [ ! -e /data/adb/metamodule ]; then
  ui_print "! KernelSU/ReSukiSU system overlays require a metamodule."
  ui_print "! Install meta-overlayfs (or an equivalent metamodule) before rebooting."
fi

mkdir -p "$MODPATH/system/priv-app/AICore"
mkdir -p "$MODPATH/system/priv-app/PrivateComputeServices"
mkdir -p "$MODPATH/system/priv-app/AndroidSystemIntelligence"
mkdir -p "$MODPATH/state"

copy_installed_pkg() {
  PKG="$1"
  DEST="$2"

  pm path "$PKG" 2>/dev/null | while IFS= read -r LINE; do
    SRC=$(echo "$LINE" | sed 's/^package://')
    [ -f "$SRC" ] || continue
    NAME=$(basename "$SRC")
    cp -af "$SRC" "$MODPATH/system/priv-app/$DEST/$NAME"
  done

  if ls "$MODPATH/system/priv-app/$DEST/"*.apk >/dev/null 2>&1; then
    ui_print "- adopted installed package: $PKG"
    return 0
  fi
  return 1
}

import_bundle() {
  SRC="$1"
  DEST="$2"
  LABEL="$3"
  [ -f "$SRC" ] || return 1
  ui_print "- importing $LABEL bundle: $SRC"
  rm -f "$MODPATH/system/priv-app/$DEST/"*.apk
  unzip -oj "$SRC" '*.apk' -d "$MODPATH/system/priv-app/$DEST" >/dev/null 2>&1
  if ls "$MODPATH/system/priv-app/$DEST/"*.apk >/dev/null 2>&1; then
    return 0
  fi
  ui_print "! No APK files found inside $SRC"
  return 1
}

IMPORT_DIR=/sdcard/AICoreBridge
mkdir -p "$IMPORT_DIR" 2>/dev/null

if ! import_bundle "$IMPORT_DIR/aicore.apkm" AICore AICore; then
  copy_installed_pkg com.google.android.aicore AICore || true
fi

if ! import_bundle "$IMPORT_DIR/pcs.apkm" PrivateComputeServices "Private Compute Services"; then
  copy_installed_pkg com.google.android.as.oss PrivateComputeServices || true
fi

if ! import_bundle "$IMPORT_DIR/asi.apkm" AndroidSystemIntelligence "Android System Intelligence"; then
  copy_installed_pkg com.google.android.as AndroidSystemIntelligence || true
fi

for D in AICore PrivateComputeServices AndroidSystemIntelligence; do
  if ! ls "$MODPATH/system/priv-app/$D/"*.apk >/dev/null 2>&1; then
    rmdir "$MODPATH/system/priv-app/$D" 2>/dev/null || true
  fi
done

set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm "$MODPATH/customize.sh" 0 0 0755
set_perm "$MODPATH/service.sh" 0 0 0755
set_perm "$MODPATH/action.sh" 0 0 0755

ui_print " "
ui_print "- Integration layer installed."
if [ ! -d "$MODPATH/system/priv-app/AICore" ]; then
  ui_print "! AICore itself was not staged."
  ui_print "! Reboot once, install the official Qualcomm AICore bundle, then run the module Action to adopt it."
fi
if [ ! -d "$MODPATH/system/priv-app/PrivateComputeServices" ]; then
  ui_print "! Private Compute Services was not staged."
  ui_print "! AICore model downloads may not work until PCS is present."
fi
ui_print "- Reboot is required after package adoption."
