import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/ble_network_provider.dart';
import '../../providers/node_profiles_provider.dart';
import 'device_chip.dart';

/// Nearby and reachable peers. Tapping a chip opens that peer; it does not
/// switch the open conversation.
class PeerStrip extends ConsumerWidget {
  const PeerStrip({super.key, required this.onPeerTap});

  final void Function(MeshNodeState peer) onPeerTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profilesAsync = ref.watch(nodeProfilesProvider);
    final activePeersAsync = ref.watch(activePeersProvider);
    final profileMap = <String, String>{};
    profilesAsync.whenData((profiles) {
      for (final profile in profiles) {
        final name = profile.displayName.trim();
        if (name.isNotEmpty) profileMap[profile.nodeId] = name;
      }
    });

    return SizedBox(
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
                  final peer = peers[i];
                  final label = profileMap[peer.id] ?? peer.name;
                  final chipColor = switch (peer.status) {
                    PeerStatus.direct => Colors.green,
                    PeerStatus.indirect => Colors.yellow,
                    PeerStatus.disconnected => Colors.grey,
                  };
                  if (i > 0) out.add(const SizedBox(width: 10));
                  out.add(
                    InkWell(
                      borderRadius: BorderRadius.circular(20),
                      onTap: () => onPeerTap(peer),
                      child: DeviceChip(
                        label: label,
                        accentColor: chipColor,
                        faded: peer.status != PeerStatus.direct,
                        talking: peer.isTalking,
                        meshCaughtUp: peer.meshCaughtUp,
                      ),
                    ),
                  );
                }
                return out;
              }(),
          ],
        ),
      ),
    );
  }
}
