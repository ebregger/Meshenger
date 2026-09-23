import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bluetooth_app/app/app.dart';

void main() {
  testWidgets('Home shows message field and Send', (WidgetTester tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MeshengerApp(),
      ),
    );

    expect(find.byKey(const Key('message_input')), findsOneWidget);
    expect(find.byKey(const Key('send_button')), findsOneWidget);
    expect(find.text('Send'), findsOneWidget);
  });
}
