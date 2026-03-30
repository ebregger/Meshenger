import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bluetooth_app/app/app.dart';

void main() {
  testWidgets('Home shows message field and Send', (WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: DynamicColorBuilder(
          builder: (lightDynamic, darkDynamic) {
            return BluetoothApp(
              lightColorScheme: lightDynamic,
              darkColorScheme: darkDynamic,
            );
          },
        ),
      ),
    );

    expect(find.byKey(const Key('message_input')), findsOneWidget);
    expect(find.byKey(const Key('send_button')), findsOneWidget);
    expect(find.text('Send'), findsOneWidget);
  });
}
