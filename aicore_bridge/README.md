# AICore Bridge - OnePlus 13 CN

Probe-first systemless integration bridge for testing the official Google Android AICore stack on the China-market OnePlus 13 (PJZ110 / ColorOS 16) without replacing ColorOS with OxygenOS.

## Evidence status

### What is directly supported by evidence

- OnePlus 13 global/OxygenOS builds ship Google AICore/Gemini Nano support.
- A public ColorOS/OnePlus system-app community distributes an **AICore (OnePlus), Global, extracted from OxygenOS 16 OTA** bundle and explicitly labels that build as **targeted to COS 16**.
- Google's production Qualcomm AICore package requires `android.hardware.npu` and `com.google.android.feature.AICORE_QC`.
- Google's current open-source Private Compute Services manifest explicitly allows both `com.google.android.aicore` and `com.google.android.inputmethod.latin` (Gboard) to access PCS.
- Public OnePlus 13 / SM8750 vendor lists contain QNN/HTP/aiboost inference libraries, so the hardware/vendor inference backend exists on this device family.

### What is NOT yet proven

There is not yet a public, reproducible report that closes the entire loop **PJZ110 ColorOS 16 -> side-loaded OOS AICore -> Gemini Nano model downloaded -> Gboard AICore Writing Tools successfully return suggestions**. This module is designed to produce the missing evidence rather than assume success.

## 0.2 design changes

- Uses the `/product` privileged-app/config layer instead of generic `/system/priv-app`.
- Saves a pre-reboot ColorOS baseline during installation.
- Reuses an existing system Private Compute Services package, including OEM locations such as OPlus Google partitions, instead of shadowing it.
- Reuses an existing system AICore package if present.
- Does **not** auto-install Android System Intelligence; Gboard has a direct PCS/AICore access path.
- Removes the incomplete ASI association allowlist from 0.1. Android allow-association targets are restrictive and a partial list can break unrelated ASI bindings.
- Performs no Pixel fingerprint spoofing, Play Integrity spoofing, or bootloader-state bypass.

## Package / variant selection

For PJZ110 / OnePlus 13 / SM8750:

1. **Best evidence match:** production Qualcomm AICore extracted from a OnePlus OxygenOS 16 OTA. The community example is `0.release.qc.prod_aicore_20260430.00_RC04.915164305`.
2. **Hardware-family candidate:** a Google production `qc8750` AICore build.
3. Avoid Samsung SLSI, `qc8650`, `qc8635`, Pixel-only, and third-party-experimental variants for the first controlled test.

The Google production signing certificate SHA-256 for the community-matched QC build is:

`b7971ccc10a03932e14a3557a1b4c2a84be0ecb506777f0c72dd46cf5d7093c6`

## Install flow

### Preferred controlled test

1. Make sure ReSukiSU/KernelSU has a system-mount metamodule such as `meta-overlayfs`.
2. Place the official Google-signed OnePlus/OOS Qualcomm AICore bundle at either:
   - `/sdcard/AICoreBridge/aicore.apks`
   - `/sdcard/AICoreBridge/aicore.apkm`
3. Do **not** provide PCS unless ColorOS really lacks `com.google.android.as.oss`; 0.2 first reuses any existing system PCS package.
4. Flash AICore Bridge 0.2.
5. The installer saves the untouched ColorOS package/feature/overlay state before the module is mounted.
6. Reboot.
7. Run the module **Action**.
8. Send `AICoreBridge/report-*.txt` for comparison.
9. Only after AICore is healthy should Gboard Enhancer be switched to the `AICore` backend.

### If AICore was already installed as a normal user package

Flash the module and run its Action. The Action can copy the existing Google-signed split APKs into the module's `/product/priv-app/AICore` overlay. Reboot once more after adoption.

### PCS fallback

If `com.google.android.as.oss` is absent, place an Android-16 arm64 PCS bundle as:

- `/sdcard/AICoreBridge/pcs.apks`, or
- `/sdcard/AICoreBridge/pcs.apkm`

0.2 will only stage it when no system PCS package is detected.

## Diagnostic report

The Action writes `/sdcard/AICoreBridge/report-YYYYMMDD-HHMMSS.txt` containing:

- untouched pre-install ColorOS baseline
- post-bridge feature declarations
- package system/user classification and code paths
- AICore version/variant classification
- GMS/ASI/AICore overlays
- OPlus `my_bigball`, `my_stock`, `my_heytap`, `my_region` package/config locations when present
- privileged permission state
- Binder/service state
- AICore/PCS data sizes
- pKVM/virtualization hints
- Qualcomm QNN/HTP/NPU/aiboost libraries
- SELinux labels and targeted AVC denials
- recent AICore, Gemini Nano, model download, `601 BINDING_FAILURE`, and `606 FEATURE_NOT_FOUND` logs

## Rollback

Disable or remove the module and reboot. The ColorOS partitions are not physically modified.
