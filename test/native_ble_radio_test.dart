import 'dart:async';

import 'package:bluetooth_app/services/native_ble_radio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/mesh_radio');

  test(
    'keeps observation timestamps and manufacturer bytes from native batches',
    () async {
      final events = StreamController<Object?>.broadcast();
      final radio = NativeBleRadio(events: events.stream, methods: channel);
      final next = radio.scanResults.first;
      events.add({
        'event': 'scan_results',
        'results': [
          {
            'mac': 'AA:BB:CC:DD:EE:FF',
            'rssi': -42,
            'seenAtMs': 123456789,
            'serviceUuids': ['c7e4f1a2-9b3d-4a8e-a1f6-2d5e8b9c0a4f'],
            'manufacturerData': {
              65504: Uint8List.fromList([0, 127, 128, 255]),
            },
          },
        ],
      });
      final observation = (await next).single;
      expect(observation.macAddress, 'AA:BB:CC:DD:EE:FF');
      expect(observation.rssi, -42);
      expect(observation.seenAt.millisecondsSinceEpoch, 123456789);
      expect(observation.manufacturerData[65504], [0, 127, 128, 255]);
      await events.close();
    },
  );

  test(
    'asynchronous scanner errors do not break adapter state delivery',
    () async {
      final events = StreamController<Object?>.broadcast();
      final radio = NativeBleRadio(events: events.stream, methods: channel);
      final error = expectLater(
        radio.scanResults.first,
        throwsA(isA<PlatformException>()),
      );
      final adapter = radio.adapterStates.first;
      events.add({
        'event': 'scan_error',
        'code': 2,
        'message': 'registration failed',
      });
      events.add({'event': 'adapter_state', 'state': 'off'});
      await error;
      expect(await adapter, MeshAdapterState.off);
      await events.close();
    },
  );

  test(
    'streams each callback once without accumulating old observations',
    () async {
      final events = StreamController<Object?>.broadcast();
      final radio = NativeBleRadio(events: events.stream, methods: channel);
      final batches = <List<MeshScanResult>>[];
      final subscription = radio.scanResults.listen(batches.add);
      for (final mac in ['first', 'second']) {
        events.add({
          'event': 'scan_results',
          'results': [
            {
              'mac': mac,
              'rssi': -30,
              'seenAtMs': 1,
              'serviceUuids': [],
              'manufacturerData': {},
            },
          ],
        });
      }
      await Future<void>.delayed(Duration.zero);
      expect(batches.map((batch) => batch.single.macAddress), [
        'first',
        'second',
      ]);
      await subscription.cancel();
      await events.close();
    },
  );

  test(
    'adapter query and scan/enable commands use the native method channel',
    () async {
      final calls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call.method);
            return call.method == 'adapter_state' ? 'on' : null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      final radio = NativeBleRadio(
        methods: channel,
        events: const Stream.empty(),
      );
      expect(await radio.adapterState(), MeshAdapterState.on);
      await radio.startScan();
      await radio.stopScan();
      await radio.turnOn();
      expect(calls, [
        'adapter_state',
        'start_scan',
        'stop_scan',
        'request_bluetooth_enable',
      ]);
    },
  );
}
