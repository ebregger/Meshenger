import 'package:flutter_riverpod/legacy.dart';

import '../services/ble_discovery_service.dart';
import '../services/message_delivery_tracker.dart';

bool _deliveryHookInstalled = false;

/// Connects finished mesh syncs to local delivery receipts.
void installMessageDeliverySyncHook() {
  if (_deliveryHookInstalled) return;
  _deliveryHookInstalled = true;
  BleDiscoveryService.addSyncCompletedListener(
    messageDeliveryTracker.notePeerSync,
  );
}

final messageDeliveryProvider = ChangeNotifierProvider<MessageDeliveryTracker>(
  (ref) => messageDeliveryTracker,
  disposeNotifier: false,
);
