import 'dart:async';

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

/// How much of a thread is loaded at a time.
///
/// A thread opens on a small page so it appears at once, then older pages are
/// fetched ahead of the reader: a first top-up shortly after opening, and more
/// whenever the scroll position comes within [prefetchExtent] of the oldest
/// loaded message. A page holds far more than that margin, so loading stays
/// ahead of even a fast fling.
class ChatPaging {
  ChatPaging._();

  /// Newest messages loaded when a thread opens.
  static const int initialLimit = 40;

  /// First top-up, requested right after the first page has painted.
  static const int warmLimit = 160;

  /// Messages added by each further page.
  static const int pageSize = 160;

  /// Distance from the oldest loaded message at which the next page is asked
  /// for. Roughly fifteen bubbles.
  static const double prefetchExtent = 1600;

  /// Limit used when everything must be loaded (stress-test runs, which
  /// verify every message was painted).
  static const int unbounded = 1 << 30;

  static bool showEverything = false;
}

/// Number of newest messages loaded for the open thread. Resets to the small
/// first page whenever another conversation is opened.
final chatLimitProvider = StateProvider<int>((ref) {
  ref.watch(selectedConversationIdProvider);
  return ChatPaging.showEverything
      ? ChatPaging.unbounded
      : ChatPaging.initialLimit;
});

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
  // Changing the page size re-runs the query in place. Restarting the provider
  // instead would flash the loading spinner on every page.
  // A newer build may have replaced this one while it awaited the identity.
  if (!ref.mounted) return;
  final limitChanges = StreamController<int?>();
  ref.onDispose(limitChanges.close);
  ref.listen<int>(chatLimitProvider, (_, next) => limitChanges.add(next));

  String? lastSignature;
  final watchTimer = Stopwatch()..start();
  debugPrint(
    '[PERF] chat watch start: thread=${conversationId.isEmpty ? 'room' : 'private'} '
    'limit=${ref.read(chatLimitProvider)}',
  );
  await for (final batch in db.watchTextMessagesWithAuthors(
    conversationId: conversationId,
    viewerNodeId: myId,
    limit: ref.read(chatLimitProvider),
    limitUpdates: limitChanges.stream,
  )) {
    // The query re-runs on any change to the messages table, including
    // unrelated sync traffic. Skip work when this thread did not change.
    final signature = _batchSignature(batch);
    if (signature == lastSignature) continue;
    lastSignature = signature;
    final timer = Stopwatch()..start();
    debugPrint(
      '[PERF] chat query rows=${batch.length} at ${watchTimer.elapsedMilliseconds} ms',
    );
    final opened = await MeshCrypto.openForViewer(
      messages: batch,
      identity: identity,
      publicKeys: await db.fetchPublicKeys(),
      myNodeId: myId,
    );
    debugPrint(
      '[PERF] chat page ready: ${opened.length} messages, '
      'open ${timer.elapsedMilliseconds} ms',
    );
    yield opened;
  }
});

String _batchSignature(List<TextMessageWithAuthor> batch) {
  final buffer = StringBuffer();
  for (final m in batch) {
    buffer
      ..write(m.msgId)
      ..write('|')
      ..write(m.textContent.length)
      ..write('|')
      ..write(m.textContent.hashCode)
      ..write('|')
      ..write(m.authorName)
      ..write('|')
      ..write(m.retiredBy)
      ..write(';');
  }
  return buffer.toString();
}

final privateConversationIdsProvider = StreamProvider<List<String>>((
  ref,
) async* {
  final db = await ref.watch(databaseProvider.future);
  var myId = '';
  try {
    myId = await ref.watch(myNodeIdProvider.future);
  } catch (error) {
    debugPrint('conversation identity unavailable: $error');
  }
  await for (final ids in db.watchPrivateConversationIds(myId)) {
    yield ids;
  }
});

class ConversationPreview {
  const ConversationPreview({
    required this.conversationId,
    required this.preview,
    required this.timestampMs,
  });

  final String conversationId;
  final String preview;
  final int timestampMs;
}

final conversationPreviewsProvider = StreamProvider<List<ConversationPreview>>((
  ref,
) async* {
  final db = await ref.watch(databaseProvider.future);
  var myId = '';
  MeshIdentity? identity;
  try {
    myId = await ref.watch(myNodeIdProvider.future);
    identity = await ref.watch(meshKeyStoreProvider).loadOrCreate();
  } catch (error) {
    debugPrint('conversation preview identity unavailable: $error');
  }
  String? lastSignature;
  await for (final rows in db.watchVisibleConversationRows(myId)) {
    final signature = rows
        .map(
          (r) =>
              '${r['msg_id']}|${r['timestamp']}|${r['text_content'].hashCode}',
        )
        .join(';');
    if (signature == lastSignature) continue;
    lastSignature = signature;
    final latest = <String, Map<String, Object?>>{};
    for (final row in rows) {
      final id = row['conversation_id']?.toString() ?? '';
      latest.putIfAbsent(id, () => row);
    }
    final publicKeys = await db.fetchPublicKeys();
    final previews = <ConversationPreview>[];
    for (final entry in latest.entries) {
      final row = entry.value;
      final timestampRaw = row['timestamp'];
      final timestampMs = timestampRaw is Int64
          ? timestampRaw.toInt()
          : int.tryParse(timestampRaw?.toString() ?? '') ?? 0;
      final message = TextMessageWithAuthor(
        msgId: row['msg_id']?.toString() ?? '',
        originNodeId: row['origin_node_id']?.toString() ?? '',
        textContent: row['text_content']?.toString() ?? '',
        timestamp: Int64(timestampMs),
        authorName: '',
        conversationId: entry.key,
        recipientNodeId: row['recipient_node_id']?.toString() ?? '',
        contentEncoding: row['content_encoding']?.toString() ?? 'plain',
      );
      final opened = await MeshCrypto.openForViewer(
        messages: [message],
        identity: identity,
        publicKeys: publicKeys,
        myNodeId: myId,
      );
      final text = opened.single.textContent.trim();
      previews.add(
        ConversationPreview(
          conversationId: entry.key,
          preview: text.isEmpty ? 'Message' : text,
          timestampMs: timestampMs,
        ),
      );
    }
    yield previews;
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
    } else if (ConversationIds.isGroup(conversationId)) {
      final members = ConversationIds.members(conversationId);
      if (!members.contains(nodeId) || members.length < 3) {
        lastSendError = 'Choose people for this group chat.';
        return null;
      }
      final identity = await _ref.read(meshKeyStoreProvider).loadOrCreate();
      final keys = Map<String, String>.from(await db.fetchPublicKeys());
      keys[nodeId] = identity.publicKeyBase64;
      final sealed = await MeshCrypto.sealForMembers(
        plaintext: trimmed,
        sender: identity,
        senderNodeId: nodeId,
        memberIds: members,
        publicKeys: keys,
        conversationId: conversationId,
      );
      if (sealed == null) {
        lastSendError =
            'Someone in this chat has not shared an encryption key yet.';
        return null;
      }
      storedText = sealed;
      encoding = MeshCrypto.contentEncoding;
      recipient = '';
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

  /// Deletes a private or group chat from this phone only. One-to-one chats
  /// also tell the other person's phone to gray out its copy; it keeps the
  /// messages until that person chooses to delete them. Groups stay untouched
  /// for everyone else.
  Future<void> deleteConversation(String conversationId) async {
    if (conversationId.isEmpty) return;
    final nodeId = await _ref.read(myNodeIdProvider.future);
    final db = await _ref.read(databaseProvider.future);
    final noticeId = await db.deleteConversationLocally(
      conversationId: conversationId,
      myNodeId: nodeId,
      grayOutForOthers: ConversationIds.isDirect(conversationId),
    );
    if (noticeId != null) onLocalCrdtWrite?.call(noticeId);
  }

  /// Removes messages that are grayed out because the other person deleted
  /// the chat. Only this phone changes.
  Future<void> deleteGrayedMessages(String conversationId) async {
    final db = await _ref.read(databaseProvider.future);
    await db.deleteRetiredMessagesLocally(conversationId);
  }
}

final chatActionsProvider = StateNotifierProvider<ChatActions, int>(
  (ref) => ChatActions(ref),
);
