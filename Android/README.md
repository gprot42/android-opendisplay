# OpenDisplay for Android (tablet receiver)

Experimental **receiver** that turns an Android tablet into a second monitor
for a Mac running [OpenDisplay](https://github.com/peetzweg/opendisplay).

Speaks the same wire protocol as the iOS app (`../WIRE.md`). **WiFi only**
for now (Apple `usbmuxd` USB does not apply to Android).

## Status

| Feature | Status |
|---|---|
| TCP listen `:9000` + hello | ✅ |
| H.264 Annex B → MediaCodec | ✅ (early) |
| Touch + two-finger scroll | ✅ |
| mDNS (`_opensidecar._tcp`) | ✅ |
| USB | ❌ (use `adb reverse` as power-user path) |
| Cursor overlay / stats | ❌ later |

## Build

Requirements: JDK 17+, Android SDK (API 35), network for Gradle deps.

```sh
cd Android
./gradlew :app:assembleDebug
# APK: app/build/outputs/apk/debug/app-debug.apk
```

If the Gradle wrapper is missing, install once:

```sh
gradle wrapper --gradle-version 8.11.1
```

Install on a device/emulator:

```sh
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

## Connect from Mac

1. Open this app on the tablet (same Wi‑Fi as the Mac).
2. Note the **IP:9000** shown on the idle screen (or pick the device from
   the Mac WiFi list if Bonjour/NSD works).
3. On the Mac, open **OpenDisplay** → connect via WiFi discovery, or manual
   host/port.

### USB power-user path

```sh
adb reverse tcp:9000 tcp:9000
# Mac manual connect → 127.0.0.1 : 9000
```

## Permissions

- Internet / network state (TCP + NSD)
- Multicast (mDNS)

No camera, mic, or storage access.

## Layout

```
app/src/main/java/app/opendisplay/receiver/
  MainActivity.kt          UI + lifecycle
  net/ReceiverServer.kt    TCP session
  net/FrameCodec.kt        length-prefix framing
  net/NsdAdvertiser.kt     Bonjour twin
  video/H264Decoder.kt     MediaCodec
  video/AnnexBParser.kt
  input/TouchMapper.kt
  protocol/WireProtocol.kt mirrors Shared/Protocol.swift
```
