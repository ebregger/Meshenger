import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/database_provider.dart';
import '../providers/identity_provider.dart';
import '../providers/ble_network_provider.dart';


final localDisplayNameProvider = FutureProvider<String?>((ref) async {
  final myId = await ref.watch(myNodeIdProvider.future);
  final db = await ref.watch(databaseProvider.future);
  final profile = await db.fetchNodeProfile(myId);
  return profile?.displayName;
});

class ConfigurationScreen extends ConsumerStatefulWidget {
  const ConfigurationScreen({super.key});

  @override
  ConsumerState<ConfigurationScreen> createState() => _ConfigurationScreenState();
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
          Text(
            'Mesh Identity',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 10),
          myIdAsync.when(
            data: (myId) => SelectableText(
              myId,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    fontFamily: 'monospace',
                  ),
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
          Text(
            'Display Name',
            style: Theme.of(context).textTheme.titleMedium,
          ),
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
                } catch (e) {
                  // Keep UI responsive; errors will show in logs.
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
          _buildDiagnosticsCard(context),
        ],
      ),
    );
  }

  Widget _buildDiagnosticsCard(BuildContext context) {
    final bleState = ref.watch(bleNetworkProvider);
    final notifier = ref.read(bleNetworkProvider.notifier);

    final statuses = bleState.permissionStatuses;

    return Card(
      child: Column(
        children: [
          _DiagnosticTile(
            title: 'Bluetooth Hardware',
            isOk: bleState.bluetoothHardwareEnabled,
            onFix: () => notifier.promptEnableBluetooth(),
            fixLabel: 'Turn On',
          ),
          _DiagnosticTile(
            title: 'Location Services (GPS)',
            subtitle: 'Mandatory for BLE on Android 11 and below',
            isOk: bleState.locationServicesEnabled,
            onFix: () => notifier.promptOpenSettings(),
            fixLabel: 'Open Settings',
          ),
          _DiagnosticTile(
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
              child: Text('No permissions checked yet. Press below to scan.'),
            ),
          ...statuses.entries.map((e) {
            final name = e.key;
            final status = e.value;
            final isGranted = status == 'granted';
            return _DiagnosticTile(
              title: 'Permission: $name',
              subtitle: 'Status: $status',
              isOk: isGranted,
              onFix: () => notifier.retryAndroidPermissions(),
              fixLabel: 'Request',
            );
          }),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: () => notifier.retryAndroidPermissions(),
                icon: const Icon(Icons.refresh),
                label: const Text('Refresh & Request All Permissions'),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () => notifier.resetRadio(),
                icon: const Icon(Icons.restart_alt),
                label: const Text('RESET MESH RADIO (Software)'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.orange,
                  side: const BorderSide(color: Colors.orange),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: SizedBox(
              width: double.infinity,
              child: TextButton.icon(
                onPressed: () => notifier.powerCycleBluetooth(),
                icon: const Icon(Icons.power_settings_new, color: Colors.red),
                label: const Text(
                  'SYSTEM HARD RESET (Power Cycle)',
                  style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DiagnosticTile extends StatelessWidget {
  final String title;
  final String? subtitle;
  final bool isOk;
  final VoidCallback onFix;
  final String fixLabel;
  final Color? warningColor;

  const _DiagnosticTile({
    required this.title,
    this.subtitle,
    required this.isOk,
    required this.onFix,
    required this.fixLabel,
    this.warningColor,
  });

  @override
  Widget build(BuildContext context) {
    Color statusColor = isOk ? (warningColor ?? Colors.green) : Colors.red;

    return ListTile(
      leading: Icon(
        isOk ? (warningColor != null ? Icons.warning_amber : Icons.check_circle) : Icons.error,
        color: statusColor,
      ),
      title: Text(title),
      subtitle: subtitle != null ? Text(subtitle!) : null,
      trailing: !isOk
          ? OutlinedButton(
              onPressed: onFix,
              child: Text(fixLabel),
            )
          : null,
    );
  }
}
