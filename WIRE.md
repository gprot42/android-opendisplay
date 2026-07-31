# OpenDisplay wire protocol

Contract between the **Mac sender** and any **receiver** (iOS today, Android
tablet in progress). Kept at the repo root (`docs/` is reserved for the Vite
site build). Keep this aligned with:

- `Shared/Protocol.swift` — protocol version integers and named message types
- `Mac/MacSender.swift` — encode, framing, control handling
- `iOS/PhoneReceiver.swift` — receive path reference implementation
- `tools/fake-receiver.swift` — minimal peer for Mac-side testing

Bump **`pv` only when the wire changes**, not for UI-only releases. See
`COMPATIBILITY.md` for version policy and force-update levers.

---

## Roles

| Side | Role |
|---|---|
| **Receiver** (phone / tablet) | **Listens** on TCP port **9000** (default) |
| **Mac** | **Connects** (USB via usbmuxd on iOS, or WiFi / manual host:port) |

The receiver-listens ordering is required for Apple USB (`usbmuxd` Connect).
Android WiFi uses the same roles so one Mac code path serves both.

---

## Framing

Every message on the TCP stream:

```
[uint32 big-endian payload length][payload bytes]
```

- Max practical payload: keep under ~1–16 MiB; reject absurd lengths.
- **Mac → receiver:** payload is either **JSON** or **video** (see below).
- **Receiver → Mac:** payload is always **JSON** (UTF-8).

### Routing Mac → receiver payloads

1. If `payload` starts with `{`, length is modest (&lt; 32 KiB), and the buffer
   contains **no** `0x00` bytes → treat as **JSON control**.
2. Otherwise → treat as a **video frame**: optional telemetry prefix + Annex B
   H.264.

JSON never contains NUL; Annex B start codes are `00 00 00 01`, so the two are
unambiguous.

---

## Discovery (WiFi)

| Field | Value |
|---|---|
| Service type | `_opensidecar._tcp` |
| Port | `9000` (or the port the app is actually listening on) |
| Service name | User-editable display name (default device name) |
| TXT `id` | Stable per-install UUID (not hardware serial) |
| TXT `pv` | Protocol version as decimal string (e.g. `"2"`) |

Mac browses with `NWBrowser` / Bonjour. Android should advertise with
`NsdManager` using the same type and TXT keys.

If discovery fails, the receiver should show **IP:port** so the Mac can use
manual host/port connect.

---

## Protocol version

| Constant | Current value | Meaning |
|---|---|---|
| `pv` (this build) | **2** | Speaks handshake + additive fields |
| `minSupportedPeer` | **1** | Oldest peer still accepted |
| Absent `pv` on peer | treated as **1** | Pre-handshake installs |

On every `hello`, the Mac replies with:

```json
{"type":"welcome","pv":2,"min":1}
```

If the receiver’s `pv` is below the Mac’s `min`, the Mac may send
`updateRequired` (iOS App Store path today; Android may ignore or map to
Play/sideload later).

---

## Control messages — receiver → Mac

All are length-prefixed JSON objects with a string `"type"`.

### `hello` (required after connect; re-send on rotation)

```json
{
  "type": "hello",
  "pixelsWide": 2560,
  "pixelsHigh": 1600,
  "scale": 2.0,
  "device": "Android",
  "id": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
  "pv": 2
}
```

| Field | Required | Notes |
|---|---|---|
| `pixelsWide` / `pixelsHigh` | yes | **Physical pixels** of the streaming surface, **current orientation** |
| `scale` | yes | Density factor (~2 / 3); Mac sizes the virtual display ~half in points for HiDPI |
| `device` | no | `"iPhone"` / `"iPad"` / `"Android"` / etc. UI copy only |
| `id` | no | Per-install UUID; Mac matches same device across transports |
| `pv` | no | Absent ⇒ protocol 1 |

### `touch`

```json
{"type":"touch","phase":"began","x":0.5,"y":0.25,"t":1710000000123.4}
```

| Field | Notes |
|---|---|
| `phase` | `began` \| `moved` \| `ended` \| `cancelled` |
| `x`, `y` | Normalized **[0, 1]** in **video** space, origin **top-left** |
| `t` | Optional; Mac wall-clock ms (receiver clock + sync offset) for input latency |

Semantics: down = left mouse down, move while down = drag, up = left mouse up.

### `scroll`

```json
{"type":"scroll","dx":0,"dy":-40}
```

`dx` / `dy` in **video pixels**, natural-scrolling sign (finger moves up → content
up → typically negative `dy` for “scroll down” feel — match iOS sender).

### `ping`

```json
{"type":"ping","t":1710000000000.0}
```

Receiver wall-clock ms. Mac replies with `pong`.

### `stats` (optional)

Aggregated receive-side health (~every 5s). Fields are additive; Mac logs them.
See iOS `PhoneReceiver` for the current set (`fps`, `mbps`, `e2e50`, …).

### `kf`

```json
{"type":"kf"}
```

Ask the Mac for an IDR (and SPS/PPS) on the next frame — use after decoder
reset or attach mid-GOP.

### `viewport` (optional; Android pinch-zoom)

```json
{"type":"viewport","x":0.25,"y":0.25,"w":0.5,"h":0.5,"z":2.0}
```

| Field | Notes |
|---|---|
| `x`,`y` | Top-left of the visible region in normalized **full-desktop** space `[0,1]` |
| `w`,`h` | Size of the visible region in the same space |
| `z` | Pinch scale (≥ 1) |
| Mac | ROI-crops ScreenCaptureKit to this rect (full encode size → sharp zoom) and raises bitrate |

Older Mac builds ignore unknown types. Send on pinch/pan (debounced); send
`z:1, x:0, y:0, w:1, h:1` on reset.

### `sleeping` / `closing`

```json
{"type":"sleeping"}
{"type":"closing"}
```

| Type | When | Mac behavior |
|---|---|---|
| `sleeping` | Device locked / stream intentionally paused | Tear down virtual display; may arm reconnect |
| `closing` | App quitting for real | End session without wake wait |

---

## Control messages — Mac → receiver

### `pong`

```json
{"type":"pong","t":1710000000000.0,"mt":1710000000012.3}
```

Echo of receiver `ping.t` plus Mac clock `mt` for NTP-style offset estimation.

### `ping` (Mac liveness + health)

```json
{
  "type": "ping",
  "drops": 0,
  "encDrops": 0,
  "netDrops": 0,
  "pending": 0,
  "inp50": 0,
  "inp95": 0,
  "capFps": 60
}
```

### `welcome`

```json
{"type":"welcome","pv":2,"min":1}
```

### `updateRequired`

```json
{
  "type": "updateRequired",
  "target": "ios",
  "store": "https://…",
  "message": "…"
}
```

### `cursor` / `cursorImg` (optional)

Local cursor echo when the Mac hides the system cursor from capture.
Receivers that do not implement these may ignore unknown types.

---

## Video frames (Mac → receiver)

Payload layout:

```
[optional UTF-8 JSON meta without NUL][Annex B H.264]
```

### Optional meta prefix

Immediately before the first start code:

```json
{"cap":1710000000100,"snd":1710000000110}
```

| Field | Meaning |
|---|---|
| `cap` | Capture wall-clock ms on the Mac |
| `snd` | Socket-send wall-clock ms on the Mac |

Used with `ping`/`pong` offset for end-to-end latency. Safe to ignore.

### Annex B H.264

- Start code: **`00 00 00 01`** only (Mac does not emit 3-byte start codes).
- Keyframes: Mac prepends **SPS** (NAL type 7) and **PPS** (NAL type 8), then
  slice NALUs.
- Real-time encode, **no B-frames** (VideoToolbox low-latency settings).
- SEI (type 6) may appear; receivers may skip.

Decoder requirements:

1. Collect SPS/PPS; (re)configure on change (e.g. rotation / quality).
2. Decode VCL NALUs; present ASAP (low-latency flags on Android MediaCodec).
3. On loss of sync: flush, send `kf`, wait for next IDR.

---

## Liveness

| Timer | Behavior |
|---|---|
| Receiver ping | Every ~2s while connected |
| Receiver watchdog | No Mac data for ~5s → drop connection, accept again |
| Mac | Streams video + periodic `ping`; ends session on `sleeping`/`closing` |

Use **TCP_NODELAY** on both ends (touch packets are tiny).

---

## Default ports and manual connect

| Setting | Default |
|---|---|
| Listen port | `9000` |
| Manual Mac connect | host + port (existing Mac UI / CLI escape hatch) |

Android USB is **not** usbmuxd. Power-user workaround:  
`adb reverse tcp:9000 tcp:9000` then Mac → `127.0.0.1:9000`.

---

## Compatibility rules for new receivers

1. **Ignore unknown JSON `type` values** (forward-compatible).
2. **Tolerate missing optional fields** on messages you do understand.
3. Prefer **additive** changes gated on peer `pv`.
4. Breaking changes are **two-phase** (see `COMPATIBILITY.md`).

---

## Quick test peers

```sh
# Minimal Swift peer (Mac)
swift tools/fake-receiver.swift
# Then connect the Mac app via manual host 127.0.0.1 port 9000
```

Android receivers should produce the same `hello` shape so Mac logs show a
successful session setup before video decode is implemented.
