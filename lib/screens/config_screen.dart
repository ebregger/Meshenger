import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/database_provider.dart';
import '../providers/identity_provider.dart';

final localDisplayNameProvider = FutureProvider<String?>((ref) async {
  final myId = await ref.watch(myNodeIdProvider.future);
  final db = await ref.watch(databaseProvider.future);
  final profile = await db.fetchNodeProfile(myId);
  return profile?.displayName;
});

class ConfigurationScreen extends ConsumerStatefulWidget {
  const ConfigurationScreen({super.key});

  @override
  ConsumerState<ConfigurationScreen> createState() => _ConfigurationScreenState();
}

class _ConfigurationScreenState extends ConsumerState<ConfigurationScreen> {
  final TextEditingController _controller = TextEditingController();
  Timer? _debounce;
  bool _initializedFromDb = false;
  bool _isProgrammaticUpdate = false;

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final myIdAsync = ref.watch(myNodeIdProvider);
    final nameAsync = ref.watch(localDisplayNameProvider);

    if (nameAsync.hasValue && !_initializedFromDb) {
      _initializedFromDb = true;
      final value = nameAsync.value;
      _isProgrammaticUpdate = true;
      _controller.text = value ?? '';
      _isProgrammaticUpdate = false;
    }

    return Padding(
      padding: const EdgeInsets.all(16),
      child: ListView(
        children: [
          const SizedBox(height: 8),
          Text(
            'Mesh Identity',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 10),
          myIdAsync.when(
            data: (myId) => SelectableText(
              myId,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    fontFamily: 'monospace',
                  ),
            ),
            loading: () => const LinearProgressIndicator(),
            error: (e, _) => Text(
              'Failed to load node id: $e',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.error,
                  ),
            ),
          ),
          const SizedBox(height: 22),
          Text(
            'Display Name',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _controller,
            maxLines: 1,
            decoration: const InputDecoration(
              hintText: 'Enter display name',
              border: OutlineInputBorder(),
            ),
            onChanged: (value) {
              if (_isProgrammaticUpdate) return;
              _debounce?.cancel();
              _debounce = Timer(const Duration(milliseconds: 250), () async {
                try {
                  final db = await ref.read(databaseProvider.future);
                  await db.setLocalDisplayName(value);
                } catch (e) {
                  // Keep UI responsive; errors will show in logs.
                  debugPrint('SET DISPLAY NAME FAILED: $e');
                }
              });
            },
          ),
        ],
      ),
    );
  }
}

