# Meshenger

Meshenger is a nearby chat app for Android. Phones discover one another over Bluetooth Low Energy (BLE) and exchange chat history directly, without Wi-Fi, mobile data, or a central server.

## Download

When a release is available, download Meshenger from the [GitHub Releases page](https://github.com/ebregger/Meshenger/releases). Choose the **universal APK** for most Android phones. The other APKs are split by processor type. Download only from the project’s Releases page.

## How the mesh works

Each phone is an equal participant in the mesh. It keeps its own local copy of the chat and continuously looks for nearby Meshenger phones while Bluetooth is available.

When a phone finds a peer, the two compare compact fingerprints of their local data. If the fingerprints differ, they connect over BLE and exchange the records each side is missing. Both phones merge the received records into their local chat. The conversation can therefore catch up in either direction.

Messages can travel across multiple phones through repeated exchanges. For example, if A can reach B and B can reach C, A’s message can reach C when C syncs with B. B stores and shares the same chat history; it does not route a live packet to a specific destination. Phones do not need to be on the same Wi-Fi network.

```mermaid
flowchart LR
    A[Phone A sends a message] -->|BLE sync| B[Phone B saves and shares it]
    B -->|BLE sync when in range| C[Phone C receives it]
```

Sync happens when nearby phones discover one another and have an opportunity to connect. It is not guaranteed to be immediate, especially when phones are out of range, Bluetooth permissions are unavailable, or Android restricts background activity.

## Privacy

Meshenger has no central server, but the current mesh traffic is **not encrypted**. Messages, user IDs, and display names are sent as readable data over Bluetooth. Nearby people with suitable BLE tools may be able to capture that traffic, even if they do not use Meshenger. Treat the shared chat as public to people within radio range. Do not send sensitive information.

## Screenshots

<p align="center">
  <img src="docs/screenshots/messages-and-peers.png" alt="Meshenger Messages screen with a sample conversation and nearby peers" width="360">
</p>

## Get started

1. Install the APK on two or more Android phones.
2. Turn on Bluetooth and allow the requested nearby-device permissions.
3. Open Meshenger on each phone and keep the screens on while trying the first sync. Debug builds keep the screen awake while Meshenger is in the foreground; release builds follow the phone's normal screen timeout.
4. Send a sample message. Nearby peers should appear as chips, and the message should arrive as the phones sync.

The **Messages** tab contains the shared conversation and nearby peers. Tap a peer chip to see its details. The **Configuration** tab lets you set a display name, check permissions and radio diagnostics, and restart the mesh radio if discovery or syncing stalls.

## Current capabilities

- Android app with BLE peer discovery and direct phone-to-phone data exchange.
- Shared chat history that syncs and merges across peers, including through a phone that is in range of both sides.
- Display names, peer presence indicators, sync status, and basic radio diagnostics.

Keep the app open and phones nearby while evaluating sync. Android background and battery limits can interrupt scanning or connections when the app is not in use.

## BLE stress baseline

On 2026-09-24, the three-phone stress test sent 300 messages round-robin (100 from each phone), after clearing prior chat rows. It measured completion when each message appeared in the other phones' `/ui` chat lists, polling about every two seconds. ADB controlled the apps; BLE carried the phone-to-phone sync. Debug builds now set `FLAG_KEEP_SCREEN_ON` while Meshenger is open, so Android does not dim or sleep the screen during foreground test runs.

| Run | Delivery | Mean / p50 / p95 / max latency | Throughput | Connection failures / penalty entries |
| --- | --- | --- | --- | --- |
| Earlier 300-message run | 300/300 in 268.77s | 60.18s / 21.92s / 239.48s / 259.71s | 1.12 msg/s, 1.91 KB/s | 74 / 67 |
| Debug-awake repeat | 300/300 in 1,009.92s | 189.61s / 72.40s / 736.36s / 977.10s | 0.30 msg/s, 1.65 KB/s | 201 / 178 |

Both runs delivered all 100 messages across each of the six sender-to-peer paths. The debug-awake repeat's worst six latency outliers (933–977s) came from the API 35 Pixel 3 sender; logs also show repeated inbound-cap connection rejections. The large run-to-run spread means these results are an initial, noisy baseline, not evidence that the keep-awake flag changed BLE performance. Device spacing was not measured, so this is not a distance or radio-range benchmark.

For the debug-awake repeat, the host-observed mean latency was 189.61s with a normal-approximation 95% interval of 161.66–217.55s (±27.94s, n=300, sample SD 246.92s). The completion times share the same BLE session and are correlated, so this interval is only a rough within-run estimate; independent repeated runs or block-based analysis are needed for a defensible confidence bound. At the observed spread, estimating the mean to ±2s would take about 58,600 independent messages, and ±1s about 234,300. At the observed throughput that is approximately 2.3–9 days of continuous traffic, before accounting for correlation. The requested ±0.01s would require about 2.34 billion independent messages and is not a practical target for this setup.

Run the general benchmark with `python stress_test.py --messages 300`. It clears old chat rows by default so receipt counts stay consistent. The detailed `.log` output is ignored by Git; the measurements above are recorded here.

## Planned work

- Keep BLE scanning and connections active more reliably in the background with an Android foreground service.
- Show local notifications for incoming messages.
- Decide and implement a stronger privacy model, including encryption if private conversations are needed.
- Add chat history clearing and retention controls.
- Support direct one-to-one conversations.
- Add message timestamps, copy actions, and clearer delivery progress.
- Configure release signing with a consistent release keystore.
