import 'package:fixnum/fixnum.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:uuid/uuid.dart';

import '../models/generated/mesh_data.pb.dart';
import '../models/text_message_with_author.dart';
import '../services/local_write_hook.dart';
import 'database_provider.dart';
import 'identity_provider.dart';

/// Live messages from the local CRDT store (updates when the DB changes or mesh merges).
///
/// Single global [StreamProvider] (no `.family`) so the whole app shares one subscription.
final chatProvider = StreamProvider<List<TextMessageWithAuthor>>((ref) async* {
  final db = await ref.watch(databaseProvider.future);
  await for (final batch in db.watchTextMessagesWithAuthors()) {
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
    debugPrint('[BENCHMARK] MSG_ID:${message.msgId} | EVENT:CREATED | TIMESTAMP:${DateTime.now().millisecondsSinceEpoch}');
    await db.upsertTextMessage(message);
    // Push to known BLE neighbors immediately — don't wait for scan/ADV.
    debugPrint('🚀 [CHAT] local write done — invoking sync hook '
        '(hook=${onLocalCrdtWrite != null})');
    onLocalCrdtWrite?.call();
  }
}

final chatActionsProvider =
    StateNotifierProvider<ChatActions, int>((ref) => ChatActions(ref));
