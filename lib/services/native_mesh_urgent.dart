import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'native_mesh_service.dart';

/// Urgent-hold / inbound-slot helpers on the shared BLE MethodChannel.
extension NativeMeshUrgent on NativeMeshService {
  static const MethodChannel _ch = MethodChannel('com.featherfawks.mesh/ble');

  Future<bool> hasInboundClients() async {
    try {
      return await _ch.invokeMethod<bool>('has_inbound_clients') ?? false;
    } on PlatformException {
      return false;
    }
  }

  Future<void> setUrgentHold(bool active) async {
    try {
      await _ch.invokeMethod<void>('set_urgent_hold', {'active': active});
    } on PlatformException catch (e) {
      debugPrint('🔥 Native set_urgent_hold failed: ${e.message}');
    }
  }

  Future<void> cancelOutbound() async {
    try {
      await _ch.invokeMethod<void>('cancel_outbound');
    } on PlatformException catch (e) {
      debugPrint('🔥 Native cancel_outbound failed: ${e.message}');
    }
  }

  Future<void> disconnectInbound() async {
    try {
      await _ch.invokeMethod<void>('disconnect_inbound');
    } on PlatformException catch (e) {
      debugPrint('🔥 Native disconnect_inbound failed: ${e.message}');
    }
  }
}
