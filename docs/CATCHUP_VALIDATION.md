# Pixel 3 catch-up and benchmark receipts

These controlled checks use the Android 9 and Android 15 Pixel 3s only. Original app identities and chats stay separate; database gap injection targets only `com.bregger.edison.meshenger.benchmark`.

## Receipt accounting

The stress runner defaults to `/messages` and matches the IDs returned by `/send`. Its record survives subsequent page changes and API outages; an unsuccessful poll does not tighten a receipt's observation interval. Successful absent polls bound delivery from request start, because a slow response may finish after the message arrives. A send that failed to return an ID can still be checked by its unique benchmark tag, with its send API error recorded separately. These are database receipts, not evidence of decryption, rendering or reading.

`--receipt-source ui` explicitly selects the UI projection. Chat clearing no longer forces unbounded rendering; the runner requests an unbounded page only in UI mode, including retained-history runs. The selected receipt source and paging configuration are recorded in each summary. Earlier UI-observed measurements retain their original meaning and are not a paired comparison with the new database measurements.

On Android 9, switching the debug API's chat setting from unbounded to bounded changed its UI snapshot from 1,162 messages to 200 while preserving all 1,163 database message IDs and the node identity. Flutter analysis is clean; all 161 Flutter tests and 73 Python tooling tests pass. Regression tests cover exact IDs, duplicate text, blank cleared rows, remembered receipts, failed and slow polls, all 1,000 receipts beyond a UI page, copying writes that exist only in SQLite's WAL, and rejecting a failed gap injection.

## Profile repair correction

Three additional database tests reproduced a profile repair defect before the fix and pass afterward. Recent and whole-history fingerprints used the CRDT writer's `node_id` for profiles rather than the profile's primary key, `mesh_node_id`. Two missing profiles from one writer could cancel in the XOR digest even when the receiver already knew that writer's latest clock. Fetching one selected writer ID could also return every profile written by that node, exceeding the repair row budget.

Both digests, selected-row lookup and rotating hash-repair ordering now use `mesh_node_id` for profiles. The tests restore two missing profiles one row at a time through each digest path and verify the one-row budget with three profiles from one writer. This changes profile fingerprint semantics; paired checks must use the same APK on both phones. It does not change the database schema, stored identities or keys. It has not been established as the cause of the earlier slow message benchmark, and no performance improvement is claimed without paired measurements.

## Older-history scheduling correction

The first traced Android 9 oldest-gap run restored all 300 rows in 138.2 seconds, but no missing rows appeared until 101.4 seconds. Its deep digest took only 58 ms to compute. Recent-message hashes agreed, so normal discovery could wait for the 90-second anti-entropy interval; a digest computed before neighbor discovery had no later initial-probe trigger.

Neighbor presence refresh now starts that probe and retries deferred deep repair. A cooldown, active outbound transfer, recent local write or missing fresh address no longer consumes a probe or round. Existing inbound links use the separate streaming page budget; an empty active-link check does not consume an outbound deep round. Only accepted outbound requests count against the existing three-round no-progress cap, and restarting a mesh session clears stale deep peer/probe state. The first ordinary offer also includes its already-computed deep bucket fingerprints, allowing the first reply to repair old rows. Later converged offers return to hash-only metadata. Urgent new-message offers retain their existing payload.

The intermediate variants still stalled: one repeat spent its rounds on existing inbound-link checks before the peer had the bucket information required for repair. Those measurements remain in the validation record. With the complete correction, Android 9's first missing rows appeared at 12.1 seconds and all 300 were restored at 25.6 seconds. Android 15 completed the same gap at 26.1 seconds. These are controlled case improvements, not evidence of a general live-message speedup or a new FlutterBluePlus before/after comparison.

## Controlled history checks

The gap harness verifies equal starting message IDs rather than equal counts. It backs up the stopped disposable database, checkpoints copied WAL writes, removes the selected live shared-room rows, and measures recovery of those exact baseline IDs. Startup/discovery time is included. Unrelated rows cannot replace missing receipts in its pass criterion. Backup filenames also support wireless ADB device addresses on Windows.

The baseline APK used source `0e20c9b`; the corrected APK uses `bd4e99b`. Both phones use the same APK within each run. The 1,500 exact baseline message IDs are retained across gap trials. Android 9 uses USB ADB; Android 15 uses wireless ADB for all these measurements. BLE carries the messages. The app PID trace collectors add some control traffic; gap polling is every three seconds.

The seed delivered all 1,500 shared messages, beyond the 1,024-row recent window, in 374.58 seconds. Database-observed mean latency was 2.308 seconds, p95 4.660 seconds and maximum 55.050 seconds. There were zero send API errors, one runner-reported connection failure and zero scanner errors. Internal native attempts logged one missing characteristic, one transfer timeout and one write failure; those are a different count from the runner's connection failures. Android 15 was connected to USB power during the seed at 02:24:52 UTC on October 5. No paired live-message performance claim is made from this seed.

| Gap | Baseline completion | Corrected completion |
| --- | --- | --- |
| Android 9 missing 300 oldest rows | 138.2 s | 25.6 s |
| Android 15 missing 300 oldest rows | 56.8 s | 26.1 s |
| Android 9 missing 700 scattered rows | 141.8 s | 121.5 s |

Each completed trial restored every exact removed ID and preserved the complete phone's history. Times include app restart, discovery and receipt polling. These are sequential physical runs, not randomized repetitions or precise radio delivery times.

## Retained-history 1,000-message run

All 1,000 new messages arrived in 290.58 seconds with zero send API errors, zero inbound rejections and zero scanner errors. Both phones held every one of the 2,500 expected live IDs afterward, while each UI snapshot contained only 200 messages. Their node identities were unchanged. This physically verifies receipt accounting beyond the UI page.

Latency was not a clean result: median 2.226 seconds, mean 29.097 seconds, p95 215.857 seconds and maximum 235.803 seconds. Three native/runner connection failures were recorded: two service-discovery transfer timeouts and one connect timeout. The API submit stage averaged 0.177 seconds and never exceeded 0.820 seconds; observation windows averaged 2.005 seconds and never exceeded 3.752 seconds. API submission or polling resolution therefore does not explain the multi-minute tail.

156 messages took over 30 seconds, split equally between senders. The worst was submitted at 51.69 seconds and observed at 287.49 seconds; the send burst ended at 277.26 seconds. Both apps were confirmed foreground and awake during the run. Traces and the existing newest-row priority during a burst point to missed early rows waiting for catch-up after the burst quiets down. That scheduling explanation is an inference; a controlled fault-injection repeat is needed before choosing a live-traffic fairness change. Burst recovery after connection failures remains a release performance concern. No live-message speedup is claimed from this run.

```text
python stress_test.py --messages 1500 --devices 88LX01L45,8AKX0UCPK --details-file build/catchup-20261004/seed-1500.log --summary-json build/catchup-20261004/seed-1500.json
python -m tools.gap_catchup --devices 88LX01L45,8AKX0UCPK --lagging 8AKX0UCPK --gap 300 --mode oldest --summary-json build/catchup-20261004/oldest-android15.json
python stress_test.py --messages 1000 --preserve-messages --devices 88LX01L45,8AKX0UCPK --details-file build/catchup-20261004/retained-1000.log --summary-json build/catchup-20261004/retained-1000.json
```

## Android 15 API recovery

Android 15 runs LineageOS 22.1 (API 35). Its disposable benchmark app UID had network policy `262144` (`REJECT_ALL`), blocking even its loopback HTTP listener. A listener existed at `127.0.0.1:8080`, but a local connection timed out; another local port was reachable. Clearing only that UID's policy to zero immediately restored HTTP 200 with the existing node identity. USB echo and a separately forwarded USB API request then succeeded too. This establishes the app API failure cause; it does not isolate every earlier USB symptom.

After the signed-to-debug APK update in the background check, the same UID policy was again `262144`. API requests then timed out and both USB and wireless shell commands stalled. Removing the test forwards and letting the blocked connections expire restored shell access. Clearing the benchmark UID policy before another HTTP request immediately restored the API again. Debug declares `INTERNET`; release does not. Future signed-to-debug test updates on this phone must check that UID policy before forwarding an API request. No production network permission has been added.

The original benchmark UID policy `262144` was restored after these completed checks, with the test API forwards removed. A future API run must clear that test-app block before opening a forwarded connection. Both ordinary screen timeouts and charging stay-awake settings match their original values; neither phone remains forced idle. Debug APKs are installed on both phones. ADB 37.0.1 was used from an isolated temporary directory; the user's existing platform-tools installation was not replaced. Original app data, keys and device identities were preserved. Raw diagnostic dumps and app traces stay in gitignored `build/catchup-20261004/`; the compact [validation record](benchmarks/catchup-20261004.json) contains shareable results and artifact identities.

## Signed background and forced-idle checks

The corrected release-key-signed, non-debuggable APK was installed on Android 15, with Android 9's debug API as sender. The signed receiver stayed behind Home for five minutes; the final two minutes used Android's [forced idle test](https://developer.android.com/training/monitoring-device-state/doze-standby#testing_doze). It was not exempted from battery optimization, its foreground service stayed active, and it held no debug partial wake lock. Three messages were sent before forced idle and two during it. All five exact IDs had signed-receiver `MERGED` traces before idle exit and persisted afterward, verified through the debug API after connection recovery. All 2,500 prior live IDs and the node identity were preserved.

Both forced-idle snapshots reported `IDLE`; the display started on, and PowerManager reported `Dozing` by the end. Android 15 enforces a device-admin maximum screen timeout of five minutes, which overrode the temporary 30-minute ordinary timeout. No administrator setting was changed. The phone was PIN-locked after the test. Its ordinary five-minute timeout and normal idle mode were restored. This is a controlled forced-idle check while USB remained connected, not natural long unplugged Doze or a battery-drain measurement. Database merge traces do not establish decrypted UI display.

The reverse signed Android 9 receiver check is pending Android 15 being unlocked so its debug sender can regain foreground location access. ADB transport has recovered, and the API was verified after clearing the network policy; the original test-app block is now restored until testing resumes. No additional cable change or Wireless debugging toggle is needed.

The corrected code passed [hosted CI](https://github.com/ebregger/Meshenger/actions/runs/37258781780), including Flutter analysis, 161 Flutter tests, the debug APK build, 9 Kotlin tests, release lint and 73 Python tooling tests. Both isolated debug and release APKs have verified package IDs and release-key signatures; their exact hashes are in the validation record.

Long unplugged Doze, battery restrictions, non-Pixel OEMs and Android 12/12L remain separate publication gates. No release or tag has been published.
