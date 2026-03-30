import 'dart:async';
import 'dart:convert';
import 'dart:io' show zlib;

import 'package:ble_peripheral/ble_peripheral.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../constants/ble_constants.dart';
import '../providers/database_provider.dart';
import 'ble_discovery_service.dart';

/// GATT peripheral: mesh service, writable mesh characteristic, and GAP ads.
///
/// [BlePeripheral] only exposes services we register via [BlePeripheral.addService]
/// (no automatic Battery 0x180F or Device Information 0x180A from the plugin).
class BleGattServer {
  BleGattServer(this._ref);

  final Ref _ref;
  bool _started = false;
  Uint8List _latestSyncBytes = Uint8List(0);

  Future<void> _refreshSyncCache() async {
    final db = await _ref.read(databaseProvider.future);
    final changeset = await db.getSyncChangeset(null);
    final jsonStr = jsonEncode(changeset);
    final compressed = zlib.encode(utf8.encode(jsonStr));
    _latestSyncBytes = Uint8List.fromList(compressed);
  }

  Future<void> start(String fullNodeId) async {
    await BlePeripheral.initialize();

    final meshCharIdLower = meshCharacteristicUuid.str128.toLowerCase();
    unawaited(_refreshSyncCache());

    BlePeripheral.setReadRequestCallback(
      (deviceId, characteristicId, offset, value) {
        final idMatch = characteristicId.toLowerCase() == meshCharIdLower;
        if (!idMatch) return null;

        // Refresh asynchronously for the next read.
        unawaited(_refreshSyncCache());

        final bytes = _latestSyncBytes;
        debugPrint(
          '📤 PERIPHERAL SERVING READ REQUEST: ${bytes.length} bytes',
        );
        if (offset <= 0) {
          return ReadRequestResult(value: bytes);
        }
        if (offset >= bytes.length) {
          return ReadRequestResult(value: Uint8List(0));
        }
        return ReadRequestResult(
          value: Uint8List.fromList(bytes.sublist(offset)),
        );
      },
    );

    BlePeripheral.setWriteRequestCallback(
      (deviceId, characteristicId, offset, value) {
        final n = value?.length ?? 0;
        debugPrint('📥 GATT SERVER RECEIVED BYTES: $n');
        final idMatch =
            characteristicId.toLowerCase() == meshCharIdLower;
        if (!idMatch || offset != 0 || value == null || value.isEmpty) {
          return null;
        }

        Future<void>.microtask(() async {
          try {
            late final String jsonStr;
            try {
              final decompressed = zlib.decode(value);
              jsonStr = utf8.decode(decompressed);
            } catch (e) {
              debugPrint('🔥 DECOMPRESSION FAILED: $e');
              return;
            }

            debugPrint('🔎 RAW INCOMING JSON: $jsonStr');
            final raw = jsonDecode(jsonStr);
            if (raw is! Map) return;
            final changeset = Map<String, dynamic>.from(raw);
            final db = await _ref.read(databaseProvider.future);
            await db.mergeSyncChangeset(changeset);
            await _refreshSyncCache();
            debugPrint(
              '✅ MESH SYNC COMPLETE: Merged ${changeset.length} tables',
            );
          } catch (e, st) {
            debugPrint('MESH SYNC MERGE FAILED: $e\n$st');
          }
        });

        return null;
      },
    );

    final shortId = BleDiscoveryService.shortNodeIdFromFull(fullNodeId);
    final payload =
        Uint8List.fromList(utf8.encode(shortId));

    if (_started) {
      await BlePeripheral.stopAdvertising();
      await BlePeripheral.clearServices();
    }

    await BlePeripheral.addService(
      BleService(
        uuid: meshServiceUuid.str128,
        primary: true,
        characteristics: [
          BleCharacteristic(
            uuid: meshCharacteristicUuid.str128,
            // Read + write: required for bidirectional swap. Avoid notify/indicate to reduce bonding prompts.
            properties: [
              CharacteristicProperties.read.index,
              CharacteristicProperties.write.index,
              CharacteristicProperties.writeWithoutResponse.index,
            ],
            permissions: [
              AttributePermissions.readable.index,
              AttributePermissions.writeable.index,
            ],
            value: null,
          ),
        ],
      ),
    );

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
