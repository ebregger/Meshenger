# Bluetooth Mesh Chat

A peer-to-peer chat app that syncs messages over Bluetooth Low Energy — no Wi‑Fi or cellular required. Nearby phones form a small mesh and share chat history automatically.

Building or debugging the project? See **[DEVELOPMENT.md](DEVELOPMENT.md)**.

---

## What you need

- An Android phone (API 24 / Android 7 or newer)
- Bluetooth turned on
- Nearby Devices / Bluetooth permissions allowed when prompted  
  (on older Android, Location may also be required for BLE scanning)

Install the app on two or more phones that are near each other. Each phone is one node in the mesh.

---

## How the mesh works

Every phone runs the same app. There is **no server phone**. Messages live in a local **CRDT database** on each device; Bluetooth is only used to exchange missing pieces until everyone’s database fingerprint matches.

Important correction vs a classic “relay packet” mesh:

> Phones do **not** forward chat messages as packets to a destination.  
> They **merge database rows**. Multi-hop means: A updates B’s DB → B’s advertised fingerprint changes → C notices B diverged and syncs with B → C merges the same rows A originally wrote.

---

### 0. Session start (once Bluetooth is on)

On each phone, when the mesh session starts:

```mermaid
flowchart TD
  BT[Bluetooth adapter ON] --> ID[Load stable node id]
  ID --> HASH[Hash local CRDT database]
  HASH --> ADV[Start GATT server + advertise<br/>12-byte payload: 8-byte DB hash + 4-byte id prefix]
  ADV --> SCAN[Start continuous BLE scan]
  SCAN --> HOOK[Hook local chat writes → urgent sync]
  HOOK --> TICK[Periodic neighbor / presence refresh]
```

After that, advertise + scan run continuously until Bluetooth drops or you restart the mesh radio.

---

### 1. Continuous jobs on every phone

```mermaid
flowchart TB
  subgraph advertise [Advertise - always]
    A1[Primary ad: mesh service UUID + short telemetry]
    A2[Scan response: MESH magic + full 8-byte DB hash + id prefix]
    A3[When DB changes: recompute hash and refresh advertisement]
  end

  subgraph scan [Scan - always]
    S1[Hear nearby mesh advertisements]
    S2[Ignore self]
    S3[Record peer sighting + dialable BLE address]
    S4{Remote DB hash == my hash?}
    S4 -->|Yes| S5[Mark peer caught up]
    S4 -->|No| S6[Mark peer behind]
    S5 --> S7{Need dial?<br/>unknown identity / stale anti-entropy / behind}
    S6 --> S7
    S7 -->|Yes| S8[Queue outbound sync handshake]
    S7 -->|No| S9[Keep listening]
  end

  subgraph presence [Presence / chips]
    P1[Direct clock: recent radio contact]
    P2[Gossip clock: heard about via another peer's sync]
    P3[Topology map: who listed whom as neighbors]
    P1 --> P4[Green = direct]
    P2 --> P5[Yellow = indirect if a green bridge exists]
    P3 --> P5
    P1 --> P6[Grey = known but quiet]
  end
```

What the scan path also enforces (kept because it changes behavior):

- If **any dialable peer is known behind**, do **not** spend the outbound radio on a peer already marked caught up.
- After a local write, scan briefly yields so **urgent push-on-write** can use the radio first.
- For idle “we match but haven’t talked in a while” anti-entropy, only one side dials (node-id prefix election) so both phones don’t connect at once.

Omitted from charts on purpose: cooldown timers, byte size caps, scanner watchdog intervals, lease millisecond formulas, log lines.

---

### 2. Send path (UI → radio) — exact order

```mermaid
sequenceDiagram
  actor You
  participant UI as Chat composer
  participant Chat as ChatActions.sendMessage
  participant DB as Local CRDT DB
  participant Net as Mesh session
  participant Disc as Discovery / urgent sync
  participant Radio as Native BLE GATT

  You->>UI: Tap Send
  UI->>Chat: sendMessage(text)
  Chat->>DB: upsertTextMessage
  Note over DB: Message is on this phone immediately
  Chat->>Net: onLocalCrdtWrite / onLocalDatabaseWrite

  Net->>Disc: markMeshStaleAfterLocalWrite<br/>(every known peer → behind)
  Net->>Net: bump peer-chip UI
  Net->>Disc: refresh local hash for comparisons
  Net->>Radio: schedule advertisement hash update
  Net->>Disc: requestUrgentSyncWithKnownPeers

  Disc->>Disc: Prefer peers with caught-up = false
  Disc->>Disc: Prefer live neighbors
  Disc->>Disc: Take one peer this wave

  alt Already have inbound link from that peer
    Disc->>Radio: NOTIFY newest missing rows over existing link
  else Need outbound
    Disc->>Radio: Connect using scan-fresh address
    Disc->>Radio: Send compressed offer
  end
```

`onLocalDatabaseWrite` does all of: mark peers behind, refresh comparison hash, update ADV, **and** start urgent sync. A separate DB watcher also refreshes ADV on message/profile changes, but **only the chat write hook** triggers urgent push (so inbound merges don’t stampede the radio).

---

### 3. Sync handshake (what “connect” actually exchanges)

Wire format over GATT: **zlib-compressed JSON**, chunked until an EOF marker.

#### Initiator → offer

```mermaid
flowchart TD
  DIAL[Dial peer / reuse held link] --> BUILD[Build offer envelope]
  BUILD --> F1[type = offer]
  BUILD --> F2[sender_id + sender_hash]
  BUILD --> F3[neighbors = who I currently see directly]
  BUILD --> F4[peer_hashes = timed fingerprints I know for others]
  BUILD --> F5[vector = my CRDT version vector]
  BUILD --> F6[fps_b = bucket fingerprints]
  BUILD --> F7[initiator_data = rows I think you lack<br/>newest / vector delta / bucket gap / repair]
  F1 --> SEND[Compress + sendPayload]
  F7 --> SEND
```

Sending an offer does **not** mark the peer caught up yet. Catch-up is decided after the reply / merge side finishes and hashes agree.

#### Receiver handles offer

```mermaid
flowchart TD
  EOF[GATT EOF → decompress JSON] --> TOPO[Update presence + topology<br/>sender is direct; listed neighbors are gossip-seen]
  TOPO --> GOS[Apply peer_hashes gossip<br/>newer timestamps win]
  GOS --> MER[Merge initiator_data into local CRDT]
  MER --> DELTA[Compute delta = rows they still lack from my DB]
  DELTA --> REPLY[Reply delta envelope:<br/>my hash, neighbors, peer_hashes, data]
  REPLY --> NOTIFY[NOTIFY reply over GATT]
  NOTIFY --> DONE{Hashes match and reply complete?}
  DONE -->|Yes| OK[markSyncComplete → peer caught up]
  DONE -->|No hash match| BAD[markSyncDiverged → peer behind]
```

#### Initiator handles delta reply

```mermaid
flowchart TD
  RCV[Receive delta] --> TOPO2[Presence + topology + gossip again]
  TOPO2 --> MER2[Merge data into local CRDT]
  MER2 --> CMP{Their sender_hash == my hash?}
  CMP -->|Yes| OK2[markSyncComplete]
  CMP -->|No| BAD2[markSyncDiverged + schedule hash repair]
  MER2 --> ADV2[If my DB hash changed → update advertisement]
```

So one successful sync is **bidirectional**: the offer can carry the sender’s new chat rows (`initiator_data`), and the delta can carry anything the other side still needs.

---

### 4. Catch-up icon state (code-backed)

```mermaid
stateDiagram-v2
  [*] --> Unknown
  Unknown --> CaughtUp: Scan sees matching hash\nor sync/gossip observation matches
  Unknown --> Behind: Scan sees mismatch\nor sync/gossip observation mismatches\nor local write marked mesh stale
  CaughtUp --> Behind: Local write markMeshStaleAfterLocalWrite\nor newer observation says hash differs
  Behind --> CaughtUp: Newer observation says hash matches\n(scan, completed sync, or gossip)
```

Sources that update this (all real):

| Source | Effect |
|--------|--------|
| Local chat send | All known peers marked **behind** |
| Scan ADV hash | Match → caught up; mismatch → behind |
| Finished sync hash check | Match → caught up; mismatch → behind |
| Gossip `peer_hashes` `{h, t}` | Same, but **only if `t` is newer** than what we already stored (stops stale loops) |

Gossip alone never moves message bodies — only fingerprints + neighbor lists for UI / dial priority.

---

### 5. How chips choose green / yellow / grey

```mermaid
flowchart TD
  ID[Known peer id] --> L{Recent direct radio contact?<br/>scan or GATT with that peer}
  L -->|Yes| G[Green - direct]
  L -->|No| N{Heard recently via gossip<br/>and a green peer bridges to them?}
  N -->|Yes| Y[Yellow - indirect<br/>show route via bridge]
  N -->|No| GR[Grey - disconnected tombstone<br/>if we still know their identity]
```

Gossip that feeds yellow chips: each offer/delta includes `neighbors`. The receiver stores “sender’s neighbor set” as mesh topology and marks those ids as network-seen. Routing for the chip is “find a direct neighbor who lists that peer,” not a separate routing protocol.

---

### 6. Multi-hop `A ↔ B ↔ C` — what the code actually does

Topology: A and C cannot hear each other. Both can hear B.

```mermaid
sequenceDiagram
  participant A as Phone A
  participant B as Phone B
  participant C as Phone C

  Note over A,C: Continuous advertise + scan on all three

  A->>A: User sends message
  A->>A: Save in CRDT + mark B,C behind
  A->>A: Urgent: pick one behind dialable peer (B)
  A->>B: Offer + initiator_data containing the new rows
  B->>B: Merge initiator_data
  B->>B: Chat UI updates
  B->>A: Delta reply (+ neighbors / peer_hashes gossip)
  A->>A: If hashes match → B caught up

  Note over B: B's DB hash changed. B does not auto-urgent<br/>just because of an inbound merge.

  C->>C: Scan hears B's new advertisement hash
  C->>C: Hash mismatch → mark B behind → dial B
  C->>B: Offer / sync
  B->>C: Rows C lacks include A's message
  C->>C: Merge → message appears
  C->>B: Delta reply
```

| Phone | Real responsibility |
|-------|---------------------|
| **A** | Origin write; urgent push to a behind neighbor (B). May never dial C. |
| **B** | Merges A’s rows into its own CRDT; advertises a new hash; gossip may tell A about C; later syncs with C when C (or anti-entropy) connects. |
| **C** | Discovers B’s hash divergence via scan (usual trigger) and pulls missing rows from B. |

If C later replies, the same mechanism runs C→B then A scans/syncs B.

---

### 7. End-to-end map (all phones)

```mermaid
flowchart TD
  subgraph always [Every phone always]
    ADV[Advertise hash + identity]
    SCN[Scan peers]
    UI[Peer chips from direct vs gossip presence]
  end

  subgraph onSend [Only on the phone that typed Send]
    W[Write CRDT row]
    STALE[Mark known peers behind]
    URG[Urgent sync: behind-first, one peer]
    OFF[Send offer + initiator_data]
  end

  subgraph onRecv [Phone that receives offer]
    M1[Merge initiator_data]
    R1[Reply delta + gossip]
    H1[Complete/diverge catch-up flags]
    ADV2[Refresh my advertisement hash]
  end

  subgraph hop2 [Next hop peer]
    SCN2[Sees new hash on advertisement]
    DIAL2[Dial because hashes diverge]
    M2[Merge missing rows]
  end

  ADV --- SCN --- UI
  W --> STALE --> URG --> OFF --> M1 --> R1 --> H1 --> ADV2
  ADV2 --> SCN2 --> DIAL2 --> M2
```

---

### 8. What “healthy” looks like

- Peers appear as chips (green/yellow/grey as above).  
- After sending, behind icons flip to check once fingerprints match again.  
- The same messages land in each phone’s chat (CRDT merge order can look briefly different).  

If catch-up sticks on sync-problem: peer out of range, radio wedged, or permissions — use **Restart Mesh Radio** / Bluetooth power cycle on Configuration.

---

## Getting around

The bottom bar has two tabs:

| Tab | What it’s for |
|-----|----------------|
| **Messages** | Chat with the mesh and see nearby peers |
| **Configuration** | Your display name, mesh identity, and radio diagnostics |

---

## Messages

1. Type in the composer at the bottom and tap **Send**.
2. Your message is stored on your phone and synced to nearby peers over Bluetooth.
3. Peers appear as chips along the top of the Messages screen.

### Peer chips

Chip **color** is connection status:

| Color | Meaning |
|-------|---------|
| Green | Direct Bluetooth link |
| Yellow | Reachable through another peer (multi-hop) |
| Grey | Known recently, but not currently reachable |

The **leading icon** is mesh sync status (same green / yellow / grey tint as connection):

| Icon | Meaning |
|------|---------|
| Check | This peer looks caught up with the mesh |
| Sync problem | This peer is behind (missing recent messages) |
| Help | Sync status not known yet |

Tap a chip for details: node ID, MAC (when known), connection path, and whether the mesh is caught up.

---

## Configuration

- **Mesh Identity** — your stable node ID (shared with the mesh; not the same as your display name).
- **Display Name** — what others see in chat. Leave empty to show a short form of your node ID.
- **Diagnostics** — Bluetooth, location, scanner health, and permission status.
- **Restart Mesh Radio** — rebuilds the mesh radio stack if peers stop appearing or sync stalls.
- **Turn Bluetooth Off and On** — full Bluetooth power cycle when the radio is wedged (may take a few seconds).

---

## Tips

- Keep phones unlocked and the app open (or recently used) while testing sync — background limits can slow discovery.
- After changing a display name, give the mesh a moment to propagate it.
- If chips never appear: confirm Bluetooth is on, permissions are granted, and try **Restart Mesh Radio**.
- Two phones can chat directly; a third phone can still receive messages through a middle peer when it is yellow.

---

## Privacy note

Traffic stays on the local Bluetooth mesh. There is no central chat server. Anyone in radio range who runs the app and joins the same mesh can receive shared messages and profiles.

---

## Platform support

- **Android** — supported today (API 24+).
- **iOS** — planned (not shipping yet).
- **Linux** and **web** — possible future targets; scaffolding may exist, but mesh chat is not productized there yet.

Windows and macOS desktop targets are not in scope and have been removed from the repo.
