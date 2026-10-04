import 'package:bluetooth_app/services/ble_discovery_service.dart';
import 'package:bluetooth_app/services/catchup_push_budget.dart';
import 'package:bluetooth_app/services/deep_catchup.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(() {
    CatchupPushBudget.shared.clear();
    DeepCatchup.reset();
    BleDiscoveryService.lastKnownPeerBuckets.clear();
  });

  test('pages run out after the limit', () {
    final budget = CatchupPushBudget(limit: 3);
    expect(budget.tryUse('p'), isTrue);
    expect(budget.tryUse('p'), isTrue);
    expect(budget.tryUse('p'), isTrue);
    expect(budget.tryUse('p'), isFalse);
    expect(budget.remaining('p'), 0);
  });

  test('burst limit yields after consecutive pages and resets on resetBurst', () {
    final budget = CatchupPushBudget(limit: 10, burstLimit: 3);
    expect(budget.shouldYieldBurst('p'), isFalse);

    // Page 1
    expect(budget.tryUse('p'), isTrue);
    expect(budget.currentBurst('p'), 1);
    expect(budget.shouldYieldBurst('p'), isFalse);

    // Page 2
    expect(budget.tryUse('p'), isTrue);
    expect(budget.currentBurst('p'), 2);
    expect(budget.shouldYieldBurst('p'), isFalse);

    // Page 3: reaches burst limit
    expect(budget.tryUse('p'), isTrue);
    expect(budget.currentBurst('p'), 3);
    expect(budget.shouldYieldBurst('p'), isTrue);

    // After yielding, resetBurst clears the burst counter while retaining overall budget
    budget.resetBurst('p');
    expect(budget.currentBurst('p'), 0);
    expect(budget.shouldYieldBurst('p'), isFalse);
    expect(budget.remaining('p'), 7);

    // Second burst can proceed
    expect(budget.tryUse('p'), isTrue);
    expect(budget.currentBurst('p'), 1);
  });

  test('peers have separate budgets and burst counters', () {
    final budget = CatchupPushBudget(limit: 5, burstLimit: 2);
    expect(budget.tryUse('a'), isTrue);
    expect(budget.tryUse('a'), isTrue);
    expect(budget.shouldYieldBurst('a'), isTrue);
    expect(budget.shouldYieldBurst('b'), isFalse);

    expect(budget.tryUse('b'), isTrue);
    expect(budget.currentBurst('b'), 1);
  });

  test('a changed bucket report refills the budget and resets burst', () {
    final shared = CatchupPushBudget.shared;
    BleDiscoveryService.rememberPeerBuckets('p', [1, 2, 3]);
    while (shared.tryUse('p')) {}

    BleDiscoveryService.rememberPeerBuckets('p', [1, 2, 3]);
    expect(shared.tryUse('p'), isFalse, reason: 'same report, nothing new');

    BleDiscoveryService.rememberPeerBuckets('p', [1, 2, 4]);
    expect(shared.tryUse('p'), isTrue);
    expect(shared.currentBurst('p'), 1);
  });

  test('a changed whole-history hash refills the budget', () {
    final shared = CatchupPushBudget.shared;
    DeepCatchup.remember('p', const PeerDeepDigest(10));
    while (shared.tryUse('p')) {}

    DeepCatchup.remember('p', const PeerDeepDigest(10));
    expect(shared.tryUse('p'), isFalse);

    DeepCatchup.remember('p', const PeerDeepDigest(11));
    expect(shared.tryUse('p'), isTrue);
  });

  test(
    'prevents 10-minute stall: 20-page budget halts circular push thrashing when peer repeats identical fingerprints',
    () {
      final shared = CatchupPushBudget.shared;
      const phoneB = 'phone-b';
      final staleBuckets = List<int>.generate(32, (i) => i * 17);

      // Simulate Phone A receiving the exact same fingerprint over 21 consecutive iterations.
      for (var iteration = 1; iteration <= 21; iteration++) {
        BleDiscoveryService.rememberPeerBuckets(phoneB, staleBuckets);

        if (iteration <= 20) {
          expect(
            shared.tryUse(phoneB),
            isTrue,
            reason: 'Iteration $iteration: push permitted within 20-page budget',
          );
        } else {
          // On iteration 21 (after 20 pages used), the budget halts further pushes
          // and forces the link to go quiet so Phone B's request for fresh fingerprints can be sent.
          expect(
            shared.tryUse(phoneB),
            isFalse,
            reason:
                'Iteration $iteration: budget must halt further pushes to prevent link starvation',
          );
          expect(shared.remaining(phoneB), 0);
        }
      }

      // Phone B's request for fresh state finally gets through the quiet link:
      final freshBuckets = List<int>.generate(
        32,
        (i) => i * 17 + (i == 0 ? 1 : 0),
      );
      BleDiscoveryService.rememberPeerBuckets(phoneB, freshBuckets);

      // Pushes resume once fresh fingerprints are reported
      expect(
        shared.tryUse(phoneB),
        isTrue,
        reason: 'Budget refills once peer reports updated fingerprints',
      );
      expect(shared.remaining(phoneB), 19);
    },
  );
}
