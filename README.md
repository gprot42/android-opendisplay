<div align="center">

<img src="public/logo.png" width="128" alt="OpenDisplay app icon" />

# OpenDisplay (Android)

**Android receiver only** — phone or tablet as a second Mac monitor over Wi‑Fi.

Mac + iPhone/iPad apps:

- **[peetzweg/opendisplay](https://github.com/peetzweg/opendisplay)**
- [Website](https://peetzweg.github.io/opendisplay/)
- [Wire protocol](WIRE.md)
- [Android details](Android/README.md)

<br />

<a href="https://ko-fi.com/peetzweg">
  <img src="https://ko-fi.com/img/githubbutton_sm.svg" alt="Buy Me a Coffee on ko-fi.com" />
</a>

</div>

---

Free, open source, no subscription — alternative to Sidecar / Duet / Luna on hardware you already own.

## Features

- True display extension (or mirror) via Mac OpenDisplay
- **Network (Wi‑Fi) by default** · **USB via tethering** (no debugging) · optional adb fallback
- Hardware H.264 decode · **system audio** · touch + two-finger scroll · pinch-to-zoom · cursor overlay
- Portrait / landscape · mDNS discovery + manual IP · stays running in background

## What works

| Feature | Status |
|---|---|
| TCP :9000 + `hello` | ✅ |
| H.264 hardware decode | ✅ |
| Touch click / drag + two-finger scroll | ✅ |
| Mac cursor overlay | ✅ |
| mDNS (`_opensidecar._tcp`) | ✅ when LAN allows multicast |
| Manual IP connect | ✅ |
| **Network mode (default)** | ✅ Wi‑Fi / LAN |
| **USB mode** | ✅ **USB tethering** (no debugging) · optional `adb` fallback |
| System audio | ✅ **Play audio on** Tablet (default) or This Mac |
| Background keep-alive | ✅ foreground service (session survives Home) |

## Android versions

| Android | API | Status | Notes |
|---|---|---|---|
| **8.0–9** | **26–28** | Supported | Higher latency; Mac quality **Fast** |
| **10** | **29** | Supported | Same as above |
| **11+** | **30+** | **Recommended** | Official low-latency decode |
| **12** | **31–32** | Supported | Guest Wi‑Fi may block mDNS → use manual IP |
| **13** | **33** | Supported | `NEARBY_WIFI_DEVICES` for discovery |
| **14** | **34** | Supported | Same as 11+ (low-latency path) |
| **15** | **35** | Supported | **targetSdk**; same as 11+ |
| **16** | **36** | Supported | Runs above targetSdk; verified on Pixel 10 Pro XL |

| | |
|---|---|
| **minSdk** | Android **8.0** (API **26**) |
| **targetSdk** | Android 15 (API 35) |
| **Required** | Hardware H.264 / AVC decoder (normal devices have one) |

| Device | Android | Result |
|---|---|---|
| Pixel 10 Pro XL | 16 / API 36 | Stream + touch + cursor (Wi‑Fi + USB via `adb forward`) |
| **Google Pixel Tablet** (10.95″, 2560×1600) | 15 / API 35 | Stream + touch + cursor (Wi‑Fi + USB via `adb forward`) |

More devices: PR welcome — model, Android version, pass/fail.

## Install & run

**Mac:** [OpenDisplay.dmg](https://github.com/peetzweg/opendisplay/releases/latest) from the main project.

Local install (build + sign + copy into `/Applications`):

```sh
./install-mac.sh --open            # Debug → /Applications/OpenDisplay Dev.app
./install-mac.sh --release --open  # Release → /Applications/OpenDisplay.app
```

**Android:**

```sh
cd Android
./gradlew :app:assembleDebug
# Version from ../version.md → ~/OpenDisplay-0.0.1-debug.apk
adb install -r ~/OpenDisplay-*-debug.apk
```

Needs JDK 17+ and the Android SDK. Details: [`Android/README.md`](Android/README.md).

1. Open the Android app.
2. **Network (default):** same Wi‑Fi → Mac OpenDisplay → pick the device (or **IP:9000**).
3. **USB (keeps Mac Wi‑Fi):** USB debugging + `adb` → app mode **USB** → Mac **Android USB**. Prefer this over tethering.

   **USB without debugging (tethering):** cable → **USB controlled by → Connected device** → enable **USB tethering** → app mode **USB** → Mac **Android USB (tether)**. Note: tethering can steal Mac internet (phone becomes default route); OpenDisplay demotes that route so Wi‑Fi stays primary. Full detail: [`Android/README.md`](Android/README.md#usb-recommended-adb--keeps-mac-internet).
4. Grant Mac **Screen Recording** + **Accessibility** if prompted.

## How it works

```
MAC (sender)                                      ANDROID (receiver)
CGVirtualDisplay
   → ScreenCaptureKit → H.264
   → TCP  [length][Annex B]  ═══════════════════→  listen :9000
                                                      → MediaCodec
   ← JSON (hello, touch, scroll) ═══════════════
```

Screen stays on your LAN — never uploaded. Full wire format: [`WIRE.md`](WIRE.md).

## FAQ

| Question | Answer |
|---|---|
| Mac doesn’t see the device? | Manual **IP:9000**; same LAN; try no VPN / client isolation |
| Black screen? | Check `adb logcat -s DeviceReport H264Decoder`; Mac quality **Fast** |
| High latency? | 5 GHz Wi‑Fi; Android **11+**; Mac **Balanced** / **Fast** |
| iPhone / iPad? | [peetzweg/opendisplay](https://github.com/peetzweg/opendisplay) (TestFlight) |
| Privacy? | Direct TCP only — [privacy page](https://peetzweg.github.io/opendisplay/privacy.html) |
| License? | [GPL-3.0](LICENSE) (≤ v0.4.x remain MIT) |

## Comparison

| | OpenDisplay | Sidecar | Duet | Luna |
|---|---|---|---|---|
| Price | **Free, OSS** | Free | Subscription | $$$ + dongle |
| Android as display | ✅ (this repo) | ❌ | ✅ | ✅ |
| iPhone as display | ✅ (main repo) | ❌ (iPad only) | ✅ | ✅ |
| Self-hosted | ✅ | — | ❌ | ❌ |

## Contributing

Issues/PRs welcome. Conventional Commits (`feat:`, `fix:`, `docs:`…). Smoke checklist and layout: [`Android/README.md`](Android/README.md).

## License

[GPL-3.0](LICENSE) — Copyright (c) 2026 Philip Poloczek.
