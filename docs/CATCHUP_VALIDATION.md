# Pixel 3 catch-up and benchmark receipts

The next controlled checks use the Android 9 and Android 15 Pixel 3s only. Original app identities and chats stay separate; database gap injection now targets only `com.bregger.edison.meshenger.benchmark`.

## Receipt accounting

The stress runner defaults to `/messages` and matches the IDs returned by `/send`. Its record survives subsequent page changes and API outages; an unsuccessful poll does not tighten a receipt's observation interval. A send that failed to return an ID can still be checked by its unique benchmark tag, with its send API error recorded separately. These are database receipts, not evidence of decryption, rendering or reading.

`--receipt-source ui` explicitly selects the UI projection. Chat clearing no longer forces unbounded rendering; the runner requests an unbounded page only in UI mode, including retained-history runs. The selected receipt source and paging configuration are recorded in each summary. Earlier UI-observed measurements retain their original meaning and are not a paired comparison with the new database measurements.

On Android 9, switching the debug API's chat setting from unbounded to bounded changed its UI snapshot from 1,162 messages to 200 while preserving all 1,163 database message IDs and the node identity. Flutter analysis is clean; all 152 Flutter tests and 72 Python tooling tests pass. Regression tests cover exact IDs, duplicate text, blank cleared rows, remembered receipts, failed polls, all 1,000 receipts beyond a UI page, copying writes that exist only in SQLite's WAL, and rejecting a failed gap injection.

## Controlled history checks

The gap harness verifies equal starting message IDs rather than equal counts. It backs up the stopped disposable database, checkpoints copied WAL writes, removes the selected live shared-room rows, and measures recovery of those exact baseline IDs. Startup/discovery time is included. Unrelated rows cannot replace missing receipts in its pass criterion.

Planned checks, using one fixed APK and two-phone topology:

1. Seed 1,500 shared messages, beyond the 1,024-row recent window, and verify equal IDs on both phones.
2. Remove 300 oldest rows on one phone, measure whole-history repair, and repeat with the other phone lagging.
3. Check a larger/scattered gap and trace BLE waits, retries and repair pages if recovery stalls.
4. Run 1,000 messages with `--preserve-messages` while the UI remains bounded.

```text
python stress_test.py --messages 1500 --devices 88LX01L45,8AKX0UCPK --details-file build/catchup-20261004/seed-1500.log --summary-json build/catchup-20261004/seed-1500.json
python -m tools.gap_catchup --devices 88LX01L45,8AKX0UCPK --lagging 8AKX0UCPK --gap 300 --mode oldest --summary-json build/catchup-20261004/oldest-android15.json
python stress_test.py --messages 1000 --preserve-messages --devices 88LX01L45,8AKX0UCPK --details-file build/catchup-20261004/retained-1000.log --summary-json build/catchup-20261004/retained-1000.json
```

Paired physical runs remain pending: Android 15's USB transport repeatedly stalled, including ordinary ADB commands, despite reconnecting and restarting. Its failed seed preflight sent no timed messages. Wireless debugging is being arranged. The compact [validation record](benchmarks/catchup-20261004.json) distinguishes completed tooling checks from pending physical runs.

Long unplugged Doze, battery restrictions, non-Pixel OEMs and Android 12/12L remain separate publication gates. No release or tag has been published.
