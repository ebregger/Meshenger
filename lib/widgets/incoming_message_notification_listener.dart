import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/text_message_with_author.dart';
import '../providers/chat_provider.dart';
import '../providers/identity_provider.dart';
import '../services/debug_incoming_message_test.dart';
import '../services/incoming_notification_planner.dart';
import '../services/local_message_notification_service.dart';

/// Watches the shared message stream and notifies only for new remote messages
/// that arrive while the app is backgrounded.
class IncomingMessageNotificationListener extends ConsumerStatefulWidget {
  const IncomingMessageNotificationListener({required this.child, super.key});

  final Widget child;

  @override
  ConsumerState<IncomingMessageNotificationListener> createState() =>
      _IncomingMessageNotificationListenerState();
}

class _IncomingMessageNotificationListenerState
    extends ConsumerState<IncomingMessageNotificationListener>
    with WidgetsBindingObserver {
  late final LocalMessageNotificationService _notifications;
  late final StreamSubscription<TextMessageWithAuthor>
  _debugMessageSubscription;
  final IncomingNotificationPlanner _planner = IncomingNotificationPlanner();

  AppLifecycleState _lifecycleState = AppLifecycleState.resumed;

  bool get _isBackgrounded =>
      _lifecycleState == AppLifecycleState.hidden ||
      _lifecycleState == AppLifecycleState.paused;

  @override
  void initState() {
    super.initState();
    _lifecycleState =
        WidgetsBinding.instance.lifecycleState ?? AppLifecycleState.resumed;
    _planner.backgrounded = _isBackgrounded;
    WidgetsBinding.instance.addObserver(this);
    _notifications = ref.read(localMessageNotificationServiceProvider);
    unawaited(_notifications.initialize());
    _debugMessageSubscription = debugIncomingMessages.listen(
      _acceptDebugMessage,
    );
  }

  @override
  void dispose() {
    unawaited(_debugMessageSubscription.cancel());
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycleState = state;
    _planner.backgrounded = _isBackgrounded;
  }

  @override
  Widget build(BuildContext context) {
    final messages = ref.watch(chatProvider);
    final myNodeId = ref.watch(myNodeIdProvider);

    ref.listen<AsyncValue<List<TextMessageWithAuthor>>>(chatProvider, (
      _,
      next,
    ) {
      next.whenData(_acceptMessageSnapshot);
    });
    ref.listen<AsyncValue<String>>(myNodeIdProvider, (_, next) {
      next.whenData(_acceptMyNodeId);
    });

    final existingMessages = messages.asData?.value;
    if (existingMessages != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _acceptMessageSnapshot(existingMessages);
      });
    }

    final resolvedNodeId = myNodeId.asData?.value;
    if (resolvedNodeId != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _acceptMyNodeId(resolvedNodeId);
      });
    }

    return widget.child;
  }

  void _acceptMyNodeId(String nodeId) {
    _notifyIds(_planner.acceptIdentity(nodeId));
  }

  void _acceptMessageSnapshot(List<TextMessageWithAuthor> messages) {
    _notifyIds(_planner.acceptSnapshot(messages));
  }

  void _acceptDebugMessage(TextMessageWithAuthor message) {
    _notifyIds(_planner.acceptDebug(message));
  }

  void _notifyIds(List<String> messageIds) {
    for (final messageId in messageIds) {
      unawaited(_notifications.showIncomingMessage(messageId));
    }
  }
}
