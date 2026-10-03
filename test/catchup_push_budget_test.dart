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

  test('peers have separate budgets', () {
    final budget = CatchupPushBudget(limit: 1);
    expect(budget.tryUse('a'), isTrue);
    expect(budget.tryUse('b'), isTrue);
    expect(budget.tryUse('a'), isFalse);
  });

  test('a changed bucket report refills the budget', () {
    final shared = CatchupPushBudget.shared;
    BleDiscoveryService.rememberPeerBuckets('p', [1, 2, 3]);
    while (shared.tryUse('p')) {}

    BleDiscoveryService.rememberPeerBuckets('p', [1, 2, 3]);
    expect(shared.tryUse('p'), isFalse, reason: 'same report, nothing new');

    BleDiscoveryService.rememberPeerBuckets('p', [1, 2, 4]);
    expect(shared.tryUse('p'), isTrue);
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
}
