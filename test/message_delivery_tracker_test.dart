import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bluetooth_app/models/chat_message.dart';
import 'package:bluetooth_app/services/ble_discovery_service.dart';
import 'package:bluetooth_app/services/message_delivery_hook.dart';
import 'package:bluetooth_app/services/message_delivery_tracker.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    messageDeliveryTracker.debugReset();
    BleDiscoveryService.lastFullSync.clear();
    BleDiscoveryService.peerCaughtUp.clear();
  });

  test(
    'successful transfers persist exact per-message relay progress',
    () async {
      SharedPreferences.setMockInitialValues({});
      await messageDeliveryTracker.restore(
        await SharedPreferences.getInstance(),
      );
      installMessageDeliverySyncHook();

      messageDeliveryTracker.noteLocalSend('local-1');
      expect(
        messageDeliveryTracker.stateFor('local-1'),
        MessageDeliveryState.sent,
      );

      BleDiscoveryService.markMessagesRelayed('peer-a', ['local-1']);
      expect(
        messageDeliveryTracker.stateFor('local-1'),
        MessageDeliveryState.relayed,
      );
      expect(messageDeliveryTracker.peerCount('local-1'), 1);

      BleDiscoveryService.markMessagesRelayed('peer-b', ['local-1']);
      expect(messageDeliveryTracker.peerCount('local-1'), 2);

      final restored = MessageDeliveryTracker();
      await restored.restore(await SharedPreferences.getInstance());
      expect(restored.stateFor('local-1'), MessageDeliveryState.relayed);
      expect(restored.peerCount('local-1'), 2);
    },
  );

  test('a hash-matched sync does not imply a message was relayed', () {
    messageDeliveryTracker.noteLocalSend('local-1');
    installMessageDeliverySyncHook();
    BleDiscoveryService.markSyncComplete('peer-a');
    expect(
      messageDeliveryTracker.stateFor('local-1'),
      MessageDeliveryState.sent,
    );
  });

  test('only IDs included in the transfer are relayed', () {
    messageDeliveryTracker.noteLocalSend('included');
    messageDeliveryTracker.noteLocalSend('new-during-transfer');
    installMessageDeliverySyncHook();
    BleDiscoveryService.markMessagesRelayed('peer-a', [
      'included',
      'someone-elses-message',
    ]);
    expect(
      messageDeliveryTracker.stateFor('included'),
      MessageDeliveryState.relayed,
    );
    expect(
      messageDeliveryTracker.stateFor('new-during-transfer'),
      MessageDeliveryState.sent,
    );
    expect(
      messageDeliveryTracker.stateFor('someone-elses-message'),
      MessageDeliveryState.none,
    );
  });

  test('legacy optimistic receipts are discarded during migration', () async {
    SharedPreferences.setMockInitialValues({
      'message_delivery_v1': jsonEncode({
        'local': ['old'],
        'delivered': {
          'old': ['peer-a'],
        },
      }),
    });
    final tracker = MessageDeliveryTracker();
    await tracker.restore(await SharedPreferences.getInstance());
    expect(tracker.stateFor('old'), MessageDeliveryState.sent);
    expect(tracker.peerCount('old'), 0);
  });
}
