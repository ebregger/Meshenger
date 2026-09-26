import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/text_message_with_author.dart';
import '../providers/chat_provider.dart';
import '../providers/identity_provider.dart';
import '../services/debug_incoming_message_test.dart';
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
  final Set<String> _seenMessageIds = {};
  final List<TextMessageWithAuthor> _awaitingIdentity = [];

  AppLifecycleState _lifecycleState = AppLifecycleState.resumed;
  String? _myNodeId;
  bool _hasSeededHistory = false;

  bool get _isBackgrounded =>
      _lifecycleState == AppLifecycleState.hidden ||
      _lifecycleState == AppLifecycleState.paused;

  @override
  void initState() {
    super.initState();
    _lifecycleState =
        WidgetsBinding.instance.lifecycleState ?? AppLifecycleState.resumed;
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
    if (!_isBackgrounded) _awaitingIdentity.clear();
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
    _myNodeId = nodeId;
    if (!_isBackgrounded || _awaitingIdentity.isEmpty) return;

    final pending = List<TextMessageWithAuthor>.of(_awaitingIdentity);
    _awaitingIdentity.clear();
    for (final message in pending) {
      if (message.originNodeId != nodeId) _notify(message);
    }
  }

  void _acceptMessageSnapshot(List<TextMessageWithAuthor> messages) {
    if (!_hasSeededHistory) {
      _seenMessageIds.addAll(messages.map((message) => message.msgId));
      _hasSeededHistory = true;
      return;
    }

    _acceptNewMessages(messages);
  }

  void _acceptDebugMessage(TextMessageWithAuthor message) {
    if (_hasSeededHistory) _acceptNewMessages([message]);
  }

  void _acceptNewMessages(Iterable<TextMessageWithAuthor> messages) {
    for (final message in messages) {
      if (message.msgId.isEmpty || !_seenMessageIds.add(message.msgId)) {
        continue;
      }
      if (!_isBackgrounded) continue;

      final myNodeId = _myNodeId;
      if (myNodeId == null) {
        _awaitingIdentity.add(message);
      } else if (message.originNodeId != myNodeId) {
        _notify(message);
      }
    }
  }

  void _notify(TextMessageWithAuthor message) {
    unawaited(_notifications.showIncomingMessage(message.msgId));
  }
}
