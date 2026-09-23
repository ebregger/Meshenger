# Development notes

For people **working on** the Bluetooth mesh chat app (engineers, agents, lab tooling).  
App users should start with **[README.md](README.md)**.

Project conventions: [`.cursorrules`](.cursorrules) (Riverpod, Protobuf OTA, small files, permissions, etc.).

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
| `probe_5s.py` | **2-node catch-up probe** — alternating sends, measure propagation ≤5s |
| `stress_test.py` | Multi-device mesh benchmark using the API + logcat |
| `tools/` | Helpers imported by the root scripts (not run directly) |

Package / activity: `com.example.bluetooth_app/.MainActivity`

The stress API is gated by `ENABLE_STRESS_TEST_API` in `lib/main.dart` and runs only in debug builds. It binds to device loopback on port 8080 for ADB forwarding. When enabled, look for logcat: `Stress Test API running on port 8080`.

---

## Prerequisites

- Flutter SDK, Android SDK, `adb` on `PATH`
- One or more physical Android devices (BLE mesh needs real radios)
- USB debugging authorized; grant Bluetooth / Nearby Devices permissions on first launch

---

## `deploy.py`

Builds a debug APK, installs it on **every** connected device, forwards a host port to each device’s `:8080`, and launches the app.

```bash
python deploy.py
```

Port assignment: first **deployable** device (API ≥24, sorted `adb devices` order) gets `18081`, second gets `18082`, etc. Nexus 7 (API 18) is skipped automatically.

Confirm with `adb forward --list` after deploy — do **not** assume port order if the device list changes.

`stress_test.py` discovers live ports via `/info` and `adb forward --list` when possible; fallback list is `[18081, 18082, 18083]`.

**Manual equivalent for one device:**

```bash
flutter build apk --debug
adb -s <SERIAL> install -r build/app/outputs/flutter-apk/app-debug.apk
adb -s <SERIAL> forward tcp:18081 tcp:8080
adb -s <SERIAL> shell am start -n com.example.bluetooth_app/.MainActivity
```

---

## Stress Test HTTP API (on-device)

Bound on the device at `0.0.0.0:8080`. Reach it via the forwarded host port after deploy.

### Endpoints

| Method | Path | Purpose |
|--------|------|---------|
| `GET` | `/info` | `{ nodeId, status }` — liveness + identity |
| `GET` | `/messages` | Messages in the **local DB** (`msgId`, `textContent`) |
| `GET` | `/has_message?text=...` | `{ found, text }` — fast propagation check (no full list) |
| `GET` | `/peers` | Live neighbor list (`id`, `name`, `status`, `macAddress`, `lastSeenMs`) |
| `GET` | `/ui` | What the chat list has **painted** (see below) |
| `POST` | `/send` | Body: `{ "text": "..." }` — create/send a chat message |
| `POST` | `/clear_messages` | Wipe chat rows only (keeps display names / `users`) |
| `POST` | `/config` | Simulation knobs: `dropRate`, `ignoreMac`, or `{ "reset": true }` |
| `POST` | `/reset_ble` | Tear down/restart native GATT server + re-advertise (clears leaked slots) |

### `/ui` vs `/messages`

- **`/messages`** = SQLite/CRDT store. A row can appear here before Flutter redraws.
- **`/ui`** = post-paint snapshot from `UiDebugSnapshot`.

`revision` increments **only** when the rendered message id list changes. Poll it to detect UI updates.

### Quick smoke test (one device on 18081)

```bash
curl -s http://127.0.0.1:18081/info
curl -s http://127.0.0.1:18081/ui
curl -s -X POST http://127.0.0.1:18081/send \
  -H "Content-Type: application/json" \
  -d "{\"text\":\"hello@$(date +%s)\"}"
curl -s http://127.0.0.1:18081/ui
```

PowerShell:

```powershell
Invoke-RestMethod http://127.0.0.1:18081/info
Invoke-RestMethod http://127.0.0.1:18081/ui
Invoke-RestMethod http://127.0.0.1:18081/send -Method POST -ContentType 'application/json' -Body '{"text":"UIVerify"}'
Invoke-RestMethod http://127.0.0.1:18081/ui
```

---

## `stress_test.py`

End-to-end mesh benchmark across multiple phones.

```bash
python stress_test.py                  # default 10 messages (round-robin senders)
python stress_test.py --messages 100 --single-sender
python stress_test.py --messages 100 --sender-port 18081
```

What it does:

1. Hits `/info` on forwarded ports; skips unreachable devices
2. Calls `/reset_ble` on each reachable device (fresh GATT)
3. Clears **messages only** via `/clear_messages` (display names stay)
4. Streams `adb logcat` for `[BENCHMARK]` / `[DIAGNOSTIC]`
5. Sends via `POST /send` (round-robin, or one sender with `--single-sender` / `--sender-port`)
6. Polls **`GET /ui`** until tags appear on every other device’s painted list (or timeout)
7. Prints latency / bandwidth / failure analytics and a receipt matrix

Needs **≥2** reachable APIs and **≥2** `adb` devices for a meaningful mesh run.

---

## `probe_5s.py` (2-node catch-up benchmark)

Targets the **single-message propagation SLA**: after `POST /send` on one phone, both nodes must have the tag in DB within **5 seconds**.

```bash
python deploy.py
# wait ~15s for mesh + permissions
python probe_5s.py 30    # 30 alternating probes
```

**Do not** call `/reset_ble` after every failed probe during a batch — it destabilizes the mesh mid-run. Reset only at batch start or after a wedged session.

---

## Logcat telemetry

```bash
adb -s <SERIAL> logcat -v raw -s flutter,NativeMeshService
```

### `[BENCHMARK]` events

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

```bash
adb logcat -d | findstr /i "UI_CHANGED DISPLAYED MERGED Stress Test API"
```

---

## Suggested workflow

1. `adb devices -l` — confirm serials
2. `python deploy.py` (or manual install + `adb forward`)
3. Wait for `Stress Test API running on port 8080` in logcat
4. `GET /info` — confirm API
5. For UI work: `POST /send` → poll `GET /ui` until `revision` bumps
6. For mesh work: deploy to ≥2 devices → `python probe_5s.py 30`, then `python stress_test.py --messages 500 --single-sender`
7. If GATT stops connecting after long runs: `POST /reset_ble`
8. If one Pixel drops off ADB: `adb kill-server && adb start-server && adb devices -l`

---

## Mesh catch-up / dial notes (product behavior)

- Peer chips show connection color + sync glyph (caught up / behind / unknown).
- Local writes mark known peers behind until hash match (ADV, sync, or gossip).
- Gossip carries timed `peer_hashes` (`h` + `t`); newer observations win; stale relays are ignored.
- While any **dialable** peer is known behind, urgent/scan prefer that peer over known caught-up peers.
- Indirect behind peers without a dial MAC do not block bridging through a neighbor.

---

## Common pitfalls

- **API unreachable** — app not launched, `ENABLE_STRESS_TEST_API` false, or port forward missing/stale (`adb forward --list`)
- **`/ui` stuck at revision 0** — chat UI never painted; check Flutter logcat
- **DB has message, UI doesn’t** — compare `/messages` vs `/ui`
- **Blackout on one path in stress report** — BLE permissions, radio stall, or GATT slot exhaustion → `/reset_ble`
- **Wrong port** — device order changed; re-run `deploy.py` or check `adb forward --list`
- **Mid-batch `/reset_ble`** — causes cascade failures; reset only at batch start
- **Only one phone on ADB** — mesh stress correctly refuses to run (&lt;2 devices)

---

## Related source

- API server: `lib/services/api_service.dart`
- UI snapshot: `lib/services/ui_debug_snapshot.dart`
- Mesh sync / merge: `lib/providers/ble_network_provider.dart`
- Discovery: `lib/services/ble_discovery_service.dart`
- Native stack: `android/app/src/main/kotlin/com/example/bluetooth_app/MainActivity.kt`

---

## CI/CD Workflows

Meshenger uses GitHub Actions located in [`.github/workflows/`](.github/workflows/):

1. **`ci.yml`**: Validates every push and PR against `main`. Runs code analysis (`flutter analyze`), unit tests (`flutter test`), and builds the debug APK artifact (`meshenger-debug-apk`).
2. **`release.yml`**: Compiles production release APKs (universal + split-per-ABI: `arm64-v8a`, `armeabi-v7a`, `x86_64`), computes `SHA256SUMS.txt`, and publishes a tagged GitHub Release.

### Creating a Release

To publish a new release:
```bash
git tag v1.0.0
git push origin v1.0.0
```
Or trigger manually via **Actions** → **Release** → **Run workflow** in GitHub.
