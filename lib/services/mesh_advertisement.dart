import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../constants/ble_constants.dart';

/// Parsed Meshenger advertisement. Discovery and tests share this layout:
/// manufacturer payload is `MESH` + 8-byte big-endian database hash + 4-byte
/// node-id prefix, with an optional capability trailer after that.
class MeshAdvertisement {
  const MeshAdvertisement({
    required this.macAddress,
    required this.rssi,
    required this.advertisesService,
    required this.payload,
    required this.databaseHash,
    required this.nodeIdPrefix,
  });

  final String macAddress;
  final int rssi;
  final bool advertisesService;

  /// Bytes after the `MESH` magic, or null when the manufacturer payload is
  /// missing or does not belong to Meshenger.
  final Uint8List? payload;
  final int? databaseHash;
  final String? nodeIdPrefix;

  bool get isMeshPeer => advertisesService || payload != null;

  static MeshAdvertisement fromScanResult(ScanResult result) {
    final payload = _payloadAfterMagic(result);
    return MeshAdvertisement(
      macAddress: result.device.remoteId.str,
      rssi: result.rssi,
      advertisesService: result.advertisementData.serviceUuids.any(
        (uuid) => uuid.str128.toLowerCase() == meshServiceUuid.str128,
      ),
      payload: payload,
      databaseHash: payload == null
          ? null
          : databaseHashFromPayload(payload),
      nodeIdPrefix: payload == null ? null : readNodeIdPrefix(payload),
    );
  }

  static int? databaseHashFromPayload(Uint8List payload) {
    if (payload.length < 8) return null;
    try {
      final data = ByteData.sublistView(payload);
      final hashHigh = data.getUint32(0, Endian.big);
      final hashLow = data.getUint32(4, Endian.big);
      return (hashHigh << 32) | hashLow;
    } catch (_) {
      return null;
    }
  }

  /// Four-character node id stored at bytes 8-11 of the post-magic payload.
  static String? readNodeIdPrefix(Uint8List payload) {
    if (payload.length < 12) return null;
    try {
      final prefix = utf8.decode(
        payload.sublist(8, 12),
        allowMalformed: true,
      );
      if (prefix.isEmpty) return null;
      return prefix;
    } catch (_) {
      return null;
    }
  }

  static Uint8List? _payloadAfterMagic(ScanResult result) {
    final raw = result.advertisementData.manufacturerData[meshManufacturerId];
    if (raw == null || raw.length < 8) return null;
    if (raw[0] != 0x4D ||
        raw[1] != 0x45 ||
        raw[2] != 0x53 ||
        raw[3] != 0x48) {
      return null;
    }
    return Uint8List.fromList(raw.sublist(4));
  }
}
