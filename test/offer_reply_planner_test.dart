import 'dart:convert';

import 'package:bluetooth_app/services/ble_discovery_service.dart';
import 'package:bluetooth_app/services/offer_reply_planner.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> rows(String table, int count, {String prefix = 'r'}) => {
  table: [
    for (var i = 0; i < count; i++) {'id': '$prefix$i', 'hlc': '$i'},
  ],
};

class _Calls {
  final List<String> made = [];
  Map<String, dynamic> deep = {};
  Map<String, dynamic> window = {};
  Map<String, dynamic> hash = {};
  Map<String, dynamic> newest = {};

  Future<OfferReplyPlan> plan({
    Map<String, dynamic> delta = const {},
    bool deltaStalled = false,
    bool deepMismatch = false,
    PeerFingerprints fingerprints = PeerFingerprints.usable,
    bool windowDiffers = false,
  }) {
    return OfferReplyPlanner.plan(
      delta: delta,
      deltaStalled: deltaStalled,
      deepBucketsMismatch: deepMismatch,
      fingerprints: fingerprints,
      windowHashesDiffer: windowDiffers,
      deepRows: () async {
        made.add('deep');
        return deep;
      },
      windowRows: () async {
        made.add('window');
        return window;
      },
      hashRepairRows: () async {
        made.add('hash');
        return hash;
      },
      newestRows: () async {
        made.add('newest');
        return newest;
      },
    );
  }
}

void main() {
  group('OfferReplyPlanner.plan', () {
    test(
      'sends the version-vector delta and never scans for repairs',
      () async {
        final calls = _Calls()..newest = rows('messages', 2, prefix: 'n');
        final plan = await calls.plan(
          delta: rows('messages', 3),
          deepMismatch: true,
          windowDiffers: true,
        );

        expect(plan.source, OfferReplySource.versionVector);
        expect(plan.isRepair, isFalse);
        expect(plan.rowCap, OfferReplyPlan.normalRowCap);
        expect(calls.made, ['newest']);
      },
    );

    test('prefers whole-history buckets over window buckets', () async {
      final calls = _Calls()
        ..deep = rows('messages', 80, prefix: 'd')
        ..window = rows('messages', 5, prefix: 'w');
      final plan = await calls.plan(deepMismatch: true, windowDiffers: true);

      expect(plan.source, OfferReplySource.deepBuckets);
      expect(plan.fingerprintsComplete, isFalse);
      expect(plan.rowCap, BleDiscoveryService.repairPageRows);
      expect(calls.made, ['deep']);
      expect(OfferReplyPlanner.countRows(plan.delta), 80);
    });

    test(
      'falls back to window buckets when deep buckets find nothing',
      () async {
        final calls = _Calls()..window = rows('messages', 5, prefix: 'w');
        final plan = await calls.plan(deepMismatch: true, windowDiffers: true);

        expect(plan.source, OfferReplySource.windowBuckets);
        expect(plan.fingerprintsComplete, isTrue, reason: 'page was not full');
        expect(calls.made, ['deep', 'window']);
      },
    );

    test('a full window page leaves fingerprints incomplete', () async {
      final calls = _Calls()
        ..window = rows('messages', BleDiscoveryService.repairPageRows);
      final plan = await calls.plan(windowDiffers: true);

      expect(plan.fingerprintsComplete, isFalse);
    });

    test('peers without a fingerprint blob get a hash repair', () async {
      final calls = _Calls()..hash = rows('messages', 4, prefix: 'h');
      final plan = await calls.plan(
        fingerprints: PeerFingerprints.missing,
        windowDiffers: true,
      );

      expect(plan.source, OfferReplySource.hashRepair);
      expect(plan.fingerprintsComplete, isFalse);
      expect(calls.made, ['hash']);
    });

    test('an unreadable blob triggers no window or hash repair', () async {
      final calls = _Calls();
      final plan = await calls.plan(
        fingerprints: PeerFingerprints.unusable,
        windowDiffers: true,
      );

      expect(plan.isRepair, isFalse);
      expect(calls.made, ['newest']);
    });

    test('matching window hashes skip window and hash repairs', () async {
      final calls = _Calls();
      await calls.plan(windowDiffers: false);

      expect(calls.made, ['newest']);
    });

    test('repair replies do not repeat the newest rows', () async {
      final calls = _Calls()
        ..deep = rows('messages', 3, prefix: 'd')
        ..newest = rows('messages', 8, prefix: 'n');
      final plan = await calls.plan(deepMismatch: true);

      expect(calls.made, isNot(contains('newest')));
      expect(OfferReplyPlanner.countRows(plan.delta), 3);
    });
  });

  group('stalled deltas', () {
    test('a delta that goes out three times running is stalled', () {
      final tracker = StalledDeltaTracker();
      expect(tracker.record('peer', 7), isFalse);
      expect(tracker.record('peer', 7), isFalse);
      expect(tracker.record('peer', 7), isTrue);
      expect(tracker.record('peer', 7), isTrue);
    });

    test('a different delta starts the count again', () {
      final tracker = StalledDeltaTracker();
      tracker.record('peer', 7);
      tracker.record('peer', 7);
      expect(tracker.record('peer', 8), isFalse);
      expect(tracker.record('peer', 7), isFalse);
    });

    test('peers are counted separately and can be forgotten', () {
      final tracker = StalledDeltaTracker();
      tracker.record('a', 1);
      tracker.record('a', 1);
      expect(tracker.record('b', 1), isFalse);
      tracker.forget('a');
      expect(tracker.record('a', 1), isFalse);
    });

    test('repairs run before a stalled delta', () async {
      final calls = _Calls()..deep = rows('messages', 6, prefix: 'd');
      final plan = await calls.plan(
        delta: rows('messages', 25, prefix: 'v'),
        deltaStalled: true,
        deepMismatch: true,
        windowDiffers: true,
      );

      expect(plan.source, OfferReplySource.deepBuckets);
      expect(OfferReplyPlanner.countRows(plan.delta), 6);
    });

    test(
      'a stalled delta is still sent when no repair finds anything',
      () async {
        final calls = _Calls();
        final plan = await calls.plan(
          delta: rows('messages', 25, prefix: 'v'),
          deltaStalled: true,
          deepMismatch: true,
          windowDiffers: true,
        );

        expect(plan.source, OfferReplySource.versionVector);
        expect(OfferReplyPlanner.countRows(plan.delta), 25);
      },
    );

    test(
      'prevents 10-minute stall: circular 25-row push thrashing is detected and broken by switching to gap repair',
      () async {
        final calls = _Calls()
          ..deep = rows('messages', 80, prefix: 'gap')
          ..newest = rows('messages', 8, prefix: 'n');
        final delta25 = rows('messages', 25, prefix: 'stale');
        final tracker = StalledDeltaTracker(threshold: 3);

        const peer = 'phone-b';
        final deltaHash = jsonEncode(delta25).hashCode;

        // Iterations 1 & 2: delta is sent normally (25 delta + 8 newest = 33 rows)
        for (var i = 1; i <= 2; i++) {
          final isStalled = tracker.record(peer, deltaHash);
          expect(isStalled, isFalse, reason: 'Iteration $i is before threshold');
          final plan = await calls.plan(
            delta: delta25,
            deltaStalled: isStalled,
            deepMismatch: true,
            windowDiffers: true,
          );
          expect(plan.source, OfferReplySource.versionVector);
          expect(OfferReplyPlanner.countRows(plan.delta), 33);
        }

        // Iteration 3: 3rd consecutive identical delta trips stalled detector
        final isStalled = tracker.record(peer, deltaHash);
        expect(isStalled, isTrue, reason: 'Iteration 3 trips stalled threshold');

        // Offer reply planner diverts away from repeating the stalled 25 rows
        // and prioritizes gap repair rows to break the circular flood
        final plan = await calls.plan(
          delta: delta25,
          deltaStalled: isStalled,
          deepMismatch: true,
          windowDiffers: true,
        );
        expect(plan.source, OfferReplySource.deepBuckets);
        expect(plan.isRepair, isTrue);
        expect(OfferReplyPlanner.countRows(plan.delta), 80);
      },
    );
  });

  group('OfferReplyPlanner.shouldRelay', () {
    test('relays live rows that are newer', () {
      expect(
        OfferReplyPlanner.shouldRelay(envelope: {}, hasNewerMessages: true),
        isTrue,
      );
    });

    test('does not relay gap-fill pages', () {
      expect(
        OfferReplyPlanner.shouldRelay(
          envelope: {BleDiscoveryService.repairFlagKey: true},
          hasNewerMessages: true,
        ),
        isFalse,
      );
    });

    test('does not relay rows that are not newer', () {
      expect(
        OfferReplyPlanner.shouldRelay(envelope: {}, hasNewerMessages: false),
        isFalse,
      );
    });
  });
}
