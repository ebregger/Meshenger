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

  test('a completed sync marks locally sent messages delivered', () async {
    SharedPreferences.setMockInitialValues({});
    await messageDeliveryTracker.restore(await SharedPreferences.getInstance());
    installMessageDeliverySyncHook();

    messageDeliveryTracker.noteLocalSend('local-1');
    expect(
      messageDeliveryTracker.stateFor('local-1'),
      MessageDeliveryState.sent,
    );

    BleDiscoveryService.markSyncComplete('peer-a');
    expect(
      messageDeliveryTracker.stateFor('local-1'),
      MessageDeliveryState.delivered,
    );
    expect(messageDeliveryTracker.peerCount('local-1'), 1);

    BleDiscoveryService.markSyncComplete('peer-b');
    expect(messageDeliveryTracker.peerCount('local-1'), 2);

    final restored = MessageDeliveryTracker();
    await restored.restore(await SharedPreferences.getInstance());
    expect(restored.stateFor('local-1'), MessageDeliveryState.delivered);
    expect(restored.peerCount('local-1'), 2);
  });
}
