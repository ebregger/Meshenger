import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/debug_incoming_message_test.dart';
import '../../services/local_message_notification_service.dart';

class MessageNotificationSettings extends ConsumerStatefulWidget {
  const MessageNotificationSettings({super.key});

  @override
  ConsumerState<MessageNotificationSettings> createState() =>
      _MessageNotificationSettingsState();
}

class _MessageNotificationSettingsState
    extends ConsumerState<MessageNotificationSettings>
    with WidgetsBindingObserver {
  bool? _enabled;
  bool _busy = false;
  bool _permissionRequested = false;

  LocalMessageNotificationService get _notifications =>
      ref.read(localMessageNotificationServiceProvider);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_refreshStatus());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_refreshStatus());
  }

  Future<void> _refreshStatus() async {
    final enabled = await _notifications.areNotificationsEnabled();
    if (mounted) setState(() => _enabled = enabled);
  }

  Future<void> _enableOrOpenSettings() async {
    setState(() => _busy = true);
    try {
      if (_enabled == true || _permissionRequested) {
        await _notifications.openNotificationSettings();
        _permissionRequested = false;
      } else {
        _permissionRequested = true;
        await _notifications.requestNotificationsPermission();
      }
      await _refreshStatus();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _sendTestNotification() async {
    unawaited(scheduleDebugIncomingMessage());
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Switch to another app within 5 seconds to test a background alert.',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final enabled = _enabled == true;
    final actionLabel = enabled || _permissionRequested ? 'Settings' : 'Enable';

    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          children: [
            ListTile(
              leading: const Icon(Icons.notifications_outlined),
              title: const Text('Incoming messages'),
              subtitle: Text(
                enabled
                    ? 'Alerts are on. Message contents stay hidden.'
                    : 'Allow alerts when Meshenger is in the background.',
              ),
              trailing: TextButton(
                onPressed: _busy ? null : _enableOrOpenSettings,
                child: _busy
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(actionLabel),
              ),
            ),
            if (kDebugMode)
              Align(
                alignment: Alignment.centerRight,
                child: Padding(
                  padding: const EdgeInsets.only(right: 12, bottom: 8),
                  child: TextButton.icon(
                    onPressed: enabled && !_busy ? _sendTestNotification : null,
                    icon: const Icon(Icons.notifications_active_outlined),
                    label: const Text('Test notification'),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
