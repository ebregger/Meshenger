import 'package:fixnum/fixnum.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:uuid/uuid.dart';

import '../models/generated/mesh_data.pb.dart';
import 'database_provider.dart';
import 'identity_provider.dart';

/// Live messages from the local CRDT store (updates when the DB changes or mesh merges).
///
/// Single global [StreamProvider] (no `.family`) so the whole app shares one subscription.
final chatProvider = StreamProvider<List<TextMessage>>((ref) async* {
  final db = await ref.watch(databaseProvider.future);
  await for (final batch in db.watchTextMessages()) {
    yield batch;
  }
});

/// Sends outbound chat rows into [DatabaseService] (and thus the mesh sync changeset).
class ChatActions extends StateNotifier<int> {
  ChatActions(this._ref) : super(0);

  final Ref _ref;

  Future<void> sendMessage(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;

    final nodeId =
        await _ref.read(identityServiceProvider).getOrCreateMyNodeId();
    final db = await _ref.read(databaseProvider.future);

    final message = TextMessage(
      msgId: const Uuid().v4(),
      originNodeId: nodeId,
      textContent: trimmed,
      timestamp: Int64(DateTime.now().millisecondsSinceEpoch),
    );
    debugPrint('📤 SAVING LOCAL MESSAGE: ${message.msgId}');
    await db.upsertTextMessage(message);
  }
}

final chatActionsProvider =
    StateNotifierProvider<ChatActions, int>((ref) => ChatActions(ref));
