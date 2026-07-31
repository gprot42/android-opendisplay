# OpenDisplay for Android

Use an Android phone or tablet as a **second monitor** for a Mac running
[OpenDisplay](https://github.com/peetzweg/opendisplay).

Wi‑Fi only (same wire protocol as iOS — see [`WIRE.md`](../WIRE.md)).

## What works

| Feature | Status |
|---|---|
| TCP listen on port **9000** + `hello` | Works |
| H.264 hardware decode (MediaCodec) | Works |
| Touch click / drag + two-finger scroll | Works |
| Pinch-to-zoom + one-finger pan when zoomed + double-tap reset | Works |
| Mac cursor overlay (local cursor echo) | Works |
| mDNS discovery (`_opensidecar._tcp`) | Works when the LAN allows multicast |
| Manual IP connect (fallback) | Works |
| USB (Apple usbmuxd) | Not supported — use Wi‑Fi or `adb reverse` |

## Supported Android versions

| | |
|---|---|
| **Minimum** | **Android 8.0** (API **26**) |
| **Target** | Android 15 (API 35) |
| **Recommended** | Android **11+** (API 30+) for official low-latency decode |

### Why API 26?

- Covers almost all tablets still in use.
- Hardware H.264 (`MediaCodec`) and mDNS (`NsdManager`) are solid from API 26.
- Jetpack Compose + AndroidX backports UI/window APIs so we don’t need a higher minSdk for chrome.

### Version notes

| Android | API | Decode latency | Discovery | Notes |
|---|---|---|---|---|
| 8–9 | 26–28 | Vendor low-latency keys only | NSD | Expect higher latency; use Mac quality **Fast** on Wi‑Fi |
| 10 | 29 | Vendor keys | NSD | Same as above |
| **11+** | **30+** | `KEY_LOW_LATENCY` + vendors | NSD | Best path |
| 12+ | 31+ | Same | NSD | Some OEMs isolate “guest” Wi‑Fi — use manual IP if Mac can’t see the device |
| 13+ | 33+ | Same | NSD | Declares `NEARBY_WIFI_DEVICES` (never for location) |

**Required on the device:** a hardware **H.264 / AVC** decoder (every normal phone/tablet has one). Soft decoders are not targeted.

### Verified so far

| Device | Android | Result |
|---|---|---|
| Pixel 10 Pro XL | 16 / API 36* | Stream + touch + cursor over Wi‑Fi |

\*Installs that report a higher API than `targetSdk` still run; we only require **≥ 26**.

Add your device after testing (PR welcome): model, Android version, Wi‑Fi or `adb reverse`, pass/fail.

## How we keep multi-version working

1. **minSdk 26** — compile against API 35, never call APIs below min without a version guard.
2. **Decode** — use `KEY_LOW_LATENCY` only on API 30+; apply common vendor low-latency keys; if configure fails, **retry a plain** MediaCodec config (some OEMs reject vendor keys).
3. **Network** — cleartext TCP allowed on LAN (`network_security_config`); same host:port as iOS.
4. **Discovery is optional** — idle screen always shows **IP:port** so a Mac can connect when mDNS is blocked.
5. **Startup probe** — logs Android version, ABI, and AVC decoder name (`adb logcat -s DeviceReport H264Decoder`).
6. **CI** — unit tests (framing / Annex B) + debug APK assemble on every push (see `.github/workflows/android.yml`).
7. **Manual matrix** — before a release, run the [smoke checklist](#smoke-checklist) on at least one API 26–28 emulator and one API 30+ device/emulator.

## Build & install

```sh
cd Android
./gradlew :app:assembleDebug
# Version from ../version.md → ~/OpenDisplay-0.0.1-debug.apk
adb install -r ~/OpenDisplay-*-debug.apk
```

Needs **JDK 17+** and the Android SDK.

## Connect from the Mac

1. Open this app (keep it in the foreground).
2. Same Wi‑Fi as the Mac (or use the USB tip below).
3. On the Mac: OpenDisplay → Wi‑Fi device, **or** manual host using the **IP:9000** on the idle screen.
4. Grant Mac **Screen Recording** + **Accessibility** if prompted.

### USB power-user path

```sh
adb reverse tcp:9000 tcp:9000
# Mac → manual connect 127.0.0.1 port 9000
```

## Smoke checklist

Run on each Android version you care about (device or emulator):

- [ ] App launches; idle screen shows port **9000** and a LAN IP (or `adb reverse` path).
- [ ] `adb logcat -s DeviceReport` shows **H.264 decoder: …** (not MISSING).
- [ ] Mac connects (discovery **or** manual IP).
- [ ] Extended display appears; desktop is visible (not black for >3s).
- [ ] Mouse cursor visible on the Android screen when the pointer is on that display.
- [ ] Tap = click, drag = drag, two-finger pan = scroll.
- [ ] Rotate device once; Mac rebuilds the display (may briefly reconnect).
- [ ] Leave app (home); session ends cleanly; reopen and reconnect.

### Emulators (optional)

```sh
# Examples — create AVDs in Android Studio Device Manager
emulator -avd Pixel_3a_API_26 &   # floor
emulator -avd Pixel_6_API_34 &    # modern
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

Emulator networking to a Mac on the host: use the emulator’s IP as shown in the app, or `adb reverse` from the host Mac.

## Troubleshooting

| Symptom | What to try |
|---|---|
| Mac doesn’t list the device | Use **manual IP:9000**; check same LAN / disable VPN / AP client isolation |
| Black screen | Confirm decoder in logcat; on Mac pick quality **Fast**; wait for keyframe |
| No cursor | Update to a build that includes cursor overlay; move pointer onto the virtual display |
| High latency | Prefer 5 GHz Wi‑Fi; Mac quality **Balanced** or **Fast**; Android 11+ helps |
| Connect then drop | Keep app foreground; don’t lock the screen mid-session |

## Permissions

- Internet / network state (TCP)
- Wi‑Fi multicast (mDNS)
- Nearby Wi‑Fi devices on API 33+ (discovery-related; not used for location)

No camera, mic, or storage.

## Layout

```
app/src/main/java/app/opendisplay/receiver/
  MainActivity.kt
  compat/DeviceReport.kt     # version / codec probe
  net/ReceiverServer.kt
  net/FrameCodec.kt
  net/NsdAdvertiser.kt
  video/H264Decoder.kt       # version-safe low-latency
  video/AnnexBParser.kt
  input/TouchMapper.kt
  ui/CursorOverlayView.kt
  protocol/WireProtocol.kt
```
