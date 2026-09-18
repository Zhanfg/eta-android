# AICore Bridge - OnePlus 13 CN

Systemless integration bridge for bringing the official Google Android AICore stack to the China-market OnePlus 13 (PJZ110 / dodge) without replacing ColorOS with OxygenOS.

## Design

This module intentionally reproduces the missing system-integration layer rather than globally spoofing the phone as a Pixel.

It adds:

- `com.google.android.feature.AICORE_QC`
- `android.hardware.npu`
- `com.google.android.feature.ASI`
- privileged-permission allowlists for `com.google.android.aicore`
- privileged-permission allowlists for `com.google.android.as.oss` (Private Compute Services)
- PCC / PCS package associations
- package-adoption helpers that preserve Google's original APK signatures
- boot diagnostics and an Action-generated report

## Important limitations

- The module does NOT bundle, modify, re-sign, or redistribute Google's proprietary AICore binaries.
- It does NOT globally spoof the device fingerprint/model as a Pixel.
- It does NOT modify bootloader state, vendor firmware, NPU firmware, QNN libraries, or Play Integrity.
- Google currently documents ML Kit GenAI APIs as unsupported on devices with an unlocked bootloader. A working local AICore service therefore does not guarantee Google will provision Gemini Nano features on an unlocked/rooted device.
- Server-side feature provisioning can still reject a device even when the package and Binder service are healthy.

## Package roles

- `com.google.android.aicore` - Android AICore system service / Gemini Nano runtime.
- `com.google.android.as.oss` - Private Compute Services; supplies the network/privacy gateway used for protected model delivery.
- `com.google.android.as` - Android System Intelligence; optional but recommended when reproducing the global Google system-intelligence stack.

## Install modes

### One-reboot import

Before flashing the module, place official Google-signed bundles in:

- `/sdcard/AICoreBridge/aicore.apkm`
- `/sdcard/AICoreBridge/pcs.apkm`
- optional: `/sdcard/AICoreBridge/asi.apkm`

The installer extracts only the APK splits into the systemless `system/priv-app` layer. It does not alter the APK bytes.

### Bootstrap / adopt

1. Flash AICore Bridge.
2. Reboot.
3. Install the official Qualcomm AICore bundle and Private Compute Services as normal user packages.
4. Open your root manager, select AICore Bridge, and run **Action**.
5. The Action copies the installed Google-signed package splits into the module's systemless priv-app layer and writes a diagnostic report.
6. Reboot again.

## KernelSU / ReSukiSU

This module modifies `/system`, so KernelSU-family roots need a compatible metamodule such as `meta-overlayfs`. Magisk can use its normal systemless mount mechanism.

## Diagnostics

Run the module Action after boot. Reports are written to:

`/sdcard/AICoreBridge/report-YYYYMMDD-HHMMSS.txt`

The report captures:

- model / product / SoC / fingerprint
- bootloader / verified-boot hints
- AICore / NPU feature declarations
- AICore / PCS / ASI / GMS package paths and selected privileged permissions
- Binder-service visibility
- Qualcomm QNN / HTP / NPU files
- recent AICore / Gemini Nano / Private Compute logcat lines

## Rollback

Disable or remove the module and reboot. The system files are overlaid systemlessly; the ColorOS partitions themselves are not modified.
