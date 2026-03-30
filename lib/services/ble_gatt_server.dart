import 'dart:convert';

import 'package:ble_peripheral/ble_peripheral.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../constants/ble_constants.dart';
import 'ble_discovery_service.dart';

/// GATT peripheral: mesh service, **write-only** mesh characteristic, and GAP ads.
///
/// Service/characteristic UUIDs live in [ble_constants] ([meshServiceUuid],
/// [meshCharacteristicUuid]) so central and peripheral stay aligned when UUIDs rotate.
///
/// **Ping-pong sync:** no GATT reads — centrals push zlib JSON; this side merges. Peers catch up
/// by scanning and writing when their local message list grows (see [BleNetworkNotifier]).
///
/// Note: ble_peripheral's Android server may still call bonding APIs in native code; this app
/// does not use [BluetoothDevice.createBond] on the central path.
///
/// [BlePeripheral] only exposes services we register via [BlePeripheral.addService]
/// (no automatic Battery 0x180F or Device Information 0x180A from the plugin).
class BleGattServer {
  BleGattServer(this._ref);

  final Ref _ref;
  bool _started = false;

  Future<void> start(String fullNodeId) async {
    await BlePeripheral.initialize();

    final shortId = BleDiscoveryService.shortNodeIdFromFull(fullNodeId);
    final payload =
        Uint8List.fromList(utf8.encode(shortId));

    // This is a "native security behavior probe": we intentionally register no
    // GATT services/characteristics and do not handle writes.
    debugPrint('🧪 BleGattServer empty-shell start (ref=${_ref.hashCode})');

    if (_started) {
      await BlePeripheral.stopAdvertising();
      await BlePeripheral.clearServices();
    }

    await BlePeripheral.startAdvertising(
      services: [meshServiceUuid.str128],
      manufacturerData: ManufacturerData(
        manufacturerId: meshManufacturerId,
        data: payload,
      ),
      addManufacturerDataInScanResponse: true,
    );
    _started = true;
  }

  Future<void> stop() async {
    if (!_started) return;
    await BlePeripheral.stopAdvertising();
    await BlePeripheral.clearServices();
    _started = false;
  }
}
