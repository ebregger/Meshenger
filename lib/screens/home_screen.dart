import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/app_themes.dart';
import '../models/chat_message.dart';
import '../models/conversation.dart';
import '../providers/ble_network_provider.dart';
import '../providers/chat_provider.dart';
import '../providers/conversation_provider.dart';
import '../providers/identity_provider.dart';
import '../providers/node_profiles_provider.dart';
import '../screens/config_screen.dart';
import '../services/local_message_notification_service.dart';
import '../services/mesh_key_store.dart';
import '../services/message_delivery_hook.dart';
import '../services/message_delivery_tracker.dart';
import '../services/ui_debug_snapshot.dart';
import '../widgets/chat/chat_bubble.dart';
import '../widgets/chat/chat_input_dock.dart';
import '../widgets/chat/chat_people.dart';
import '../widgets/chat/conversation_list.dart';
import '../widgets/chat/new_chat_page.dart';
import '../widgets/chat/peer_strip.dart';
import '../widgets/chat/retired_notice.dart';
import '../widgets/home/liquid_glass_app_bar.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  final ScrollController _chatScroll = ScrollController();

  bool _showScrollToBottom = false;

  @override
  void initState() {
    super.initState();
    _chatScroll.addListener(_scrollListener);
    messageNotificationTapEvents.addListener(_openMessagesAfterNotificationTap);
  }

  void _openMessagesAfterNotificationTap() {
    if (!mounted) return;
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  void _scrollListener() {
    if (!_chatScroll.hasClients) return;
    final currentScroll = _chatScroll.position.pixels;
    _maybeLoadOlder();

    final shouldShow = currentScroll > 150;
    if (shouldShow != _showScrollToBottom) {
      setState(() {
        _showScrollToBottom = shouldShow;
      });
    }
  }

  /// Asks for the next page of older messages while the reader is still well
  /// short of the oldest one loaded, so pages arrive before they are needed.
  void _maybeLoadOlder() {
    if (!_chatScroll.hasClients) return;
    final position = _chatScroll.position;
    if (position.maxScrollExtent - position.pixels >
        ChatPaging.prefetchExtent) {
      return;
    }
    _requestOlderPage();
  }

  void _requestOlderPage() {
    final chat = ref.read(chatProvider);
    // While another thread is loading, the previous thread's rows are still
    // on show. They say nothing about how much of this one exists.
    if (chat.isLoading) return;
    final loaded = chat.value?.length ?? 0;
    final limit = ref.read(chatLimitProvider);
    // Fewer rows than asked for means either the thread is fully loaded or a
    // page is already on its way.
    if (loaded < limit) return;
    ref.read(chatLimitProvider.notifier).state = limit + ChatPaging.pageSize;
  }

  @override
  void dispose() {
    messageNotificationTapEvents.removeListener(
      _openMessagesAfterNotificationTap,
    );
    _warmTimer?.cancel();
    _chatScroll.removeListener(_scrollListener);
    _chatScroll.dispose();
    super.dispose();
  }

  void _snapChatToBottom({required bool animated}) {
    if (!_chatScroll.hasClients) return;
    final target = 0.0;
    if (animated) {
      _chatScroll.animateTo(
        target,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
    } else {
      _chatScroll.jumpTo(target);
    }
  }

  Timer? _warmTimer;

  /// Keeps older pages coming: a quick first top-up after a thread opens, then
  /// more whenever a page lands while the reader is still close to its top.
  void _scheduleOlderPages() {
    if (ref.read(chatLimitProvider) == ChatPaging.initialLimit) {
      _warmTimer ??= Timer(const Duration(milliseconds: 250), () {
        _warmTimer = null;
        if (!mounted) return;
        if (ref.read(chatLimitProvider) == ChatPaging.initialLimit) {
          _requestOlderPage();
        }
      });
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _maybeLoadOlder();
    });
  }

  Widget _messagesTab(BuildContext context) {
    final location = ref.watch(chatLocationProvider);
    final peerStrip = PeerStrip(
      onPeerTap: (peer) => _showNodeDetailsDialog(context, peer),
    );
    if (location.showingList) {
      return SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            peerStrip,
            const Expanded(child: ConversationList()),
          ],
        ),
      );
    }

    final myIdAsync = ref.watch(myNodeIdProvider);
    final conversationId = location.conversationId;
    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (conversationId.isEmpty) peerStrip,
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(
                  child: ref
                      .watch(chatProvider)
                      .when(
                        data: (messages) {
                          final myId = myIdAsync.value;
                          if (messages.isEmpty) {
                            return Center(
                              child: Text(
                                ConversationIds.isDirect(conversationId)
                                    ? 'No private messages yet'
                                    : 'No messages yet',
                                style: Theme.of(context).textTheme.bodyLarge
                                    ?.copyWith(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.onSurfaceVariant,
                                    ),
                              ),
                            );
                          }

                          return ListView.builder(
                            reverse: true,
                            controller: _chatScroll,
                            physics: const BouncingScrollPhysics(
                              parent: AlwaysScrollableScrollPhysics(),
                            ),
                            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                            itemCount: messages.length,
                            itemBuilder: (context, index) {
                              final messageIndex = messages.length - 1 - index;
                              final tm = messages[messageIndex];
                              final isSent =
                                  myId != null && tm.originNodeId == myId;
                              final deliveryState = isSent
                                  ? ref
                                        .watch(messageDeliveryProvider)
                                        .stateFor(tm.msgId)
                                  : MessageDeliveryState.none;
                              final delivery = !isSent
                                  ? MessageDeliveryState.none
                                  : deliveryState ==
                                        MessageDeliveryState.delivered
                                  ? MessageDeliveryState.delivered
                                  : MessageDeliveryState.sent;

                              final bubble = ChatMessage(
                                id: tm.msgId,
                                body: tm.textContent,
                                authorName: tm.authorName,
                                isSent: isSent,
                                timestamp: DateTime.fromMillisecondsSinceEpoch(
                                  tm.timestamp.toInt(),
                                ),
                                delivery: delivery,
                                deliveredPeerCount: isSent
                                    ? ref
                                          .watch(messageDeliveryProvider)
                                          .peerCount(tm.msgId)
                                    : 0,
                                locked: tm.locked,
                                retired: tm.retired,
                              );
                              final endsRetiredRun =
                                  tm.retired &&
                                  (messageIndex == messages.length - 1 ||
                                      !messages[messageIndex + 1].retired);
                              final deletedBy = endsRetiredRun
                                  ? chatDisplayName(
                                      nodeId: tm.retiredBy,
                                      profileNames: profileNameMap(
                                        ref
                                                .watch(nodeProfilesProvider)
                                                .asData
                                                ?.value ??
                                            const [],
                                      ),
                                    )
                                  : '';
                              final bubbleWidget = ChatBubble(
                                message: bubble,
                                onMessagePrivately:
                                    conversationId.isEmpty &&
                                        !isSent &&
                                        myId != null &&
                                        tm.originNodeId.isNotEmpty
                                    ? () => openConversation(
                                        ref,
                                        ConversationIds.direct(
                                          myId,
                                          tm.originNodeId,
                                        ),
                                      )
                                    : null,
                              );
                              return Padding(
                                padding: const EdgeInsets.only(bottom: 10),
                                child: endsRetiredRun
                                    ? Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.stretch,
                                        children: [
                                          bubbleWidget,
                                          RetiredChatNotice(
                                            deletedBy: deletedBy,
                                            onDelete: () async {
                                              final ok =
                                                  await confirmDeleteGrayedMessages(
                                                    context,
                                                    deletedBy: deletedBy,
                                                  );
                                              if (!ok) return;
                                              await ref
                                                  .read(
                                                    chatActionsProvider
                                                        .notifier,
                                                  )
                                                  .deleteGrayedMessages(
                                                    conversationId,
                                                  );
                                            },
                                          ),
                                        ],
                                      )
                                    : bubbleWidget,
                              );
                            },
                          );
                        },
                        loading: () =>
                            const Center(child: CircularProgressIndicator()),
                        error: (error, stack) => Center(
                          child: SingleChildScrollView(
                            padding: const EdgeInsets.all(16),
                            child: SelectableText(
                              'chatProvider stream failed\n\n$error\n\n$stack',
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.error,
                                fontFamily: 'monospace',
                                fontSize: 12,
                              ),
                            ),
                          ),
                        ),
                      ),
                ),
                if (_showScrollToBottom)
                  Positioned(
                    right: 16,
                    bottom: 16,
                    child: FloatingActionButton.small(
                      onPressed: () {
                        _snapChatToBottom(animated: true);
                      },
                      child: const Icon(Icons.arrow_downward),
                    ),
                  ),
              ],
            ),
          ),
          const ChatInputDock(),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final useLiquidBar = defaultTargetPlatformIsIos;
    final topInset = MediaQuery.paddingOf(context).top;

    ref.listen(chatProvider, (previous, next) {
      final messages = next.value;
      final prevLen = previous?.value?.length;
      final nextLen = messages?.length;
      final newestChanged =
          previous?.value?.lastOrNull?.msgId != messages?.lastOrNull?.msgId;
      if (messages != null) {
        final viewerId = ref.read(myNodeIdProvider).asData?.value;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          UiDebugSnapshot.reportRendered([
            for (final message in messages)
              {
                'msgId': message.msgId,
                'textContent': message.textContent,
                'originNodeId': message.originNodeId,
              },
          ]);
          if (viewerId == null) return;
          for (final message in messages) {
            if (message.originNodeId == viewerId) {
              messageDeliveryTracker.observeStored(message.msgId);
            }
          }
        });
      }
      // Older pages joining the top must not move the reader; only a new
      // newest message (or a different thread) snaps to the bottom.
      if (newestChanged) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          if (!ref.read(chatLocationProvider).showingList) {
            _snapChatToBottom(animated: prevLen != null && prevLen > 0);
          }
        });
      }
      if (nextLen != null && nextLen > 0) _scheduleOlderPages();
    });

    ref.watch(publishMeshIdentityProvider);
    final location = ref.watch(chatLocationProvider);
    final inThread = !location.showingList;
    final conversationTitle = _conversationTitle(location);
    final backButton = BackButton(
      onPressed: () => ref.read(chatLocationProvider.notifier).showList(),
    );
    final settingsButton = IconButton(
      key: const Key('settings_button'),
      tooltip: 'Settings',
      onPressed: () {
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (context) => const ConfigurationScreen(),
          ),
        );
      },
      icon: const Icon(Icons.settings_outlined),
    );
    final appBar = useLiquidBar
        ? LiquidGlassAppBar(
            title: conversationTitle,
            statusBarHeight: topInset,
            leading: inThread ? backButton : null,
            trailing: inThread ? null : settingsButton,
          )
        : AppBar(
            title: Text(conversationTitle),
            centerTitle: true,
            automaticallyImplyLeading: false,
            leading: inThread ? backButton : null,
            actions: [if (!inThread) settingsButton],
          );

    return Scaffold(
      resizeToAvoidBottomInset: true,
      appBar: appBar,
      floatingActionButton: location.showingList
          ? FloatingActionButton(
              key: const Key('new_chat_button'),
              tooltip: 'New chat',
              onPressed: () => openNewChatPage(context),
              child: const Icon(Icons.edit_outlined),
            )
          : null,
      body: _messagesTab(context),
    );
  }

  String _conversationTitle(ChatLocation location) {
    if (location.showingList) return 'Messages';
    return conversationTitle(
      location.conversationId,
      myNodeId: ref.watch(myNodeIdProvider).asData?.value,
      profileNames: profileNameMap(
        ref.watch(nodeProfilesProvider).asData?.value ?? const [],
      ),
      peerNames: peerNameMap(
        ref.watch(activePeersProvider).asData?.value ?? const [],
      ),
    );
  }

  void _showNodeDetailsDialog(BuildContext context, MeshNodeState state) {
    // Only restore the composer keyboard after dismiss if it was already open.
    final keyboardWasOpen = MediaQuery.viewInsetsOf(context).bottom > 0;
    if (!keyboardWasOpen) {
      FocusManager.instance.primaryFocus?.unfocus();
    }

    showDialog<void>(
      context: context,
      builder: (context) => NodeDetailsDialog(initialState: state),
    ).then((_) {
      if (keyboardWasOpen) return;
      // Clear focus now and again after the barrier tap settles, so a click-out
      // can't leave the message field focused and pop the keyboard.
      FocusManager.instance.primaryFocus?.unfocus();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        FocusManager.instance.primaryFocus?.unfocus();
      });
    });
  }
}

class NodeDetailsDialog extends StatefulWidget {
  final MeshNodeState initialState;

  const NodeDetailsDialog({super.key, required this.initialState});

  @override
  State<NodeDetailsDialog> createState() => _NodeDetailsDialogState();
}

class _NodeDetailsDialogState extends State<NodeDetailsDialog> {
  late DateTime trackedLastSeen;
  late int localSecondsAgo;
  String? currentRouteName;
  String? currentMacAddress;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    // Lock in the baseline state once, safely protected from outer rebuilds
    trackedLastSeen = widget.initialState.lastSeen;
    localSecondsAgo = DateTime.now().difference(trackedLastSeen).inSeconds;
    currentRouteName = widget.initialState.routeViaName;
    currentMacAddress = widget.initialState.macAddress;

    // The Autonomous Stopwatch
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        setState(() {
          localSecondsAgo = DateTime.now()
              .difference(trackedLastSeen)
              .inSeconds;
        });
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return PopScope(
      onPopInvokedWithResult: (_, _) => _timer?.cancel(),
      child: AlertDialog(
        title: Text(
          widget.initialState.name,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        content: Consumer(
          builder: (context, ref, child) {
            final nodes =
                ref.watch(activePeersProvider).asData?.value ?? const [];

            // Look for background updates
            MeshNodeState? liveNode;
            for (final n in nodes) {
              if (n.id == widget.initialState.id) {
                liveNode = n;
                break;
              }
            }

            final PeerStatus currentStatus;
            if (liveNode == null) {
              // The stream pruned it entirely (> 75s). It is permanently dead.
              currentStatus = PeerStatus.disconnected;
            } else {
              // It is still in the stream. Use the stream's exact truth.
              currentStatus = liveNode.status;

              // Update route even if lastSeen didn't advance.
              currentRouteName = liveNode.routeViaName;
              if (liveNode.macAddress != null) {
                currentMacAddress = liveNode.macAddress;
              }

              // Update our local stopwatch baseline if a newer ping arrived
              if (liveNode.lastSeen.isAfter(trackedLastSeen)) {
                trackedLastSeen = liveNode.lastSeen;
                localSecondsAgo = DateTime.now()
                    .difference(trackedLastSeen)
                    .inSeconds;
              }
            }

            // Map the UI
            final String statusText;
            final Color statusColor;

            switch (currentStatus) {
              case PeerStatus.disconnected:
                statusText = 'Disconnected';
                statusColor = Colors.grey;
                break;
              case PeerStatus.direct:
                statusText = 'Directly Connected';
                statusColor = Colors.green;
                break;
              case PeerStatus.indirect:
                statusText = 'Indirectly Connected';
                statusColor = Colors.yellow;
                break;
            }

            final lastSeenText = localSecondsAgo < 5
                ? 'Just now'
                : '$localSecondsAgo seconds ago';
            final rssiDbm = liveNode?.rssiDbm ?? widget.initialState.rssiDbm;
            final rssiSeenAt =
                liveNode?.rssiSeenAt ?? widget.initialState.rssiSeenAt;
            final String rssiText;
            if (rssiDbm == null || rssiSeenAt == null) {
              rssiText = 'No scan reading yet';
            } else {
              final ageSeconds = DateTime.now()
                  .difference(rssiSeenAt)
                  .inSeconds;
              final ageText = ageSeconds <= 0
                  ? 'just now'
                  : '${ageSeconds}s ago';
              rssiText = '$rssiDbm dBm · $ageText';
            }

            return SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.timer, size: 16, color: Colors.grey),
                      const SizedBox(width: 8),
                      Text('Last Seen: $lastSeenText'),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      const Icon(
                        Icons.signal_cellular_alt,
                        size: 16,
                        color: Colors.grey,
                      ),
                      const SizedBox(width: 8),
                      Expanded(child: Text('Last scan RSSI: $rssiText')),
                    ],
                  ),
                  const SizedBox(height: 14),
                  const Text('Node ID'),
                  const SizedBox(height: 4),
                  SelectableText(
                    widget.initialState.id,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: 14),
                  const Text('MAC Address'),
                  const SizedBox(height: 4),
                  SelectableText(
                    currentMacAddress ??
                        (currentStatus == PeerStatus.indirect
                            ? 'Unknown (Out of Range)'
                            : currentStatus == PeerStatus.direct
                            ? 'Unknown (awaiting bind)'
                            : 'Unknown'),
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Icon(Icons.circle, size: 10, color: statusColor),
                      const SizedBox(width: 8),
                      Text(statusText),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Icon(
                        liveNode?.meshCaughtUp == true
                            ? Icons.check_circle_rounded
                            : liveNode?.meshCaughtUp == false
                            ? Icons.sync_problem_rounded
                            : Icons.help_outline_rounded,
                        size: 18,
                        color: statusColor,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        liveNode?.meshCaughtUp == true
                            ? 'Mesh caught up'
                            : liveNode?.meshCaughtUp == false
                            ? 'Mesh behind'
                            : 'Mesh sync unknown',
                      ),
                    ],
                  ),
                  if (statusText == 'Indirectly Connected' &&
                      currentRouteName != null) ...[
                    const SizedBox(height: 14),
                    Row(
                      children: [
                        Icon(Icons.route, size: 18, color: scheme.primary),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text('Connected through: $currentRouteName'),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            );
          },
        ),
        actions: [
          Consumer(
            builder: (context, ref, _) {
              final myId = ref.watch(myNodeIdProvider).asData?.value;
              if (myId == null || myId == widget.initialState.id) {
                return const SizedBox.shrink();
              }
              return TextButton(
                key: const Key('private_chat_button'),
                onPressed: () {
                  openConversation(
                    ref,
                    ConversationIds.direct(myId, widget.initialState.id),
                  );
                  _timer?.cancel();
                  Navigator.of(context).pop();
                },
                child: const Text('Private chat'),
              );
            },
          ),
          TextButton(
            onPressed: () {
              _timer?.cancel();
              Navigator.of(context).pop();
            },
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}
