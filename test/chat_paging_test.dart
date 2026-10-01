import 'dart:async';

import 'package:fixnum/fixnum.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite_crdt/sqlite_crdt.dart';

import 'package:bluetooth_app/models/generated/mesh_data.pb.dart';
import 'package:bluetooth_app/providers/chat_provider.dart';
import 'package:bluetooth_app/providers/database_provider.dart';
import 'package:bluetooth_app/providers/identity_provider.dart';
import 'package:bluetooth_app/providers/node_profiles_provider.dart';
import 'package:bluetooth_app/services/database_service.dart';

const _total = 300;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late DatabaseService db;

  setUp(() async {
    db = DatabaseService.forTesting(await SqliteCrdt.openInMemory());
    await db.init();
    // A fixed base timestamp keeps ordering independent of the test clock.
    final base = DateTime.now().millisecondsSinceEpoch - 10 * 60 * 1000;
    for (var i = 0; i < _total; i++) {
      await db.upsertTextMessage(
        TextMessage(
          msgId: 'm${i.toString().padLeft(4, '0')}',
          originNodeId: 'alice',
          textContent: 'message $i',
          timestamp: Int64(base + i * 1000),
        ),
      );
    }
  });

  tearDown(() => db.dispose());

  String idOf(int n) => 'm${n.toString().padLeft(4, '0')}';

  test('a limited watch returns the newest page, oldest first', () async {
    final page = await db
        .watchTextMessagesWithAuthors(limit: 40)
        .firstWhere((rows) => rows.isNotEmpty);
    expect(page.length, 40);
    expect(page.first.msgId, idOf(_total - 40));
    expect(page.last.msgId, idOf(_total - 1));
  });

  test('raising the limit on a live stream adds older rows', () async {
    final updates = StreamController<int?>();
    final seen = <int>[];
    final sub = db
        .watchTextMessagesWithAuthors(limit: 40, limitUpdates: updates.stream)
        .listen((rows) => seen.add(rows.length));

    Future<void> until(bool Function() done) async {
      for (var i = 0; i < 200 && !done(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(done(), isTrue, reason: 'saw $seen');
    }

    await until(() => seen.contains(40));
    updates.add(200);
    await until(() => seen.contains(200));
    updates.add(null);
    await until(() => seen.contains(_total));
    await sub.cancel();
    await updates.close();
  });

  test('chatProvider pages in place and keeps the newest messages', () async {
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWith((ref) async => db),
        myNodeIdProvider.overrideWith((ref) async => 'alice'),
        nodeProfilesProvider.overrideWith((ref) => Stream.value(const [])),
      ],
    );
    addTearDown(container.dispose);

    final lengths = <int>[];
    var sawLoadingAfterData = false;
    container.listen(chatProvider, (_, next) {
      if (next.hasValue) lengths.add(next.requireValue.length);
      if (next.isLoading && lengths.isNotEmpty && !next.hasValue) {
        sawLoadingAfterData = true;
      }
    }, fireImmediately: true);

    Future<void> until(bool Function() done) async {
      for (var i = 0; i < 300 && !done(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(done(), isTrue, reason: 'saw $lengths');
    }

    await until(() => lengths.contains(ChatPaging.initialLimit));
    expect(
      container.read(chatProvider).requireValue.last.textContent,
      'message ${_total - 1}',
    );

    container.read(chatLimitProvider.notifier).state = ChatPaging.warmLimit;
    await until(() => lengths.contains(ChatPaging.warmLimit));
    expect(
      container.read(chatProvider).requireValue.last.textContent,
      'message ${_total - 1}',
      reason: 'older pages must not displace the newest message',
    );
    expect(sawLoadingAfterData, isFalse, reason: 'paging must not flash');
  });
}
