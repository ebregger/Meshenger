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
  testWidgets('Home shows message field and Send', (WidgetTester tester) async {
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

    expect(find.byKey(const Key('message_input')), findsOneWidget);
    expect(find.byKey(const Key('send_button')), findsOneWidget);
    expect(find.text('Send'), findsOneWidget);
  });
}
