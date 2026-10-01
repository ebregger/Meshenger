import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite_crdt/sqlite_crdt.dart';

import 'package:bluetooth_app/models/conversation.dart';
import 'package:bluetooth_app/models/generated/mesh_data.pb.dart';
import 'package:bluetooth_app/providers/ble_network_provider.dart';
import 'package:bluetooth_app/providers/chat_provider.dart';
import 'package:bluetooth_app/providers/conversation_provider.dart';
import 'package:bluetooth_app/providers/database_provider.dart';
import 'package:bluetooth_app/providers/identity_provider.dart';
import 'package:bluetooth_app/providers/node_profiles_provider.dart';
import 'package:bluetooth_app/services/database_service.dart';
import 'package:bluetooth_app/widgets/chat/conversation_list.dart';

const _me = '11111111-1111-4111-8111-111111111111';
const _ava = '22222222-2222-4222-8222-222222222222';

Future<ProviderContainer> _pumpList(
  WidgetTester tester,
  DatabaseService database,
) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        databaseProvider.overrideWith((ref) async => database),
        myNodeIdProvider.overrideWith((ref) async => _me),
        nodeProfilesProvider.overrideWith(
          (ref) =>
              Stream.value([NodeProfile(nodeId: _ava, displayName: 'Ava')]),
        ),
        activePeersProvider.overrideWith((ref) => Stream.value(const [])),
        privateConversationIdsProvider.overrideWith(
          (ref) => Stream.value(const <String>[]),
        ),
        conversationPreviewsProvider.overrideWith(
          (ref) => Stream.value(const <ConversationPreview>[]),
        ),
      ],
      child: const MaterialApp(home: Scaffold(body: ConversationList())),
    ),
  );
  await tester.pumpAndSettle();
  return ProviderScope.containerOf(
    tester.element(find.byType(ConversationList)),
  );
}

Future<DatabaseService> _openDatabase() async {
  final database = DatabaseService.forTesting(await SqliteCrdt.openInMemory());
  await database.init();
  return database;
}

void main() {
  testWidgets('long-press deletes a private chat from the list', (
    tester,
  ) async {
    final database = (await tester.runAsync(_openDatabase))!;
    addTearDown(database.dispose);

    final chat = ConversationIds.direct(_me, _ava);
    final container = await _pumpList(tester, database);
    container.read(pinnedConversationIdsProvider.notifier).pin(chat);
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey(chat)), findsOneWidget);

    await tester.longPress(find.byKey(ValueKey(chat)));
    await tester.pumpAndSettle();
    expect(find.text('Delete chat'), findsOneWidget);

    await tester.tap(find.byKey(const Key('delete_conversation_action')));
    await tester.pumpAndSettle();
    expect(find.text('Delete chat?'), findsOneWidget);

    await tester.tap(find.byKey(const Key('confirm_clear_history')));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey(chat)), findsNothing);
    expect(container.read(pinnedConversationIdsProvider), isEmpty);
    expect(find.byKey(const ValueKey('conversation_everyone')), findsOneWidget);
  });

  testWidgets('long-press on Everyone offers to clear messages', (
    tester,
  ) async {
    final database = (await tester.runAsync(_openDatabase))!;
    addTearDown(database.dispose);
    await _pumpList(tester, database);

    await tester.longPress(find.byKey(const ValueKey('conversation_everyone')));
    await tester.pumpAndSettle();
    expect(find.text('Clear messages'), findsOneWidget);
    expect(find.text('Delete chat'), findsNothing);
  });
}
