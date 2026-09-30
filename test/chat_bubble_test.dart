import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bluetooth_app/models/chat_message.dart';
import 'package:bluetooth_app/widgets/chat/chat_bubble.dart';

void main() {
  testWidgets('shows the local time for a message from today', (tester) async {
    final now = DateTime.now();
    final timestamp = DateTime(now.year, now.month, now.day, 9, 7);

    await tester.pumpWidget(
      _appWithMessages([_message(id: 'today', timestamp: timestamp)]),
    );

    expect(
      tester
          .widget<Text>(find.byKey(const Key('message_timestamp_today')))
          .data,
      '9:07 AM',
    );
  });

  testWidgets('shows the date as well as time for an older message', (
    tester,
  ) async {
    final timestamp = DateTime.now().subtract(const Duration(days: 2));
    await tester.pumpWidget(
      _appWithMessages([_message(id: 'older', timestamp: timestamp)]),
    );

    final localTimestamp = timestamp.toLocal();
    final localizations = MaterialLocalizations.of(
      tester.element(find.byKey(const Key('message_timestamp_older'))),
    );
    final expectedDate = localizations.formatMediumDate(localTimestamp);
    final expectedTime = localizations.formatTimeOfDay(
      TimeOfDay.fromDateTime(localTimestamp),
    );
    expect(find.text('$expectedDate · $expectedTime'), findsOneWidget);
  });

  testWidgets('keeps long messages within a narrow layout', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      _appWithMessages([
        _message(
          id: 'long',
          timestamp: DateTime.now(),
          body:
              'A long message with enough words to wrap onto several lines '
              'while keeping the timestamp visible at the bottom of its bubble.',
          isSent: true,
        ),
      ]),
    );

    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('message_timestamp_long')), findsOneWidget);
  });

  testWidgets('shows sent and delivered progress on outgoing messages', (
    tester,
  ) async {
    await tester.pumpWidget(
      _appWithMessages([
        _message(
          id: 'outgoing',
          timestamp: DateTime.now(),
          isSent: true,
          delivery: MessageDeliveryState.sent,
        ),
        _message(
          id: 'arrived',
          timestamp: DateTime.now(),
          isSent: true,
          delivery: MessageDeliveryState.delivered,
          deliveredPeerCount: 2,
        ),
      ]),
    );

    expect(find.text('Sent'), findsOneWidget);
    expect(find.text('Delivered to 2 peers'), findsOneWidget);
  });

  for (final isSent in [false, true]) {
    final direction = isSent ? 'sent' : 'received';

    testWidgets('copies the exact body of a $direction message', (
      tester,
    ) async {
      String? copiedText;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copiedText =
                (call.arguments as Map<Object?, Object?>)['text'] as String?;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );

      const body = 'Copy this exact message.\nKeep the second line.';
      await tester.pumpWidget(
        _appWithMessages([
          _message(
            id: 'copy',
            timestamp: DateTime(2024, 6, 7, 11, 12),
            body: body,
            isSent: isSent,
          ),
        ]),
      );

      await tester.longPress(find.byKey(const Key('chat_bubble_copy')));
      await tester.pumpAndSettle();
      expect(find.text('Copy message'), findsOneWidget);

      await tester.tap(find.byKey(const Key('copy_message_action')));
      await tester.pumpAndSettle();

      expect(copiedText, body);
      expect(find.text('Message copied'), findsOneWidget);
    });
  }
}

Widget _appWithMessages(List<ChatMessage> messages) {
  return MaterialApp(
    locale: const Locale('en', 'US'),
    home: Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            for (final message in messages)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: ChatBubble(message: message),
              ),
          ],
        ),
      ),
    ),
  );
}

ChatMessage _message({
  required String id,
  required DateTime timestamp,
  String body = 'Message body',
  bool isSent = false,
  MessageDeliveryState delivery = MessageDeliveryState.none,
  int deliveredPeerCount = 0,
}) {
  return ChatMessage(
    id: id,
    body: body,
    authorName: isSent ? '' : 'Alex',
    isSent: isSent,
    timestamp: timestamp,
    delivery: delivery,
    deliveredPeerCount: deliveredPeerCount,
  );
}
