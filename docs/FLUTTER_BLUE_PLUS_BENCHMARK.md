# FlutterBluePlus before/after benchmark

October 4, 2026: removing FlutterBluePlus preserved delivery in this foreground two-phone test. The fresh-data pair shows a small observed timing improvement, not a demonstrated causal speedup. APK size fell independently of the timing result.

| Measurement | FlutterBluePlus | Native discovery |
| --- | ---: | ---: |
| Messages delivered | 1,000/1,000 | 1,000/1,000 |
| Total elapsed | 173.95 s | 172.15 s |
| Effective throughput | 5.749/s | 5.809/s |
| Mean observed latency | 1.628 s | 1.592 s |
| Median observed latency | 1.539 s | 1.548 s |
| p95 observed latency | 3.433 s | 2.998 s |
| Maximum observed latency | 6.142 s | 4.466 s |
| Send API errors | 10 | 8 |
| Connection failures | 0 | 0 |
| Inbound connection rejections | 2 | 0 |
| Scanner errors | 0 | 0 |
| Signed universal APK bytes | 62,204,108 | 61,833,996 |

Elapsed time fell by 1.03%, mean latency by 2.21%, and p95 by 12.66% in this pair. The universal release APK is 370,112 bytes (0.60%) smaller. This burst workload is paced by HTTP requests and a 100 ms send interval, so effective throughput is not the radio's maximum throughput.

## Setup and reproducibility

- Pixel 3 Android 9/API 28 (`88LX01L45`) and Pixel 3 Android 15/API 35 (`8AKX0UCPK`). Both unlocked, plugged in, with the debug activity foregrounded to keep the screen awake. The optional CPU wake lock was off. Charging stay-awake settings stayed at their original values, 7 and 0.
- Both variants use the isolated `com.bregger.edison.meshenger.benchmark` application ID. Force-stop all other Meshenger installations on both phones before either run. Clear **only this disposable package's data** before each variant, grant the required permissions, launch it, and wait for the stress API. Fresh identities are generated after each clear.
- Baseline source: `8062bec`, plus the optional benchmark ID suffix. Native source: the removal change committed with this report. Existing GATT transport, mesh scheduling, payload limits and CRDT behavior are shared.
- 1,000 messages, alternating senders (500 each), `burst`, 100 ms minimum send interval and 2 s UI polling. Coordinated BLE reset and fresh-peer preflight precede the timed workload. Delivery means every message appeared on the receiving phone's debug UI snapshot, not merely a successful send response.
- Build a normal debug APK with Flutter, then run `gradlew.bat :app:assembleDebug -PmeshengerBenchmark=true` in `android/` to produce the isolated APK. Confirm the packaged ID before installing. Do not use the stress runner's production database-wipe helper for isolation.

```text
python stress_test.py --messages 1000 --profile burst --send-interval-s 0.1 --poll-interval-s 2 --devices 88LX01L45,8AKX0UCPK --details-file build/flutterblueplus-benchmark/before.log --summary-json build/flutterblueplus-benchmark/before.json
```

Repeat with the native APK and `after` output paths, after clearing the disposable app's data on both phones again. The [compact machine-readable record](benchmarks/flutterblueplus-20261004.json) retains measurements, metadata, APK hashes and raw-summary hashes. Full logs, JSON traces and debug APKs are local, gitignored files in `build/flutterblueplus-benchmark/`.

## Reliability and interpretation

Both variants triggered the existing CRDT assertion `hlc >= canonicalTime` in concurrent debug writes/merges. SQL writes can persist before this assertion raises, explaining complete delivery despite send API errors. These are not clean send-API runs. Clock publication ordering remains a first-release gate; removal did not fix it.

There is one fresh-data run per variant, sequentially rather than randomized. The mean confidence intervals overlap; normal-approximation intervals assume independent samples, whereas BLE delivery is correlated within a run. Two-second polling is coarser than the observed mean improvement. Repeated randomized pairs and CPU/memory/battery measurements are needed to establish an overhead reduction. These results cover two Pixel phones in the foreground, not three-phone relaying, other OEMs or background/Doze behavior.

Earlier trials are retained rather than hidden. The first pair had another Meshenger instance running on Android 15 and is excluded. Original app identities/data were never cleared; that extra instance may have received public test traffic. A subsequent pair stopped other apps but used `/clear_messages`, which retains CRDT tombstones rather than producing empty databases. With unequal accumulated history, the native trial needed 228.27 s overall and averaged 97.90 s observed delivery latency, versus 172.09 s and 1.68 s before removal. All 1,000 eventually arrived in both trials. Retained-history catch-up needs separate investigation; these trials cannot isolate discovery overhead. The final pair above corrects both setup problems.

After the timed runs, the native Bluetooth-enable UI opened Android's confirmation dialogs on both Android 9 and 15. Allowing them restored adapter state and fresh peer scan observations; native GATT acknowledged transfers after recovery. No release or tag was published.
