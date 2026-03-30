import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/connected_devices_provider.dart';
import 'device_chip.dart';

/// Horizontally scrollable row of connected-device chips.
class ConnectedDevicesStrip extends ConsumerWidget {
  const ConnectedDevicesStrip({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final devices = ref.watch(connectedDevicesProvider);

    return SizedBox(
      height: 52,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        child: Row(
          children: [
            for (var i = 0; i < devices.length; i++) ...[
              if (i > 0) const SizedBox(width: 10),
              DeviceChip(label: devices[i]),
            ],
          ],
        ),
      ),
    );
  }
}
