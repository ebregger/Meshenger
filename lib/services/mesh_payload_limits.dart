import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Resource limits apply to untrusted BLE input before decoding or merging it.
class MeshPayloadLimits {
  const MeshPayloadLimits._();

  static const maxCompressedBytes = 256 * 1024;
  static const maxDecompressedBytes = 2 * 1024 * 1024;
  static const maxRows = 2048;
  static const maxPeers = 512;
  static const maxFieldBytes = 64 * 1024;
  static const maxMessageCharacters = 2000;
  static const maxMessageBytes = 2048;
  static const maxGroupMembers = 16;
  static const maxChunkBytes = 512;
  static const maxChunks = 16384;
  static const maxIncomingTransfers = 4;
  static const transferTimeout = Duration(seconds: 30);

  static bool canSendText(String text) =>
      text.runes.length <= maxMessageCharacters &&
      utf8.encode(text).length <= maxMessageBytes;

  /// Fits a trusted outbound delta to the same limits the receiver enforces.
  /// Updates `data` to the actual prefix sent, so relay receipts describe only
  /// those records. Later fingerprint repair rounds can fetch the remainder.
  static List<int> encodeDelta(Map<String, dynamic> envelope) {
    final original = envelope['data'];
    if (original is! Map) {
      throw const FormatException('Delta changeset must be an object');
    }
    var rows = Map<String, dynamic>.from(original);
    validateChangeset(rows);
    while (true) {
      envelope['data'] = rows;
      final encoded = utf8.encode(jsonEncode(envelope));
      final compressed = zlib.encode(encoded);
      if (encoded.length <= maxDecompressedBytes &&
          compressed.length <= maxCompressedBytes) {
        return compressed;
      }
      var reduced = false;
      rows = rows.map((table, value) {
        final batch = value as List;
        if (batch.length <= 1) return MapEntry(table, batch);
        reduced = true;
        return MapEntry(table, batch.take((batch.length + 1) ~/ 2).toList());
      });
      if (!reduced) {
        throw const FormatException(
          'Mesh metadata or record exceeds the limit',
        );
      }
    }
  }

  static Map<String, dynamic> decodeEnvelope(List<int> compressed) {
    if (compressed.length > maxCompressedBytes) {
      throw const FormatException(
        'Compressed mesh payload exceeds the size limit',
      );
    }
    final output = _LimitedBytesSink(maxDecompressedBytes);
    final decoder = zlib.decoder.startChunkedConversion(output);
    // Small input chunks bound each inflater allocation, including highly
    // compressed input that expands past the output limit.
    for (var start = 0; start < compressed.length; start += 1024) {
      final end = (start + 1024).clamp(0, compressed.length);
      decoder.add(compressed.sublist(start, end));
    }
    decoder.close();
    final decoded = jsonDecode(utf8.decode(output.bytes.takeBytes()));
    if (decoded is! Map) {
      throw const FormatException('Mesh envelope must be an object');
    }
    final root = Map<String, dynamic>.from(decoded);
    final type = root['type'];
    if (type != null && type != 'offer' && type != 'delta') {
      throw const FormatException('Unknown mesh envelope type');
    }
    for (final field in ['sender_id']) {
      final value = root[field];
      if (value != null && (value is! String || value.length > 128)) {
        throw const FormatException('Invalid peer identity');
      }
    }
    final neighbors = root['neighbors'];
    if (neighbors != null &&
        (neighbors is! List ||
            neighbors.length > maxPeers ||
            neighbors.any((id) => id is! String || id.length > 128))) {
      throw const FormatException('Invalid neighbor list');
    }
    for (final field in ['vector', 'peer_hashes']) {
      final value = root[field];
      if (value != null &&
          (value is! Map ||
              value.length > maxPeers ||
              value.keys.any((id) => id is! String || id.length > 128))) {
        throw const FormatException('Invalid mesh peer map');
      }
    }
    final changes = type == 'offer'
        ? root['initiator_data']
        : (root['data'] ?? root['changes']);
    if (changes != null) {
      if (changes is! Map) {
        throw const FormatException('Changeset must be an object');
      }
      validateChangeset(Map<String, dynamic>.from(changes));
    }
    return root;
  }

  static void validateChangeset(Map<String, dynamic> changeset) {
    const columns = {
      'messages': {
        'msg_id',
        'origin_node_id',
        'text_content',
        'timestamp',
        'conversation_id',
        'recipient_node_id',
        'content_encoding',
        'is_deleted',
        'hlc',
        'node_id',
        'modified',
      },
      'users': {
        'mesh_node_id',
        'display_name',
        'timestamp',
        'public_key',
        'is_deleted',
        'hlc',
        'node_id',
        'modified',
      },
      'bitmap_chunks': {
        'file_id',
        'chunk_index',
        'total_chunks',
        'chunk_data',
        'is_deleted',
        'hlc',
        'node_id',
        'modified',
      },
    };
    var total = 0;
    for (final entry in changeset.entries) {
      final allowed = columns[entry.key];
      final rows = entry.value;
      if (allowed == null || rows is! List) {
        throw const FormatException('Unknown mesh table or invalid rows');
      }
      total += rows.length;
      if (total > maxRows) throw const FormatException('Too many mesh records');
      for (final row in rows) {
        if (row is! Map || row.keys.any((key) => !allowed.contains(key))) {
          throw const FormatException('Invalid mesh record columns');
        }
        final idColumn = switch (entry.key) {
          'messages' => 'msg_id',
          'users' => 'mesh_node_id',
          _ => 'file_id',
        };
        final id = row[idColumn];
        if (id is! String || id.isEmpty || id.length > 128) {
          throw const FormatException('Invalid mesh record identity');
        }
        for (final field in row.entries) {
          final value = field.value;
          if (value is String && utf8.encode(value).length > maxFieldBytes) {
            throw const FormatException('Mesh field exceeds the size limit');
          }
          if (value is List &&
              (field.key != 'chunk_data' ||
                  value.length > maxFieldBytes ||
                  value.any(
                    (byte) => byte is! int || byte < 0 || byte > 255,
                  ))) {
            throw const FormatException('Invalid binary mesh field');
          }
          if (value is Map) {
            throw const FormatException('Nested mesh record value');
          }
        }
        final key = row['public_key'];
        if (key != null && key != '') {
          if (key is! String) throw const FormatException('Invalid peer key');
          final decoded = base64Decode(key);
          if (decoded.length != 32 || decoded.every((byte) => byte == 0)) {
            throw const FormatException('Invalid peer key');
          }
        }
        final conversation = row['conversation_id'];
        if (conversation is String && conversation.length > 2048) {
          throw const FormatException('Invalid conversation identifier');
        }
      }
    }
  }
}

class _LimitedBytesSink extends ByteConversionSink {
  _LimitedBytesSink(this.limit);
  final int limit;
  final bytes = BytesBuilder(copy: false);

  @override
  void add(List<int> data) {
    if (bytes.length + data.length > limit) {
      throw const FormatException(
        'Expanded mesh payload exceeds the size limit',
      );
    }
    bytes.add(data);
  }

  @override
  void close() {}
}
