import 'dart:typed_data';

import 'package:fixnum/fixnum.dart';

import '../models/generated/mesh_data.pb.dart';

NodeProfile nodeProfileFromRow(Map<String, Object?> row) {
  return NodeProfile(
    nodeId: _asString(row['mesh_node_id']),
    displayName: _asString(row['display_name']),
    timestamp: Int64(_asInt(row['timestamp'])),
  );
}

TextMessage textMessageFromRow(Map<String, Object?> row) {
  return TextMessage(
    msgId: _asString(row['msg_id']),
    originNodeId: _asString(row['origin_node_id']),
    textContent: _asString(row['text_content']),
    timestamp: Int64(_asInt(row['timestamp'])),
  );
}

BitmapChunk bitmapChunkFromRow(Map<String, Object?> row) {
  return BitmapChunk(
    fileId: _asString(row['file_id']),
    chunkIndex: _asInt(row['chunk_index']),
    totalChunks: _asInt(row['total_chunks']),
    chunkData: _asBytes(row['chunk_data']),
  );
}

String _asString(Object? value) => (value ?? '') as String;

int _asInt(Object? value) {
  if (value is int) return value;
  if (value is Int64) return value.toInt();
  return int.tryParse(value?.toString() ?? '') ?? 0;
}

List<int> _asBytes(Object? value) {
  if (value is Uint8List) return value.toList(growable: false);
  if (value is List<int>) return List<int>.from(value, growable: false);
  return const <int>[];
}

