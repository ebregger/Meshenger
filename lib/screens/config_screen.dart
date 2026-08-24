import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/ble_network_provider.dart';
import '../providers/database_provider.dart';
import '../providers/identity_provider.dart';
import '../widgets/config/diagnostic_tile.dart';
import '../widgets/config/diagnostics_action_button.dart';

final localDisplayNameProvider = FutureProvider<String?>((ref) async {
  final myId = await ref.watch(myNodeIdProvider.future);
  final db = await ref.watch(databaseProvider.future);
  final profile = await db.fetchNodeProfile(myId);
  return profile?.displayName;
});

class ConfigurationScreen extends ConsumerStatefulWidget {
  const ConfigurationScreen({super.key});

  @override
  ConsumerState<ConfigurationScreen> createState() =>
      _ConfigurationScreenState();
}

class _ConfigurationScreenState extends ConsumerState<ConfigurationScreen> {
  final TextEditingController _controller = TextEditingController();
  Timer? _debounce;
  bool _initializedFromDb = false;
  bool _isProgrammaticUpdate = false;

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final myIdAsync = ref.watch(myNodeIdProvider);
    final nameAsync = ref.watch(localDisplayNameProvider);

    if (nameAsync.hasValue && !_initializedFromDb) {
      _initializedFromDb = true;
      final value = nameAsync.value;
      _isProgrammaticUpdate = true;
      _controller.text = value ?? '';
      _isProgrammaticUpdate = false;
    }

    return Padding(
      padding: const EdgeInsets.all(16),
      child: ListView(
        children: [
          const SizedBox(height: 8),
          Text('Mesh Identity', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 10),
          myIdAsync.when(
            data: (myId) => SelectableText(
              myId,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(fontFamily: 'monospace'),
            ),
            loading: () => const LinearProgressIndicator(),
            error: (e, _) => Text(
              'Failed to load node id: $e',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.error,
              ),
            ),
          ),
          const SizedBox(height: 22),
          Text('Display Name', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 10),
          TextField(
            controller: _controller,
            maxLines: 1,
            decoration: const InputDecoration(
              hintText: 'Enter display name',
              border: OutlineInputBorder(),
            ),
            onChanged: (value) {
              if (_isProgrammaticUpdate) return;
              _debounce?.cancel();
              _debounce = Timer(const Duration(milliseconds: 250), () async {
                try {
                  final db = await ref.read(databaseProvider.future);
                  await db.setLocalDisplayName(value);
                  ref.invalidate(localDisplayNameProvider);
                } catch (e) {
                  debugPrint('SET DISPLAY NAME FAILED: $e');
                }
              });
            },
          ),
          const SizedBox(height: 32),
          Text(
            'Connectivity Diagnostics',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 10),
          _buildDiagnosticsSection(),
        ],
      ),
    );
  }

  Widget _buildDiagnosticsSection() {
    final bleState = ref.watch(bleNetworkProvider);
    final notifier = ref.read(bleNetworkProvider.notifier);
    final statuses = bleState.permissionStatuses;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              DiagnosticTile(
                title: 'Bluetooth Hardware',
                isOk: bleState.bluetoothHardwareEnabled,
                onFix: () => notifier.promptEnableBluetooth(),
                fixLabel: 'Turn On',
              ),
              DiagnosticTile(
                title: 'Location Services (GPS)',
                subtitle: 'Mandatory for BLE on Android 11 and below',
                isOk: bleState.locationServicesEnabled,
                onFix: () => notifier.promptOpenSettings(),
                fixLabel: 'Open Settings',
              ),
              DiagnosticTile(
                title: 'BLE Scanner Instance',
                subtitle: !bleState.scannerHealthy
                    ? 'CRITICAL ERROR: Scanner failed to start'
                    : (bleState.scannerStalled
                          ? 'WARNING: No activity detected (Potential Jam)'
                          : 'Healthy - Scanning for peers'),
                isOk: bleState.scannerHealthy && !bleState.scannerStalled,
                onFix: () => notifier.resetRadio(),
                fixLabel: 'Try Reset',
                warningColor: bleState.scannerHealthy && bleState.scannerStalled
                    ? Colors.orange
                    : null,
              ),
              const Divider(),
              if (statuses.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(
                    'No permissions checked yet. Press below to scan.',
                  ),
                ),
              ...statuses.entries.map((e) {
                return DiagnosticTile(
                  title: 'Permission: ${e.key}',
                  subtitle: 'Status: ${e.value}',
                  isOk: e.value == 'granted',
                  onFix: () => notifier.retryAndroidPermissions(),
                  fixLabel: 'Request',
                );
              }),
            ],
          ),
        ),
        const SizedBox(height: 12),
        DiagnosticsActionButton(
          onPressed: () => notifier.retryAndroidPermissions(),
          icon: Icons.refresh,
          label: 'Refresh & Request All Permissions',
        ),
        const SizedBox(height: 8),
        DiagnosticsActionButton(
          onPressed: () => notifier.resetRadio(),
          icon: Icons.restart_alt,
          label: 'Restart Mesh Radio',
        ),
        const SizedBox(height: 8),
        DiagnosticsActionButton(
          onPressed: () => notifier.powerCycleBluetooth(),
          icon: Icons.bluetooth_disabled,
          label: 'Turn Bluetooth Off and On',
        ),
      ],
    );
  }
}
