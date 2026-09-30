import 'package:fixnum/fixnum.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:uuid/uuid.dart';

import '../models/conversation.dart';
import '../models/generated/mesh_data.pb.dart';
import '../models/text_message_with_author.dart';
import '../services/benchmark_trace.dart';
import '../services/local_write_hook.dart';
import '../services/mesh_crypto.dart';
import '../services/mesh_key_store.dart';
import '../services/message_delivery_tracker.dart';
import 'conversation_provider.dart';
import 'database_provider.dart';
import 'identity_provider.dart';
import 'node_profiles_provider.dart';

/// Live messages for the selected conversation.
///
/// Single global [StreamProvider] (no `.family`) so the whole app shares one
/// subscription. The selected conversation and profile updates restart it.
final chatProvider = StreamProvider<List<TextMessageWithAuthor>>((ref) async* {
  final db = await ref.watch(databaseProvider.future);
  final conversationId = ref.watch(selectedConversationIdProvider);
  ref.watch(nodeProfilesProvider);
  var myId = '';
  try {
    myId = await ref.watch(myNodeIdProvider.future);
  } catch (error) {
    debugPrint('chat identity unavailable: $error');
  }
  MeshIdentity? identity;
  try {
    identity = await ref.watch(meshKeyStoreProvider).loadOrCreate();
  } catch (error) {
    debugPrint('mesh key unavailable: $error');
  }
  await for (final batch in db.watchTextMessagesWithAuthors(
    conversationId: conversationId,
    viewerNodeId: myId,
  )) {
    yield await MeshCrypto.openForViewer(
      messages: batch,
      identity: identity,
      publicKeys: await db.fetchPublicKeys(),
      myNodeId: myId,
    );
  }
});

final directConversationIdsProvider = StreamProvider<List<String>>((ref) async* {
  final db = await ref.watch(databaseProvider.future);
  var myId = '';
  try {
    myId = await ref.watch(myNodeIdProvider.future);
  } catch (error) {
    debugPrint('conversation identity unavailable: $error');
  }
  await for (final ids in db.watchDirectConversationIds(myId)) {
    yield ids;
  }
});

/// Sends outbound chat rows into [DatabaseService] (and thus the mesh sync changeset).
class ChatActions extends StateNotifier<int> {
  ChatActions(this._ref) : super(0);

  final Ref _ref;

  /// Set when [sendMessage] returns null because the message could not be stored.
  String? lastSendError;

  Future<String?> sendMessage(
    String text, {
    String conversationId = ConversationIds.room,
    String? recipientNodeId,
  }) async {
    lastSendError = null;
    final trimmed = text.trim();
    if (trimmed.isEmpty) return null;

    final nodeId = await _ref
        .read(identityServiceProvider)
        .getOrCreateMyNodeId();
    final db = await _ref.read(databaseProvider.future);

    final messageId = const Uuid().v4();
    var storedText = trimmed;
    var encoding = 'plain';
    var recipient = recipientNodeId ?? '';
    if (ConversationIds.isDirect(conversationId)) {
      recipient =
          recipientNodeId ??
          ConversationIds.otherParty(conversationId, nodeId) ??
          '';
      if (recipient.isEmpty) {
        lastSendError = 'Choose a peer for this private chat.';
        return null;
      }
      final remoteKey = await db.fetchPublicKey(recipient);
      if (remoteKey == null || remoteKey.isEmpty) {
        lastSendError = 'This peer has not shared an encryption key yet.';
        return null;
      }
      final identity = await _ref.read(meshKeyStoreProvider).loadOrCreate();
      storedText = await MeshCrypto.seal(
        plaintext: trimmed,
        sender: identity,
        recipientPublicKey: remoteKey,
        conversationId: conversationId,
        originNodeId: nodeId,
        recipientNodeId: recipient,
      );
      encoding = MeshCrypto.contentEncoding;
    }

    final message = TextMessage(
      msgId: messageId,
      originNodeId: nodeId,
      textContent: storedText,
      timestamp: Int64(DateTime.now().millisecondsSinceEpoch),
    );
    debugPrint('📤 SAVING LOCAL MESSAGE: ${message.msgId}');
    traceBenchmarkMessage(message.msgId, 'CREATED');
    await db.upsertTextMessage(
      message,
      conversationId: conversationId,
      recipientNodeId: recipient,
      contentEncoding: encoding,
    );
    messageDeliveryTracker.noteLocalSend(message.msgId);
    traceBenchmarkMessage(message.msgId, 'STORED');
    // Push to known BLE neighbors immediately — don't wait for scan/ADV.
    debugPrint(
      '🚀 [CHAT] local write done — invoking sync hook '
      '(hook=${onLocalCrdtWrite != null})',
    );
    onLocalCrdtWrite?.call(message.msgId);
    return message.msgId;
  }
}

final chatActionsProvider = StateNotifierProvider<ChatActions, int>(
  (ref) => ChatActions(ref),
);
