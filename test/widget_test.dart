import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bluetooth_app/app/app.dart';
import 'package:bluetooth_app/services/local_message_notification_service.dart';

class _FakeLocalMessageNotificationService
    extends LocalMessageNotificationService {
  @override
  Future<void> initialize() async {}

  @override
  Future<bool?> areNotificationsEnabled() async => false;
}

void main() {
  testWidgets('Home opens Everyone from the chat list', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localMessageNotificationServiceProvider.overrideWithValue(
            _FakeLocalMessageNotificationService(),
          ),
        ],
        child: MeshengerApp(),
      ),
    );

    expect(find.text('Everyone'), findsOneWidget);
    expect(find.byKey(const Key('new_chat_button')), findsOneWidget);
    expect(find.byKey(const Key('settings_button')), findsOneWidget);
    expect(find.text('Configuration'), findsNothing);
    expect(find.byKey(const Key('message_input')), findsNothing);

    await tester.tap(find.byKey(const Key('settings_button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('Mesh Identity'), findsOneWidget);

    await tester.pageBack();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('conversation_everyone')));
    await tester.pump();

    expect(find.byKey(const Key('message_input')), findsOneWidget);
    expect(find.byKey(const Key('send_button')), findsOneWidget);
    expect(find.text('Send'), findsOneWidget);
  });
}
