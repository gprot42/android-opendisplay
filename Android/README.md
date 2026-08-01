# OpenDisplay for GrapheneOS

Use a **[GrapheneOS](https://grapheneos.org/)** phone or tablet as a **second
monitor** for a Mac running this OpenDisplay Mac app (or upstream
[peetzweg/opendisplay](https://github.com/peetzweg/opendisplay)).

This receiver is an Android APK, but **this fork is tested and documented for
GrapheneOS**, not stock OEM Android.

Same wire protocol as iOS — see [`WIRE.md`](../WIRE.md). **Network is the
default**; USB is optional.

## Features

**Display**

- Extend (virtual Mac display) or Mirror
- Hardware H.264 decode (`MediaCodec`)
- Portrait / landscape

**Connect**

- **Wi‑Fi / LAN** — listen on **:9000**; Mac dials when peer TCP works
- **mDNS** — advertise `_opensidecar._tcp` with TXT `sig=OpenDisplay`
- **Reverse connect** — when Mac→device TCP is blocked (AP isolation, guest
  Wi‑Fi, many VPNs), the Mac listens on **:9011** (`_opendisplay-mac._tcp`)
  and this app **dials the Mac**. Same stream protocol after TCP is up.
  With USB debugging attached, Mac can set `adb reverse tcp:9011` so the
  device dials `127.0.0.1:9011` if pure Wi‑Fi outbound is blocked.
- **VPN help in-app** — idle **Can't connect over Wi‑Fi?** explains
  Always-on vs lockdown and opens system VPN settings (apps cannot
  disable the kill switch).
- **USB + adb** — `adb forward tcp:9000` (Mac dials loopback)
- **USB tethering** — optional path without debugging

**Why reverse connect?**  
Classic Sidecar-style apps assume the computer can open a TCP connection to
the tablet. Home/guest routers often allow discovery (mDNS/ping) but **drop
peer TCP**. Reverse connect flips dial direction so streaming can still work
on those networks.

**Input & audio**

- Touch click / drag / two-finger scroll; pinch-zoom
- Mac cursor overlay
- System audio to device speakers when enabled on the Mac

**Reliability**

- Foreground service; stream survives Home / recents

## What works (GrapheneOS)

| Feature | Status |
|---|---|
| TCP listen on port **9000** + `hello` | Works |
| H.264 hardware decode (MediaCodec) | Works |
| Touch click / drag + two-finger scroll | Works |
| Pinch-to-zoom + pan when zoomed + double-tap reset | Works |
| Mac cursor overlay | Works |
| mDNS (`_opensidecar._tcp` + signature) | Works when LAN allows multicast |
| **Reverse connect** (dial Mac `:9011`) | Works when device→Mac TCP (or adb reverse) works |
| Manual IP connect | Works when Mac→device TCP works |
| USB + adb | Works |
| USB tethering | Works (may affect Mac internet) |
| System audio | Mac → device when streaming |
| Background keep-alive | Foreground service |

## Platform

| | |
|---|---|
| **Target OS** | **GrapheneOS** on supported Pixel devices |
| **Minimum API** | **26** (build baseline; GrapheneOS is far newer) |
| **Target API** | **35** |
| **Required** | Hardware **H.264 / AVC** decoder |

### Verified

| Device | OS | Result |
|---|---|---|
| **Google Pixel Tablet** | **GrapheneOS** | Stream + touch + cursor (reverse network / USB) |

Stock Android / other OEMs are **not** the documented support surface. PRs
welcome for other GrapheneOS-supported Pixels.

## How we keep builds working

1. **minSdk 26 / targetSdk 35** — GrapheneOS runs a current API; we still version-guard platform APIs.
2. **Decode** — `KEY_LOW_LATENCY` on API 30+; vendor keys with plain MediaCodec fallback.
3. **Network** — cleartext TCP on LAN (`network_security_config`); classic listen `:9000` plus reverse dial to Mac `:9011`.
4. **Discovery is optional** — idle screen always shows **IP:port** when mDNS is blocked.
5. **Startup probe** — logs API level, ABI, AVC decoder (`adb logcat -s DeviceReport H264Decoder`).
6. **CI** — unit tests + debug APK assemble (see `.github/workflows/android.yml`).
7. **Manual smoke** — [checklist](#smoke-checklist) on GrapheneOS (Pixel Tablet or phone) before release.

## Build & install

```sh
cd Android
./gradlew :app:assembleDebug
# Version from ../version.md → ~/OpenDisplay-0.0.2-debug.apk
adb install -r ~/OpenDisplay-*-debug.apk
```

Needs **JDK 17+** and the Android SDK.

## Connect from the Mac

### Network (default)

1. Open this app on GrapheneOS (leave it on the waiting screen).
2. Same Wi‑Fi as the Mac (avoid guest Wi‑Fi / VPNs that block LAN if you can).
3. Mac OpenDisplay → **Connect over network** (IP filled from discovery when possible).
4. Grant Mac **Screen Recording** + **Accessibility** if prompted.

**If classic dial fails** (`nc <tablet-ip> 9000` times out): reverse connect
kicks in — Mac listens on **9011**, this app dials the Mac. Keep the app open.
With USB debugging connected, Mac may use `adb reverse tcp:9011` so the app
can dial `127.0.0.1:9011` when pure Wi‑Fi peer traffic is blocked.

### USB (adb — keeps Mac internet)

USB debugging does **not** install a Mac default route, so **Wi‑Fi keeps working**.

1. Enable **Developer options → USB debugging** (GrapheneOS: Developer options as usual).
2. Cable device ↔ Mac; accept the debugging prompt if shown.
3. Mac OpenDisplay → **Android USB** / adb path (needs
   [platform-tools](https://developer.android.com/tools/releases/platform-tools)
   `adb` on PATH or the usual SDK location).
4. **Do not enable USB tethering** unless adb is unavailable.

Manual equivalent:

```sh
adb forward tcp:9000 tcp:9000
# Mac → manual connect 127.0.0.1 port 9000
```

### USB without debugging (tethering)

Android **USB tethering** creates an RNDIS/NCM link so the Mac can reach the tablet without adb. **Side effect:** macOS often makes the phone the default route and **Wi‑Fi appears offline**. OpenDisplay then best-effort **removes only that tether default route** so Wi‑Fi is primary again while still using the cable for the display session.

**Setup checklist**

1. Cable tablet ↔ Mac (data cable, not charge-only).
2. USB notification / **Settings → USB**.
3. **USB controlled by → Connected device** (this computer).
4. Enable **USB tethering** (**Settings → Network & internet → Hotspot & tethering → USB tethering**). Toggle off→on if the Mac row stays “accessory/charging”.
5. OpenDisplay Android app → mode **USB**.
6. Mac OpenDisplay → **Android USB** — label should become **“Android USB (tether)”** (not “accessory/charging”). In **System Settings → Network** you should see a **Pixel Tablet** (or similar) interface with an IPv4 address (often `192.168.42.x`).

**If Mac shows the tablet on USB but “no devices” / connect fails:** the cable is up but the tablet is not in a network or adb USB mode (e.g. product id accessory `0x4EE1`). Re-enable **USB tethering**, or turn on **USB debugging**. Charge-only mode will never work.

**Mac internet:** USB tethering often ranks the tablet **above Wi‑Fi** in Network Service Order (internet “dies”). While OpenDisplay is open it automatically puts **Wi‑Fi above** Pixel/Android USB services. If internet is still broken: **System Settings → Network → ⋯ → Set Service Order** → drag **Wi‑Fi** to the top, or turn tethering off.

Grant Mac **Screen Recording** + **Accessibility** if prompted.
## Smoke checklist

Run on GrapheneOS (Pixel Tablet or supported phone):

- [ ] App launches; idle screen shows port **9000** and a LAN IP (or `adb forward` path).
- [ ] `adb logcat -s DeviceReport` shows **H.264 decoder: …** (not MISSING).
- [ ] Mac connects (discovery, reverse, **or** manual IP / USB).
- [ ] Extended display appears; desktop is visible (not black for >3s).
- [ ] Mouse cursor visible on the device when the pointer is on that display.
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

Emulator networking to a Mac on the host: use the emulator’s IP as shown in the app, or `adb forward` from the host Mac.

## Troubleshooting

| Symptom | What to try |
|---|---|
| Mac doesn’t list the device | Same LAN; Local Network on Mac; manual **IP:9000**; VPN / AP isolation |
| Wi‑Fi fails; USB / `adb reverse` works | OS VPN **lockdown** — see [below](#grapheneos-vpn-lockdown) |
| `nc <ip> 9000` times out | Peer TCP blocked — fix lockdown, reverse connect, or USB/adb |
| Reverse connects then drops | Keep app open; allow LAN in VPN apps; avoid guest Wi‑Fi |
| Black screen | Decoder in logcat; Mac quality **Fast**; wait for keyframe |
| No cursor | Move pointer onto the virtual display |
| High latency | Prefer 5 GHz Wi‑Fi; Mac quality **Balanced** or **Fast** |
| Connect then drop | Keep app foreground; don’t lock screen mid-session |
| VPN / ExpressVPN / Nord | OS lockdown **off** and app **Allow LAN** / Network Lock off |

### GrapheneOS VPN lockdown

GrapheneOS turns **both** toggles on when you first set up any VPN:

| Toggle | What it does |
|---|---|
| **Always-on VPN** | Keeps that VPN selected; may restart the tunnel |
| **Block connections without VPN** | Kill switch — only VPN paths allowed |

**Block connections without VPN** (lockdown) is the one that breaks
Mac ↔ tablet Wi‑Fi:

- Blocks LAN peer TCP (classic `:9000` and reverse `:9011`)
- Still blocks when the VPN app looks **disconnected**
- VPN-app “Allow LAN” does **not** override OS lockdown
- `adb reverse` + dial `127.0.0.1` can still work (loopback, not LAN)

**Turn it off for pure Wi‑Fi:**

1. **Settings → Network & internet → VPN**
2. Tap the **gear** on each listed VPN
3. Turn **off** **Block connections without VPN**
4. Optionally turn **Always-on VPN** off too
5. Toggle Wi‑Fi, then retry **Connect over network**

In OpenDisplay, **Can't connect over Wi‑Fi?** on the idle screen shows
these steps and opens **VPN settings**. A normal app **cannot** change
this toggle (Device Owner / user only).

Also in the VPN app: enable **Allow LAN** / **Local network sharing**
and disable any Network Lock / app kill switch if present.

| Goal | Always-on | Block without VPN |
|---|---|---|
| Max privacy on the go | ON | ON |
| Home LAN + OpenDisplay Wi‑Fi | optional | **OFF** |
| VPN only when you open the app | OFF | OFF |

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
