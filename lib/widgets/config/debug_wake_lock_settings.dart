import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/native_mesh_service.dart';

class DebugWakeLockSettings extends StatefulWidget {
  const DebugWakeLockSettings({super.key});

  @override
  State<DebugWakeLockSettings> createState() => _DebugWakeLockSettingsState();
}

class _DebugWakeLockSettingsState extends State<DebugWakeLockSettings>
    with WidgetsBindingObserver {
  final NativeMeshService _nativeMesh = NativeMeshService();
  bool? _enabled;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_refreshState());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_refreshState());
  }

  Future<void> _refreshState() async {
    try {
      final enabled = await _nativeMesh.getDebugWakeLockState();
      if (mounted) setState(() => _enabled = enabled);
    } catch (error) {
      if (mounted) setState(() => _enabled = null);
      debugPrint('Could not read debug wake lock state: $error');
    }
  }

  Future<void> _setEnabled(bool enabled) async {
    setState(() => _busy = true);
    try {
      final applied = await _nativeMesh.setDebugWakeLockEnabled(enabled);
      if (!applied) {
        await _refreshState();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Start the mesh session before changing this setting.',
              ),
            ),
          );
        }
        return;
      }
      if (mounted) setState(() => _enabled = enabled);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not change the test wake lock: $error'),
          ),
        );
      }
      await _refreshState();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Column(
        children: [
          SwitchListTile(
            secondary: const Icon(Icons.battery_charging_full_outlined),
            title: const Text('Keep CPU awake for BLE tests'),
            subtitle: Text(
              _enabled == null
                  ? 'Checking test wake lock…'
                  : _enabled!
                  ? 'On. BLE work can continue with the screen off; uses extra battery, lock screen unchanged.'
                  : 'Off. Screen-off testing may be affected by CPU sleep.',
            ),
            value: _enabled ?? false,
            onChanged: _busy || _enabled == null ? null : _setEnabled,
          ),
          if (_busy) const LinearProgressIndicator(),
        ],
      ),
    );
  }
}
