import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bluetooth_app/models/conversation.dart';
import 'package:bluetooth_app/models/generated/mesh_data.pb.dart';
import 'package:bluetooth_app/providers/ble_network_provider.dart';
import 'package:bluetooth_app/providers/chat_provider.dart';
import 'package:bluetooth_app/providers/conversation_provider.dart';
import 'package:bluetooth_app/providers/identity_provider.dart';
import 'package:bluetooth_app/providers/node_profiles_provider.dart';
import 'package:bluetooth_app/widgets/chat/new_chat_page.dart';

const _me = '11111111-1111-4111-8111-111111111111';
const _ava = '22222222-2222-4222-8222-222222222222';
const _noah = '33333333-3333-4333-8333-333333333333';

Future<ProviderContainer> _openPage(
  WidgetTester tester, {
  List<String> storedChats = const [],
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        myNodeIdProvider.overrideWith((ref) async => _me),
        nodeProfilesProvider.overrideWith(
          (ref) => Stream.value([
            NodeProfile(nodeId: _ava, displayName: 'Ava'),
            NodeProfile(nodeId: _noah, displayName: 'Noah'),
          ]),
        ),
        activePeersProvider.overrideWith((ref) => Stream.value(const [])),
        privateConversationIdsProvider.overrideWith(
          (ref) => Stream.value(storedChats),
        ),
        conversationPreviewsProvider.overrideWith(
          (ref) => Stream.value(const <ConversationPreview>[]),
        ),
      ],
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => openNewChatPage(context),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return ProviderScope.containerOf(tester.element(find.byType(NewChatPage)));
}

void main() {
  testWidgets('choosing one person starts a chat, two start a group', (
    tester,
  ) async {
    final container = await _openPage(tester);

    expect(find.text('New chat'), findsOneWidget);
    expect(find.text('Ava'), findsOneWidget);
    expect(find.text('Noah'), findsOneWidget);
    expect(find.byKey(const Key('start_chat_button')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('chat_person_$_ava')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('to_chip_$_ava')), findsOneWidget);
    expect(find.text('Start chat'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('chat_person_$_noah')));
    await tester.pumpAndSettle();
    expect(find.text('New group'), findsOneWidget);
    expect(find.text('Start group'), findsOneWidget);

    await tester.tap(find.byKey(const Key('start_chat_button')));
    await tester.pumpAndSettle();

    final location = container.read(chatLocationProvider);
    expect(location.showingList, isFalse);
    expect(location.conversationId, ConversationIds.group([_me, _ava, _noah]));
    expect(find.byType(NewChatPage), findsNothing);
  });

  testWidgets('choosing people who already have a chat reopens it', (
    tester,
  ) async {
    final existing = ConversationIds.direct(_me, _ava);
    final container = await _openPage(tester, storedChats: [existing]);

    // Existing chats are offered as suggestions before anyone is picked.
    expect(find.byKey(ValueKey('suggested_$existing')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('chat_person_$_ava')));
    await tester.pumpAndSettle();
    expect(find.text('Open chat'), findsOneWidget);

    await tester.tap(find.byKey(const Key('start_chat_button')));
    await tester.pumpAndSettle();
    expect(container.read(chatLocationProvider).conversationId, existing);
  });

  testWidgets('shows a spinner, not an empty message, while people load', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          myNodeIdProvider.overrideWith((ref) async => _me),
          nodeProfilesProvider.overrideWith(
            (ref) => const Stream<List<NodeProfile>>.empty(),
          ),
          activePeersProvider.overrideWith((ref) => Stream.value(const [])),
          privateConversationIdsProvider.overrideWith(
            (ref) => Stream.value(const <String>[]),
          ),
          conversationPreviewsProvider.overrideWith(
            (ref) => Stream.value(const <ConversationPreview>[]),
          ),
        ],
        child: const MaterialApp(home: NewChatPage()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.textContaining('show up here'), findsNothing);
  });

  testWidgets('typing filters people', (tester) async {
    await _openPage(tester);

    await tester.enterText(find.byKey(const Key('new_chat_query')), 'noa');
    await tester.pumpAndSettle();
    expect(find.text('Noah'), findsOneWidget);
    expect(find.text('Ava'), findsNothing);
  });
}
