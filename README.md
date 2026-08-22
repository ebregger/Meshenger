# bluetooth_app — Agent / tooling guide

Bluetooth mesh chat app (Flutter + Android native GATT). Messages sync over BLE via a CRDT store. This README is for **agents and humans** ramping up on the existing debug/deploy tools.

Project conventions live in [`.cursorrules`](.cursorrules) (Riverpod, Protobuf OTA, small files, permissions, etc.).

---

## Quick orientation

| Path | Role |
|------|------|
| `lib/` | Flutter UI, Riverpod providers, Dart services |
| `lib/services/api_service.dart` | In-app HTTP debug API (port **8080** on device) |
| `lib/services/ui_debug_snapshot.dart` | Tracks what the chat UI has painted (`/ui`) |
| `android/.../MainActivity.kt` | Native mesh GATT / scan / connect |
| `proto/mesh_data.proto` | Protobuf schemas |
| `deploy.py` | Build debug APK, install on all `adb` devices, port-forward, launch |
| `stress_test.py` | Multi-device mesh benchmark using the API + logcat |

Package / activity: `com.example.bluetooth_app/.MainActivity`

Stress API is gated by `ENABLE_STRESS_TEST_API` in `lib/main.dart` (currently `true`). When enabled, look for logcat: `Stress Test API running on port 8080`.

---

## Prerequisites

- Flutter SDK, Android SDK, `adb` on `PATH`
- One or more physical Android devices (BLE mesh needs real radios)
- USB debugging authorized; grant Bluetooth / Nearby Devices permissions on first launch

---

## Tool 1: `deploy.py`

Builds a debug APK, installs it on **every** connected device, forwards a host port to each device’s `:8080`, and launches the app.

```bash
python deploy.py
```

Port assignment (sorted by `adb devices` order):

| Device index | Host port → device |
|--------------|--------------------|
| 0 | `127.0.0.1:18081` → `:8080` |
| 1 | `127.0.0.1:18082` → `:8080` |
| 2 | `127.0.0.1:18083` → `:8080` |

`stress_test.py` expects these same ports (`PORTS = [18081, 18082, 18083]`).

**Manual equivalent for one device:**

```bash
flutter build apk --debug
adb -s <SERIAL> install -r build/app/outputs/flutter-apk/app-debug.apk
adb -s <SERIAL> forward tcp:18081 tcp:8080
adb -s <SERIAL> shell am start -n com.example.bluetooth_app/.MainActivity
```

---

## Tool 2: Stress Test HTTP API (on-device)

Bound on the device at `0.0.0.0:8080`. Reach it via the forwarded host port after deploy.

### Endpoints

| Method | Path | Purpose |
|--------|------|---------|
| `GET` | `/info` | `{ nodeId, status }` — liveness + identity |
| `GET` | `/messages` | Messages in the **local DB** (`msgId`, `textContent`) |
| `GET` | `/ui` | What the chat list has **painted** (see below) |
| `POST` | `/send` | Body: `{ "text": "..." }` — create/send a chat message |
| `POST` | `/config` | Simulation knobs: `dropRate`, `ignoreMac`, or `{ "reset": true }` |
| `POST` | `/reset_ble` | Tear down/restart native GATT server + re-advertise (clears leaked slots) |

### `/ui` vs `/messages`

- **`/messages`** = SQLite/CRDT store. A row can appear here before Flutter redraws.
- **`/ui`** = post-paint snapshot from `UiDebugSnapshot`.

`/ui` response shape:

```json
{
  "revision": 2,
  "changedAtMs": 1787423402446,
  "count": 2,
  "messages": [
    { "msgId": "...", "textContent": "...", "originNodeId": "..." }
  ]
}
```

`revision` increments **only** when the rendered message id list changes. Poll it to detect UI updates.

### Quick smoke test (one device on 18081)

```bash
curl -s http://127.0.0.1:18081/info
curl -s http://127.0.0.1:18081/ui
curl -s -X POST http://127.0.0.1:18081/send \
  -H "Content-Type: application/json" \
  -d "{\"text\":\"hello@$(date +%s)\"}"
curl -s http://127.0.0.1:18081/ui
# expect revision >= 1 and the new text in messages
```

PowerShell:

```powershell
Invoke-RestMethod http://127.0.0.1:18081/info
Invoke-RestMethod http://127.0.0.1:18081/ui
Invoke-RestMethod http://127.0.0.1:18081/send -Method POST -ContentType 'application/json' -Body '{"text":"UIVerify"}'
Invoke-RestMethod http://127.0.0.1:18081/ui
```

---

## Tool 3: `stress_test.py`

End-to-end mesh benchmark across multiple phones.

```bash
python stress_test.py                  # default 10 messages
python stress_test.py --messages 30
```

What it does:

1. Hits `/info` on ports `18081–18083`; skips unreachable devices
2. Calls `/reset_ble` on each reachable device (fresh GATT)
3. Streams `adb logcat` (`flutter`, `NativeMeshService`) for `[BENCHMARK]` / `[DIAGNOSTIC]`
4. Round-robins `POST /send` across devices
5. Polls **`GET /ui`** until tags appear on every other device’s painted list (or timeout)
6. Prints latency / bandwidth / failure analytics and a device→device receipt matrix

Needs **≥2** reachable APIs and **≥2** `adb` devices for a meaningful mesh run. One device is enough to exercise `/ui` and `/send` manually.

Port ↔ serial mapping assumes the same order as `deploy.py` (`sorted` host ports ↔ `adb devices` order).

---

## Tool 4: Logcat telemetry

Filter tags the stress harness already watches:

```bash
adb -s <SERIAL> logcat -v raw -s flutter,NativeMeshService
```

### `[BENCHMARK]` events (pipe-separated `KEY:value`)

| Event | Meaning |
|-------|---------|
| `CREATED` | Local message inserted (`MSG_ID`) |
| `SCAN_COMMANDED` / `SCAN_HIT` | Scanner activity |
| `OFFER_SENT` | Sync offer toward a peer |
| `GATT_CONNECTED` | Native GATT connected |
| `DELTA_RECEIVED` | Sync payload bytes received |
| `MERGED` | Message row merged into local DB |
| `UI_CHANGED` | Painted list changed (`REVISION`, `COUNT`) |
| `DISPLAYED` | First time a `MSG_ID` appeared in a UI snapshot |

### `[DIAGNOSTIC]` events

Foreground/background (`APP_STATE`), connection failures, penalty box, GATT collisions, telemetry header bytes, scan ticks.

Useful ad-hoc filters:

```bash
adb logcat -d | findstr /i "UI_CHANGED DISPLAYED MERGED Stress Test API"
```

---

## Suggested agent workflow

1. `adb devices -l` — confirm serials
2. `python deploy.py` (or manual install + `adb forward`)
3. Wait for `Stress Test API running on port 8080` in logcat
4. `GET /info` — confirm API
5. For UI work: `POST /send` → poll `GET /ui` until `revision` bumps
6. For mesh work: deploy to ≥2 devices → `python stress_test.py --messages 10`
7. If GATT stops connecting after long runs: `POST /reset_ble` (or re-run stress test, which kicks BLE on start)

---

## Common pitfalls

- **API unreachable** — app not launched, `ENABLE_STRESS_TEST_API` false, or port forward missing/stale (`adb forward --list`)
- **`/ui` stuck at revision 0** — chat UI never painted (still loading / crash); check Flutter logcat
- **DB has message, UI doesn’t** — compare `/messages` vs `/ui`; that’s intentional for catch UI lag
- **Blackout on one path in stress report** — BLE permissions, radio stall, or GATT slot exhaustion → `/reset_ble`
- **Wrong port** — device order changed; re-run `deploy.py` or re-forward explicitly

---

## Related source

- API server: `lib/services/api_service.dart`
- UI snapshot: `lib/services/ui_debug_snapshot.dart` (reported from `lib/screens/home_screen.dart` after paint)
- Mesh sync / merge: `lib/providers/ble_network_provider.dart`
- Discovery: `lib/services/ble_discovery_service.dart`
- Native stack: `android/app/src/main/kotlin/com/example/bluetooth_app/MainActivity.kt`
