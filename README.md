<div align="center">

<img src="public/logo.png" width="128" alt="OpenDisplay app icon" />

# OpenDisplay (Android)

**Android receiver only** — phone or tablet as a second Mac monitor over Wi‑Fi.

Mac + iPhone/iPad apps: **[peetzweg/opendisplay](https://github.com/peetzweg/opendisplay)** · [Website](https://peetzweg.github.io/opendisplay/) · [Wire protocol](WIRE.md) · [Android details](Android/README.md)

<br />

<a href="https://ko-fi.com/peetzweg">
  <img src="https://ko-fi.com/img/githubbutton_sm.svg" alt="Buy Me a Coffee on ko-fi.com" />
</a>

</div>

---

Free, open source, no subscription — alternative to Sidecar / Duet / Luna on hardware you already own.

## Features

- True display extension (or mirror) via Mac OpenDisplay
- **Wi‑Fi** only on Android (same wire protocol as iOS)
- Hardware H.264 decode · touch + two-finger scroll · pinch-to-zoom · cursor overlay
- Portrait / landscape · mDNS discovery + manual IP

## What works

| Feature | Status |
|---|---|
| TCP :9000 + `hello` | ✅ |
| H.264 hardware decode | ✅ |
| Touch click / drag + two-finger scroll | ✅ |
| Mac cursor overlay | ✅ |
| mDNS (`_opensidecar._tcp`) | ✅ when LAN allows multicast |
| Manual IP connect | ✅ |
| USB (usbmuxd) | ❌ — use Wi‑Fi or `adb reverse` |

## Android versions

| Android | API | Status | Notes |
|---|---|---|---|
| **8.0–9** | **26–28** | Supported | Higher latency; Mac quality **Fast** |
| **10** | **29** | Supported | Same as above |
| **11+** | **30+** | **Recommended** | Official low-latency decode |
| **12+** | **31+** | Supported | Guest Wi‑Fi may block mDNS → use manual IP |
| **13+** | **33+** | Supported | `NEARBY_WIFI_DEVICES` for discovery |

| | |
|---|---|
| **minSdk** | Android **8.0** (API **26**) |
| **targetSdk** | Android 15 (API 35) |
| **Required** | Hardware H.264 / AVC decoder (normal devices have one) |

| Device | Android | Result |
|---|---|---|
| Pixel 10 Pro XL | 16 / API 36 | Stream + touch + cursor (Wi‑Fi) |

More devices: PR welcome — model, Android version, pass/fail.

## Install & run

**Mac:** [OpenDisplay.dmg](https://github.com/peetzweg/opendisplay/releases/latest) from the main project.

**Android:**

```sh
cd Android
./gradlew :app:assembleDebug
# Version from ../version.md → ~/OpenDisplay-0.0.1-debug.apk
adb install -r ~/OpenDisplay-*-debug.apk
```

Needs JDK 17+ and the Android SDK. Details: [`Android/README.md`](Android/README.md).

1. Open the Android app (foreground).
2. Same Wi‑Fi as the Mac (or `adb reverse tcp:9000 tcp:9000` → Mac connects to `127.0.0.1:9000`).
3. Mac OpenDisplay → pick Wi‑Fi device or enter **IP:9000** from the idle screen.
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
