import 'dart:async';

import 'package:flutter/services.dart';

enum MeshAdapterState {
  unknown,
  on,
  off,
  turningOn,
  turningOff,
  unauthorized,
  unavailable,
}

/// One advertisement observation, without a plugin-owned device or cache.
class MeshScanResult {
  const MeshScanResult({
    required this.macAddress,
    required this.rssi,
    required this.seenAt,
    required this.serviceUuids,
    required this.manufacturerData,
  });

  final String macAddress;
  final int rssi;
  final DateTime seenAt;
  final List<String> serviceUuids;
  final Map<int, List<int>> manufacturerData;

  factory MeshScanResult.fromNative(Map<Object?, Object?> raw) {
    final manufacturers = raw['manufacturerData'] as Map? ?? const {};
    return MeshScanResult(
      macAddress: raw['mac'] as String,
      rssi: (raw['rssi'] as num).toInt(),
      seenAt: DateTime.fromMillisecondsSinceEpoch(
        (raw['seenAtMs'] as num).toInt(),
      ),
      serviceUuids: (raw['serviceUuids'] as List? ?? const []).cast<String>(),
      manufacturerData: {
        for (final entry in manufacturers.entries)
          (entry.key as num).toInt(): Uint8List.fromList(
            (entry.value as List).cast<int>(),
          ),
      },
    );
  }
}

/// Discovery and adapter control share one native broadcast stream. GATT
/// traffic keeps its existing channel and scheduling policy.
class NativeBleRadio {
  NativeBleRadio({MethodChannel? methods, Stream<Object?>? events})
    : _methods = methods ?? const MethodChannel('com.featherfawks.mesh/ble'),
      _events =
          events ??
          const EventChannel(
            'com.featherfawks.mesh/radio_events',
          ).receiveBroadcastStream();

  static final instance = NativeBleRadio();
  final MethodChannel _methods;
  final Stream<Object?> _events;

  static MeshAdapterState _state(Object? value) =>
      MeshAdapterState.values.firstWhere(
        (state) => state.name == value,
        orElse: () => MeshAdapterState.unknown,
      );

  Stream<MeshAdapterState> get adapterStates => _events
      .where((event) => event is Map && event['event'] == 'adapter_state')
      .map((event) => _state((event as Map)['state']));

  Stream<List<MeshScanResult>> get scanResults => _events
      .where(
        (event) =>
            event is Map &&
            (event['event'] == 'scan_results' ||
                event['event'] == 'scan_error'),
      )
      .map((event) {
        final raw = event as Map;
        if (raw['event'] == 'scan_error') {
          throw PlatformException(
            code: 'SCAN_FAILED_${raw['code']}',
            message: raw['message'] as String?,
          );
        }
        return [
          for (final result in raw['results'] as List)
            MeshScanResult.fromNative(
              Map<Object?, Object?>.from(result as Map),
            ),
        ];
      });

  Future<MeshAdapterState> adapterState() async =>
      _state(await _methods.invokeMethod<String>('adapter_state'));
  Future<void> startScan() => _methods.invokeMethod<void>('start_scan');
  Future<void> stopScan() => _methods.invokeMethod<void>('stop_scan');
  Future<void> turnOn() =>
      _methods.invokeMethod<void>('request_bluetooth_enable');
}
