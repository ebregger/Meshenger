import 'package:flutter_test/flutter_test.dart';

import 'package:bluetooth_app/services/deferred_repair.dart';

void main() {
  final t0 = DateTime(2026, 9, 30, 12);

  test('a deferred round comes back once the blocking link closes', () {
    final queue = DeferredRepairQueue()
      ..defer('maya', myNodeId: 'me', hash: 7, now: t0);

    final live = queue.takeLive(t0.add(const Duration(milliseconds: 600)));

    expect(live.single.peerId, 'maya');
    expect(live.single.hash, 7);
    expect(live.single.myNodeId, 'me');
  });

  test('taking the queue empties it', () {
    final queue = DeferredRepairQueue()
      ..defer('maya', myNodeId: 'me', hash: 7, now: t0);

    queue.takeLive(t0);

    expect(queue.isEmpty, isTrue);
    expect(queue.takeLive(t0), isEmpty);
  });

  test('only the latest request for a peer is kept', () {
    final queue = DeferredRepairQueue()
      ..defer('maya', myNodeId: 'me', hash: 1, now: t0)
      ..defer('maya', myNodeId: 'me', hash: 2, now: t0);

    expect(queue.takeLive(t0).single.hash, 2);
  });

  test('rounds deferred long ago are dropped, not retried', () {
    final queue = DeferredRepairQueue()
      ..defer('old', myNodeId: 'me', hash: 1, now: t0)
      ..defer(
        'fresh',
        myNodeId: 'me',
        hash: 2,
        now: t0.add(const Duration(seconds: 9)),
      );

    final live = queue.takeLive(t0.add(const Duration(seconds: 11)));

    expect(live.map((r) => r.peerId), ['fresh']);
  });
}
