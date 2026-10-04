import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/conversation.dart';
import '../providers/database_provider.dart';
import '../providers/identity_provider.dart';
import '../services/mesh_key_store.dart';
import '../services/peer_key_trust_store.dart';

class KeyVerificationScreen extends ConsumerStatefulWidget {
  const KeyVerificationScreen({super.key, this.conversationId = ''});
  final String conversationId;

  @override
  ConsumerState<KeyVerificationScreen> createState() =>
      _KeyVerificationScreenState();
}

class _KeyVerificationScreenState extends ConsumerState<KeyVerificationScreen> {
  late final Future<List<_KeyDetails>> _details = _load();

  Future<List<_KeyDetails>> _load() async {
    final myId = await ref.read(myNodeIdProvider.future);
    final identity = await ref.read(meshKeyStoreProvider).loadOrCreate();
    final db = await ref.read(databaseProvider.future);
    final keys = await db.fetchPublicKeys();
    final profiles = await db.fetchNodeProfiles();
    final names = {
      for (final profile in profiles) profile.nodeId: profile.displayName,
    };
    final trust = ref.read(peerKeyTrustStoreProvider);
    await trust.load();
    final result = <_KeyDetails>[
      _KeyDetails(
        myId,
        'Your fingerprint',
        identity.publicKeyBase64,
        await PeerKeyTrustStore.fingerprint(identity.publicKeyBase64),
        true,
      ),
    ];
    for (final peer in ConversationIds.members(
      widget.conversationId,
    ).where((id) => id != myId)) {
      final key = keys[peer];
      if (key == null) continue;
      await trust.observe(peer, key);
      final name = names[peer]?.trim();
      result.add(
        _KeyDetails(
          peer,
          name == null || name.isEmpty ? peer : name,
          key,
          await PeerKeyTrustStore.fingerprint(key),
          false,
        ),
      );
    }
    return result;
  }

  Future<void> _confirm(_KeyDetails details) async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Have the fingerprints matched?'),
        content: const Text(
          'Compare their fingerprint here with the fingerprint on their own phone, in person or through a trusted channel. Confirm only if every group of numbers matches.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('They match'),
          ),
        ],
      ),
    );
    if (accepted != true) return;
    try {
      await ref
          .read(peerKeyTrustStoreProvider)
          .confirmKey(details.nodeId, details.key);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not save the verified key. Please try again.'),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final trust = ref.watch(peerKeyTrustStoreProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Verify encryption keys')),
      body: FutureBuilder<List<_KeyDetails>>(
        future: _details,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return const Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'Encryption keys are unavailable. Reopen this screen after the peer has synced.',
              ),
            );
          }
          final details = snapshot.data;
          if (details == null) {
            return const Center(child: CircularProgressIndicator());
          }
          return ListView(
            padding: const EdgeInsets.all(20),
            children: [
              const Text(
                'Encryption protects message contents. Verify fingerprints to check who you are chatting with. Names alone do not verify identity.',
              ),
              if (details.length == 1 && widget.conversationId.isNotEmpty)
                const Padding(
                  padding: EdgeInsets.only(top: 16),
                  child: Text(
                    'No peer keys are available yet. Keep both phones nearby and try again after syncing.',
                  ),
                ),
              for (final detail in details) ...[
                const SizedBox(height: 24),
                Text(
                  detail.name,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                SelectableText(
                  detail.fingerprint,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 16),
                ),
                if (!detail.own) ...[
                  const SizedBox(height: 8),
                  Text(
                    trust.pinnedKey(detail.nodeId) != detail.key
                        ? 'Key changed. Sending is paused until you verify this new fingerprint. Older messages may require the previous key.'
                        : trust.isVerified(detail.nodeId, detail.key)
                        ? 'Verified on this phone'
                        : 'Not yet verified',
                  ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: trust.isVerified(detail.nodeId, detail.key)
                          ? null
                          : () => _confirm(detail),
                      icon: const Icon(Icons.verified_user_outlined),
                      label: const Text('Compare and verify'),
                    ),
                  ),
                ],
              ],
            ],
          );
        },
      ),
    );
  }
}

class _KeyDetails {
  const _KeyDetails(
    this.nodeId,
    this.name,
    this.key,
    this.fingerprint,
    this.own,
  );
  final String nodeId;
  final String name;
  final String key;
  final String fingerprint;
  final bool own;
}
