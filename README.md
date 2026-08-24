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
| `probe_5s.py` | **2-node catch-up probe** — alternating sends, measure propagation ≤5s |
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

Port assignment: first **deployable** device (API ≥24, sorted `adb devices` order) gets `18081`, second gets `18082`, etc. Nexus 7 (API 18) is skipped automatically.

**Current lab mapping (Aug 2026):**

| Device | Serial | Host port |
|--------|--------|-----------|
| Clear 3 (Pixel 3, SDK 28) | `88LX01L45` | `18081` |
| Red 3 (Pixel 3, SDK 35) | `8AKX0UCPK` | `18082` |
| Nexus 7 (skipped) | `0598e1e8` | — |

Confirm with `adb forward --list` after deploy — do **not** assume port order if device list changes.

`stress_test.py` discovers live ports via `/info` and `adb forward --list` when possible; fallback list is `[18081, 18082, 18083]`.

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
| `GET` | `/has_message?text=...` | `{ found, text }` — fast propagation check (no full list) |
| `GET` | `/peers` | Live neighbor list (`id`, `name`, `status`, `macAddress`, `lastSeenMs`) |
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

## Tool 4: `probe_5s.py` (2-node catch-up benchmark)

Targets the **single-message propagation SLA**: after `POST /send` on one phone, both nodes must have the tag in DB within **5 seconds**.

```bash
python deploy.py
# wait ~15s for mesh + permissions
python probe_5s.py 30    # 30 alternating probes (Clear→Red→Clear…)
```

Behavior:

1. `POST /reset_ble` on both forwarded ports + 2s settle
2. Two warmup sends (one per device, 4s apart)
3. Alternating `POST /send` with unique tags; polls `GET /has_message?text=...` on **both** ports every 80ms (8s hard fail)
4. 3s gap between probes
5. Exit code **0** only if **100%** OK and ≤5000ms

PowerShell one-liner smoke test:

```powershell
$tag = "SMOKE_$(Get-Date -UFormat %s)"
Invoke-RestMethod http://127.0.0.1:18081/send -Method POST -ContentType 'application/json' -Body (@{text=$tag} | ConvertTo-Json)
# poll 18081 + 18082 /has_message?text=$tag until both found=true
```

**Do not** call `/reset_ble` after every failed probe during a batch — it destabilizes the mesh mid-run. Reset only at batch start or after a wedged session.

---

## Tool 5: Logcat telemetry

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
6. For mesh work: deploy to ≥2 devices → `python probe_5s.py 30` (catch-up SLA) **then** `python stress_test.py --messages 500`
7. If GATT stops connecting after long runs: `POST /reset_ble` (or re-run stress test, which kicks BLE on start)
8. If one Pixel drops off ADB: `adb kill-server && adb start-server && adb devices -l`

---

## Agent handoff — urgent catch-up work (Aug 2026)

**Goal:** **100%** single-message propagation on Clear↔Red **under 5s**, then run `stress_test.py --messages 500`.

**Git:** `88fc45b` on `main` (NOTIFY-ready inbound + 5s probe). **Held-link reuse below is uncommitted.**

### Probe results

| Run | OK / 30 | Avg when OK | Notes |
|-----|---------|-------------|-------|
| **Held-link reuse** | **30/30** | **1.66s** (max 2.54s) | Clear 15/15, Red 15/15 |
| Prior best | 22/30 | ~2.0s | Warmup + NOTIFY-ready inbound |
| Typical before hold | 15–20/30 | ~2–3.5s | Wedged after ~15 probes |

Fix: do not disconnect the GATT client on notify EOF. Reuse that link — server inbound-NOTIFYs, client writes the next offer on the held GATT. Avoids RPA reconnect / mutual-dial / slot exhaustion.

### Uncommitted changes (summary)

| File | What changed |
|------|----------------|
| `lib/services/ble_discovery_service.dart` | Urgent sync pipeline: inbound-first, parallel race, MAC validation, GATT-hold scoped to active urgent, scan defer on fresh hash divergence, GATT recovery retry, fallback dial |
| `lib/providers/ble_network_provider.dart` | `server_connect` / `server_ready` handlers, `_recoverGattForUrgent()` |
| `lib/services/native_mesh_service.dart` | EventChannel events for server connect + NOTIFY-ready |
| `android/.../MainActivity.kt` | Held client GATT after EOF, `writeOnHeldClient`, CCCD-before-`server_ready`, 400ms notify ACK |
| `lib/services/native_mesh_urgent.dart` | `setUrgentHold` / `cancelOutbound` / `hasInboundClients` |
| `lib/services/api_service.dart` | `GET /has_message?text=` |
| `probe_5s.py` | 5s propagation probe script |

### Root causes identified (still partially open)

1. **Stale RPA dial MACs** — urgent dialed dead MACs; mitigated via `rememberScanMac(seenAt:)` + `candidateDialMacs()`
2. **False-positive inbound push** — NOTIFY to wrong/stale inbound MAC reported success; mitigated via `_resolveInboundMacForPeer()` + NOTIFY-only-after-CCCD (`server_ready`)
3. **Mutual-dial collision** — both peers outbound simultaneously; mitigated via hash-divergence defer + inbound-first race
4. **GATT slot exhaustion** — leftover dual-role reconnects; mitigated by holding one client link and skipping scan-path while held
5. **8s urgent radio hold** — was blocking scan recovery; now cleared in `_runUrgentSync` `finally`
6. **`probe_5s.py` indentation bug** — fixed (lines 64–72 were outside the loop briefly; caused bogus 1/30 summaries)

### TODO for next agent

1. **[x] Hit 30/30 on `probe_5s.py 30`** — Clear 15/15, Red 15/15, avg 1655ms, max 2539ms
2. **[x] Stabilize Red→Clear** — held client reuse + inbound NOTIFY
3. **[x] Stabilize Clear→Red** — same persistent link
4. **[x] Reduce GATT wedge** — one held link; skip scan-path while held; no mid-probe `resetServer`
5. **[x] `server_ready` after CCCD response** — both SDK 28 and 35; notify ACK timeout 400ms (SDK 28 never fires `onNotificationSent`)
6. **[ ] `python stress_test.py --messages 500`** — send finished; UI poll stalled at 11/500 (`/ui` windowing + urgent newest-1 during 0.3s burst). Coalesce + held-link scan-path are in the tree, not re-run.
7. **[ ] Commit** when user asks — do **not** commit `*.txt` stress logs or `.cursor/`

### Debug commands

```bash
adb -s 88LX01L45 logcat -d -t 100 | findstr /i "DISCOVERY URGENT NOTIFY recovery"
adb -s 8AKX0UCPK logcat -d -t 100 | findstr /i "DISCOVERY URGENT NOTIFY recovery"
curl -s http://127.0.0.1:18081/peers
curl -s http://127.0.0.1:18082/peers
# BT power-cycle if wedged:
adb -s 88LX01L45 shell svc bluetooth disable; adb -s 8AKX0UCPK shell svc bluetooth disable
sleep 3
adb -s 88LX01L45 shell svc bluetooth enable; adb -s 8AKX0UCPK shell svc bluetooth enable
```

---

## Common pitfalls

- **API unreachable** — app not launched, `ENABLE_STRESS_TEST_API` false, or port forward missing/stale (`adb forward --list`)
- **`/ui` stuck at revision 0** — chat UI never painted (still loading / crash); check Flutter logcat
- **DB has message, UI doesn’t** — compare `/messages` vs `/ui`; that’s intentional for catch UI lag
- **Blackout on one path in stress report** — BLE permissions, radio stall, or GATT slot exhaustion → `/reset_ble`
- **Wrong port** — device order changed; re-run `deploy.py` or check `adb forward --list`
- **Probe script bogus 1/30** — ensure result/recording lines are **inside** the `for i in range(n)` loop in `probe_5s.py`
- **Mid-batch `/reset_ble`** — causes cascade failures; reset only at batch start
- **`/has_message` 404** — deploy latest APK (endpoint added in uncommitted work)

## Related source

- API server: `lib/services/api_service.dart`
- UI snapshot: `lib/services/ui_debug_snapshot.dart` (reported from `lib/screens/home_screen.dart` after paint)
- Mesh sync / merge: `lib/providers/ble_network_provider.dart`
- Discovery: `lib/services/ble_discovery_service.dart`
- Native stack: `android/app/src/main/kotlin/com/example/bluetooth_app/MainActivity.kt`
