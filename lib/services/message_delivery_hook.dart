import 'package:flutter_riverpod/legacy.dart';

import '../services/ble_discovery_service.dart';
import '../services/message_delivery_tracker.dart';

bool _deliveryHookInstalled = false;

/// Connects successful transfers to exact per-message relay progress.
void installMessageDeliverySyncHook() {
  if (_deliveryHookInstalled) return;
  _deliveryHookInstalled = true;
  BleDiscoveryService.addMessagesRelayedListener(
    messageDeliveryTracker.noteMessagesRelayed,
  );
}

final messageDeliveryProvider = ChangeNotifierProvider<MessageDeliveryTracker>(
  (ref) => messageDeliveryTracker,
  disposeNotifier: false,
);
