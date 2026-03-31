import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/app_themes.dart';
import '../models/chat_message.dart';
import '../providers/ble_network_provider.dart';
import '../providers/chat_provider.dart';
import '../providers/identity_provider.dart';
import '../providers/node_profiles_provider.dart';
import '../screens/config_screen.dart';
import '../widgets/chat/chat_bubble.dart';
import '../widgets/chat/chat_input_dock.dart';
import '../widgets/chat/device_chip.dart';
import '../widgets/home/liquid_glass_app_bar.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  final ScrollController _chatScroll = ScrollController();
  int _tabIndex = 0;

  @override
  void dispose() {
    _chatScroll.dispose();
    super.dispose();
  }

  void _snapChatToBottom({required bool animated}) {
    if (!_chatScroll.hasClients) return;
    final target = _chatScroll.position.maxScrollExtent;
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

  Widget _messagesTab(BuildContext context) {
    final myIdAsync = ref.watch(myNodeIdProvider);
    final profilesAsync = ref.watch(nodeProfilesProvider);
    final activePeersAsync = ref.watch(activePeersProvider);

    final profileMap = <String, String>{};
    profilesAsync.whenData((profiles) {
      for (final p in profiles) {
        final name = p.displayName.trim();
        if (name.isNotEmpty) {
          profileMap[p.nodeId] = name;
        }
      }
    });

    return SafeArea(
      bottom: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 52,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Row(
                children: [
                  if (activePeersAsync.asData?.value.isEmpty ?? true)
                    Text(
                      'No mesh nodes nearby',
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                    )
                  else
                    ...() {
                      final peers = activePeersAsync.asData!.value;
                      final out = <Widget>[];
                      for (var i = 0; i < peers.length; i++) {
                        final s = peers[i];
                        final label = profileMap[s.id] ?? s.name;
                        Color chipColor;
                        switch (s.status) {
                          case PeerStatus.direct:
                            chipColor = Colors.green;
                            break;
                          case PeerStatus.indirect:
                            chipColor = Colors.yellow;
                            break;
                          case PeerStatus.disconnected:
                            chipColor = Colors.grey;
                            break;
                        }
                        if (i > 0) out.add(const SizedBox(width: 10));
                        out.add(
                          InkWell(
                            borderRadius: BorderRadius.circular(20),
                            onTap: () => _showNodeDetailsDialog(context, s),
                            child: DeviceChip(
                              label: label,
                              accentColor: chipColor,
                              faded: s.status != PeerStatus.direct,
                            ),
                          ),
                        );
                      }
                      return out;
                    }(),
                ],
              ),
            ),
          ),
          Expanded(
            child: ref.watch(chatProvider).when(
                  data: (messages) {
                    final myId = myIdAsync.value;
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (!mounted) return;
                      if (_tabIndex == 0) {
                        _snapChatToBottom(animated: false);
                      }
                    });
                    if (messages.isEmpty) {
                      return Center(
                        child: Text(
                          'No messages yet',
                          style: Theme.of(context)
                              .textTheme
                              .bodyLarge
                              ?.copyWith(
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant,
                              ),
                        ),
                      );
                    }
                    return ListView.builder(
                      controller: _chatScroll,
                      physics: const BouncingScrollPhysics(
                        parent: AlwaysScrollableScrollPhysics(),
                      ),
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                      itemCount: messages.length,
                      itemBuilder: (context, index) {
                        final tm = messages[index];
                        final isSent = myId != null && tm.originNodeId == myId;
                        final bubble = ChatMessage(
                          id: tm.msgId,
                          body: tm.textContent,
                          authorName: tm.authorName,
                          isSent: isSent,
                        );
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: ChatBubble(message: bubble),
                        );
                      },
                    );
                  },
                  loading: () => const Center(
                    child: CircularProgressIndicator(),
                  ),
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
      final prevLen = previous?.value?.length;
      final nextLen = next.value?.length;
      if (prevLen != nextLen) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          if (_tabIndex == 0) {
            _snapChatToBottom(animated: true);
          }
        });
      }
    });

    final appBar = _tabIndex == 0
        ? (useLiquidBar
            ? LiquidGlassAppBar(
                title: 'Messages',
                statusBarHeight: topInset,
              )
            : AppBar(
                title: const Text('Messages'),
                centerTitle: true,
              ))
        : AppBar(
            title: const Text('Configuration'),
            centerTitle: true,
          );

    return Scaffold(
      resizeToAvoidBottomInset: true,
      appBar: appBar,
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _tabIndex,
        onTap: (idx) => setState(() => _tabIndex = idx),
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.chat_bubble_outline_rounded),
            label: 'Messages',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.settings_outlined),
            label: 'Configuration',
          ),
        ],
      ),
      body: IndexedStack(
        index: _tabIndex,
        children: [
          _messagesTab(context),
          const ConfigurationScreen(),
        ],
      ),
    );
  }

  void _showNodeDetailsDialog(BuildContext context, MeshNodeState state) {
    showDialog(
      context: context,
      builder: (context) => NodeDetailsDialog(initialState: state),
    );
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
          localSecondsAgo = DateTime.now().difference(trackedLastSeen).inSeconds;
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
                localSecondsAgo =
                    DateTime.now().difference(trackedLastSeen).inSeconds;
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
                    currentMacAddress ?? 'Unknown (Out of Range)',
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
