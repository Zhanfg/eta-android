# Gboard Enhancer 0.2-dev

Flutter Material 3 configuration UI + Kotlin LSPosed core.

## Runtime change

Gboard's hot flag getter no longer performs periodic provider IPC. Configuration is loaded once at Application.attach and refreshed only after a CONFIG_CHANGED broadcast.

## Writing Tools backend modes

- GBOARD_SERVER => backend_type=1, hybrid=false, on-device proofread=false
- AICORE => backend_type=2, hybrid=true, on-device proofread=true
- ASTREA => backend_type=3, hybrid=true, on-device proofread=false

The UI also includes Google / Google APIs / Gboard model endpoint connectivity tests and native visibility checks for Gboard, Google Play services, and Android AICore.
