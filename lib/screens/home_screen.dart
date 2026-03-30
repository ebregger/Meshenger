import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/app_themes.dart';
import '../models/chat_message.dart';
import '../models/generated/mesh_data.pb.dart';
import '../providers/ble_network_provider.dart';
import '../providers/chat_provider.dart';
import '../providers/identity_provider.dart';
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

  @override
  Widget build(BuildContext context) {
    final useLiquidBar = defaultTargetPlatformIsIos;
    final topInset = MediaQuery.paddingOf(context).top;
    final myIdAsync = ref.watch(myNodeIdProvider);
    final ble = ref.watch(bleNetworkProvider);

    // App-wide chat stream (chatProvider is not .family — single global subscription).
    ref.listen<AsyncValue<List<TextMessage>>>(chatProvider, (previous, next) {
      final prevLen = previous?.value?.length;
      final nextLen = next.value?.length;
      if (prevLen != nextLen) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _snapChatToBottom(animated: true);
        });
      }
    });

    final discovered = ble.discoveredNodeIds.toList()..sort();
    final radioDot = MeshRadioStatusDot(
      connecting: ble.radioMeshConnecting,
      advertising: ble.radioMeshAdvertising &&
          ble.adapterStatus == BleAdapterStatus.on,
    );

    return Scaffold(
      resizeToAvoidBottomInset: true,
      appBar: useLiquidBar
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
            ),
      body: SafeArea(
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
                    if (discovered.isEmpty)
                      Text(
                        'No mesh nodes nearby',
                        style: Theme.of(context).textTheme.labelLarge?.copyWith(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                            ),
                      )
                    else
                      for (var i = 0; i < discovered.length; i++) ...[
                        if (i > 0) const SizedBox(width: 10),
                        DeviceChip(label: discovered[i]),
                      ],
                  ],
                ),
              ),
            ),
            Expanded(
              child: ref
                  .watch(chatProvider) // global stream — see chat_provider.dart
                  .when(
                data: (messages) {
                  final myId = myIdAsync.value;
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (!mounted) return;
                    _snapChatToBottom(animated: false);
                  });
                  if (messages.isEmpty) {
                    return Center(
                      child: Text(
                        'No messages yet',
                        style: Theme.of(context).textTheme.bodyLarge?.copyWith(
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
                      final isSent =
                          myId != null && tm.originNodeId == myId;
                      final bubble = ChatMessage(
                        id: tm.msgId,
                        body: tm.textContent,
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
      ),
    );
  }
}
