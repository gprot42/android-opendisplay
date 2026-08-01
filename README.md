<div align="center">

<img src="public/logo.png" width="128" alt="OpenDisplay app icon" />

# OpenDisplay (GrapheneOS)

**GrapheneOS receiver** — turn a GrapheneOS phone or tablet into a second Mac
monitor over Wi‑Fi or USB. Built for de-Googled Pixel hardware; not a general
stock-Android product.

Mac + iPhone/iPad apps (upstream):

- **[peetzweg/opendisplay](https://github.com/peetzweg/opendisplay)**
- [Website](https://peetzweg.github.io/opendisplay/)
- [Wire protocol](WIRE.md)
- [Receiver details](Android/README.md)

<br />

<a href="https://ko-fi.com/peetzweg">
  <img src="https://ko-fi.com/img/githubbutton_sm.svg" alt="Buy Me a Coffee on ko-fi.com" />
</a>

</div>

---

Free, open source, no subscription — Sidecar / Duet / Luna alternative
on hardware you already own, including **GrapheneOS**.

## Features

**Display**

- **Extend** — real second desktop (virtual Mac display)
- **Mirror** — show the main Mac screen on the device
- Retina-scale stream via hardware H.264
- Portrait or landscape

**Connect**

- **Wi‑Fi / LAN** (default) — mDNS discovery (`_opensidecar._tcp` + signature),
  or manual **IP:9000**
- **Reverse connect** (tablet → Mac) — when the router blocks Mac→device TCP
  (guest Wi‑Fi, AP client isolation, some VPNs), the Mac listens and the
  GrapheneOS app dials back. See [Reverse connection](#reverse-connection)
- **USB + adb** — cable path; keeps Mac Wi‑Fi working; can assist reverse via
  `adb reverse` when Wi‑Fi peer traffic is blocked
- **USB tethering** — no debugging; may affect Mac internet routing
- Mac **Connect over network** — classic dial + reverse when peer TCP fails
- In-app **Can't connect over Wi‑Fi?** — GrapheneOS VPN lockdown help
  (Always-on vs **Block connections without VPN**); opens system VPN settings

**Discovery & trust**

- Signature-verified discovery only (Bonjour TXT `sig=OpenDisplay` and/or
  UDP `od-ack`) — no ARP false positives
- Idle screen always shows **IP:port** when mDNS is filtered

**Input & audio**

- Touch click, drag, and two-finger scroll
- Pinch-to-zoom; Mac cursor overlay
- System audio: **Play on device** (default) or **This Mac**

**Reliability**

- Foreground service keeps the session through Home / recents
- Auto-reconnect for brief blips
- Retrieve windows back to the Mac in Extend mode (optional; off by default)

## Reverse connection

Many home and guest routers allow devices to *see* each other (ping, mDNS)
but **block peer-to-peer TCP**. Classic OpenDisplay has the **Mac dial the
device** on port **9000** — that path fails on those networks (`nc IP 9000`
times out).

**Reverse connection** flips who dials:

1. Mac starts listening (port **9011**) and advertises Bonjour
   `_opendisplay-mac._tcp`.
2. GrapheneOS app discovers the Mac and **connects outbound** to it.
3. After TCP is up, the same wire protocol runs as usual (Mac still sends
   video; device still sends `hello` / touch).

| Situation | What to use |
|---|---|
| Normal LAN (peer TCP works) | Mac dials device `:9000` (classic) |
| AP isolation / guest Wi‑Fi / VPN blocking peer TCP | **Reverse** (device dials Mac `:9011`) |
| USB debugging plugged in | Reverse can use `adb reverse tcp:9011` so the device dials `127.0.0.1` while the Mac still “listens” for reverse |

### GrapheneOS VPN lockdown (common Wi‑Fi failure)

GrapheneOS enables **both** of these when you first set up any VPN
([features](https://grapheneos.org/features)):

| Toggle | Role |
|---|---|
| **Always-on VPN** | OS keeps that VPN selected / restarts it |
| **Block connections without VPN** | Kill switch: only VPN traffic allowed |

**Block connections without VPN** (lockdown) is what breaks OpenDisplay on
Wi‑Fi. While it is on:

- LAN peer TCP is blocked (Mac ↔ tablet)
- Private IPs like `192.168.x.x` are not exempt
- It still blocks if the tunnel looks **disconnected**
- VPN-app “Allow LAN” is not enough with OS lockdown on

That is why pure Wi‑Fi fails while **USB + `adb reverse`** can still work:
the tablet dials `127.0.0.1`, not the Mac’s LAN address.

**Fix (required for pure Wi‑Fi):**

1. **Settings → Network & internet → VPN**
2. Tap the **gear** on each configured VPN
3. Turn **off** **Block connections without VPN**
4. Optionally turn **Always-on VPN** off too
5. Toggle Wi‑Fi, then **Connect over network**

Also enable **Allow LAN** / turn off Network Lock in the VPN app if
present.

In the receiver app, **Can't connect over Wi‑Fi?** opens VPN settings and
shows these steps. A normal app **cannot** flip the kill switch for you.

## What works (GrapheneOS)

| Feature | Status |
|---|---|
| TCP :9000 + `hello` | ✅ |
| H.264 hardware decode | ✅ |
| Touch click / drag + two-finger scroll | ✅ |
| Mac cursor overlay | ✅ |
| mDNS discovery (`_opensidecar._tcp` + `sig`) | ✅ when LAN allows multicast |
| **Reverse connect** (device → Mac `:9011`) | ✅ when device can open TCP to Mac |
| Manual IP connect | ✅ when peer TCP is open |
| USB + adb | ✅ |
| USB tethering | ✅ fallback |
| System audio | ✅ device or This Mac |
| Background keep-alive | ✅ session survives Home |

## Platform

| | |
|---|---|
| **Target OS** | **[GrapheneOS](https://grapheneos.org/)** on supported Pixels |
| **minSdk** | API **26** (Android 8.0 baseline; GrapheneOS builds are much newer) |
| **targetSdk** | API **35** |
| **Required** | Hardware H.264 / AVC decoder |

| Device | OS | Result |
|---|---|---|
| **Google Pixel Tablet** | **GrapheneOS** | Stream + touch + cursor (network reverse / USB) |
| Pixel phones (GrapheneOS-supported) | GrapheneOS | Expected same path; PRs welcome |

Stock OEM Android is **not** the focus of this fork. The APK is a standard
Android package and may run elsewhere, but **testing and docs assume GrapheneOS**.

## Install & run

**Mac:** [OpenDisplay.dmg](https://github.com/peetzweg/opendisplay/releases/latest)
from the main project, or build this fork:

```sh
./install-mac.sh --open            # Debug → OpenDisplay Dev.app
./install-mac.sh --release --open  # Release → OpenDisplay.app
```

**GrapheneOS device:**

```sh
cd Android
./gradlew :app:assembleDebug
# Version from ../version.md → ~/OpenDisplay-0.0.2-debug.apk
adb install -r ~/OpenDisplay-*-debug.apk
```

Needs JDK 17+ and the Android SDK (to build the receiver APK).
Details: [`Android/README.md`](Android/README.md).

1. Open the receiver app on GrapheneOS.
2. **Network (default):** same Wi‑Fi → Mac OpenDisplay → **Connect over
   network** (or pick the discovered device). If Mac→device TCP is
   blocked, reverse connect starts automatically (device dials Mac).
3. **USB (keeps Mac Wi‑Fi):** enable USB debugging + `adb` → Mac
   **Android USB** / adb path. Prefer this over tethering when you need
   a reliable cable stream.

   Full USB detail:
   [`Android/README.md`](Android/README.md#usb-recommended-adb--keeps-mac-internet).
4. Grant Mac **Screen Recording** + **Accessibility** if prompted.

## How it works

```
MAC (sender)                                   GRAPHENEOS (receiver)
CGVirtualDisplay
   → ScreenCaptureKit → H.264

Classic (peer TCP OK):
   Mac dials device:9000  ═══════════════════→  listen :9000 → MediaCodec

Reverse (peer TCP blocked Mac→device):
   Mac listens :9011 (+ Bonjour _opendisplay-mac)
   ← device dials Mac:9011 ═══════════════════
   then same framed H.264 / JSON as classic

   ← JSON (hello, touch, scroll) ═══════════════
```

Screen stays on your LAN — never uploaded.
Full wire format: [`WIRE.md`](WIRE.md).

## FAQ

| Question | Answer |
|---|---|
| Mac doesn’t see the device? | Same LAN; allow Local Network; try manual **IP:9000**; disable VPN / AP isolation |
| Wi‑Fi fails, USB/`adb reverse` works? | Turn off **Block connections without VPN** (see [VPN lockdown](#grapheneos-vpn-lockdown-common-wi-fi-failure)); still blocks when tunnel is off |
| `nc IP 9000` times out? | Peer TCP blocked (VPN lockdown, AP isolation) — fix lockdown, reverse connect, or USB |
| Black screen? | `adb logcat -s DeviceReport H264Decoder`; Mac quality **Fast** |
| High latency? | 5 GHz Wi‑Fi; Mac **Balanced** / **Fast** |
| Can’t use Mac apps while extended? | Lift finger from tablet; Cmd+Tab or **Retrieve Windows** |
| Stock Android? | This fork targets **GrapheneOS**; not the supported surface |
| iPhone / iPad? | [peetzweg/opendisplay](https://github.com/peetzweg/opendisplay) |
| Privacy? | Direct TCP only — [privacy](https://peetzweg.github.io/opendisplay/privacy.html) |
| License? | [GPL-3.0](LICENSE) (≤ v0.4.x remain MIT) |

## Comparison

| | OpenDisplay (this fork) | Sidecar | Duet | Luna |
|---|---|---|---|---|
| Price | **Free, OSS** | Free | Subscription | $$$ + dongle |
| GrapheneOS as display | ✅ | ❌ | ❌ | ❌ |
| Stock Android as display | Not the focus | ❌ | ✅ | ✅ |
| iPhone as display | Upstream repo | ❌ (iPad only) | ✅ | ✅ |
| Self-hosted / no cloud | ✅ | — | ❌ | ❌ |

## Contributing

Issues/PRs welcome. Conventional Commits (`feat:`, `fix:`, `docs:`…).
Smoke checklist and layout: [`Android/README.md`](Android/README.md).

Upstream OpenDisplay (Mac + iPhone/iPad) was invited to merge this Android
tree for a unified codebase — see
[peetzweg/opendisplay#186](https://github.com/peetzweg/opendisplay/issues/186)
(no PR from us; merge welcome).

## License

[GPL-3.0](LICENSE) — Copyright (c) 2026 Philip Poloczek.
