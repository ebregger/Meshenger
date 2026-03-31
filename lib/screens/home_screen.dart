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
import '../providers/ble_network_state.dart';
import '../widgets/home/liquid_glass_app_bar.dart';
import '../widgets/home/mesh_radio_status_dot.dart';

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
                        final isDirect = s.isDirect;
                        final inGrace = s.inGrace;
                        if (i > 0) out.add(const SizedBox(width: 10));
                        out.add(
                          InkWell(
                            borderRadius: BorderRadius.circular(20),
                            onTap: () => _showNodeDetailsDialog(context, s),
                            child: DeviceChip(
                              label: label,
                              accentColor: inGrace
                                  ? Colors.grey
                                  : (isDirect ? Colors.green : Colors.yellow),
                              faded: !isDirect,
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
    final ble = ref.watch(bleNetworkProvider);

    final radioDot = MeshRadioStatusDot(
      connecting: ble.radioMeshConnecting,
      advertising: ble.radioMeshAdvertising && ble.adapterStatus == BleAdapterStatus.on,
    );

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
                trailing: radioDot,
              )
            : AppBar(
                title: const Text('Messages'),
                centerTitle: true,
                actions: [
                  Padding(
                    padding: const EdgeInsets.only(right: 12),
                    child: radioDot,
                  ),
                ],
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
    showDialog<void>(
      context: context,
      builder: (context) => _NodeDetailsDialog(state: state),
    );
  }
}

class _NodeDetailsDialog extends ConsumerStatefulWidget {
  const _NodeDetailsDialog({required this.state});

  final MeshNodeState state;

  @override
  ConsumerState<_NodeDetailsDialog> createState() => _NodeDetailsDialogState();
}

class _NodeDetailsDialogState extends ConsumerState<_NodeDetailsDialog> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = widget.state;
    final peersAsync = ref.watch(activePeersProvider);
    MeshNodeState state = snapshot;
    final peers = peersAsync.asData?.value;
    if (peers != null) {
      for (final e in peers) {
        if (e.id == snapshot.id) {
          state = e;
          break;
        }
      }
    }

    final scheme = Theme.of(context).colorScheme;
    final statusText = state.inGrace
        ? 'Disconnected'
        : (state.isDirect ? 'Directly Connected' : 'Indirectly Connected');
    final statusColor = state.inGrace
        ? Colors.grey
        : (state.isDirect ? Colors.green : Colors.yellow);
    final secondsAgo = DateTime.now().difference(state.lastSeen).inSeconds;
    final lastSeenText =
        secondsAgo == 0 ? 'Just now' : '$secondsAgo seconds ago';

    return AlertDialog(
      title: Text(state.name),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.timer, size: 16, color: Colors.grey),
                const SizedBox(width: 8),
                Text('Last Seen: $lastSeenText'),
              ],
            ),
            const SizedBox(height: 14),
            Text('Node ID'),
            const SizedBox(height: 4),
            SelectableText(
              state.id,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
            const SizedBox(height: 14),
            Text('MAC Address'),
            const SizedBox(height: 4),
            SelectableText(
              state.macAddress ?? 'Unknown (Out of Range)',
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Icon(Icons.circle, size: 10, color: statusColor),
                const SizedBox(width: 8),
                Text(statusText),
              ],
            ),
            if (state.routeViaName != null) ...[
              const SizedBox(height: 14),
              Row(
                children: [
                  Icon(Icons.route, size: 18, color: scheme.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text('Connected through: ${state.routeViaName}'),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}
