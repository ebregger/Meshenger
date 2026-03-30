// This is a generated file - do not edit.
//
// Generated from mesh_data.proto.

// @dart = 3.3

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names
// ignore_for_file: curly_braces_in_flow_control_structures
// ignore_for_file: deprecated_member_use_from_same_package, library_prefixes
// ignore_for_file: non_constant_identifier_names, prefer_relative_imports
// ignore_for_file: unused_import

import 'dart:convert' as $convert;
import 'dart:core' as $core;
import 'dart:typed_data' as $typed_data;

@$core.Deprecated('Use nodeProfileDescriptor instead')
const NodeProfile$json = {
  '1': 'NodeProfile',
  '2': [
    {'1': 'node_id', '3': 1, '4': 1, '5': 9, '10': 'nodeId'},
    {'1': 'display_name', '3': 2, '4': 1, '5': 9, '10': 'displayName'},
    {'1': 'timestamp', '3': 3, '4': 1, '5': 3, '10': 'timestamp'},
  ],
};

/// Descriptor for `NodeProfile`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List nodeProfileDescriptor = $convert.base64Decode(
    'CgtOb2RlUHJvZmlsZRIXCgdub2RlX2lkGAEgASgJUgZub2RlSWQSIQoMZGlzcGxheV9uYW1lGA'
    'IgASgJUgtkaXNwbGF5TmFtZRIcCgl0aW1lc3RhbXAYAyABKANSCXRpbWVzdGFtcA==');

@$core.Deprecated('Use textMessageDescriptor instead')
const TextMessage$json = {
  '1': 'TextMessage',
  '2': [
    {'1': 'msg_id', '3': 1, '4': 1, '5': 9, '10': 'msgId'},
    {'1': 'origin_node_id', '3': 2, '4': 1, '5': 9, '10': 'originNodeId'},
    {'1': 'text_content', '3': 3, '4': 1, '5': 9, '10': 'textContent'},
    {'1': 'timestamp', '3': 4, '4': 1, '5': 3, '10': 'timestamp'},
  ],
};

/// Descriptor for `TextMessage`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List textMessageDescriptor = $convert.base64Decode(
    'CgtUZXh0TWVzc2FnZRIVCgZtc2dfaWQYASABKAlSBW1zZ0lkEiQKDm9yaWdpbl9ub2RlX2lkGA'
    'IgASgJUgxvcmlnaW5Ob2RlSWQSIQoMdGV4dF9jb250ZW50GAMgASgJUgt0ZXh0Q29udGVudBIc'
    'Cgl0aW1lc3RhbXAYBCABKANSCXRpbWVzdGFtcA==');

@$core.Deprecated('Use bitmapChunkDescriptor instead')
const BitmapChunk$json = {
  '1': 'BitmapChunk',
  '2': [
    {'1': 'file_id', '3': 1, '4': 1, '5': 9, '10': 'fileId'},
    {'1': 'chunk_index', '3': 2, '4': 1, '5': 5, '10': 'chunkIndex'},
    {'1': 'total_chunks', '3': 3, '4': 1, '5': 5, '10': 'totalChunks'},
    {'1': 'chunk_data', '3': 4, '4': 1, '5': 12, '10': 'chunkData'},
  ],
};

/// Descriptor for `BitmapChunk`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List bitmapChunkDescriptor = $convert.base64Decode(
    'CgtCaXRtYXBDaHVuaxIXCgdmaWxlX2lkGAEgASgJUgZmaWxlSWQSHwoLY2h1bmtfaW5kZXgYAi'
    'ABKAVSCmNodW5rSW5kZXgSIQoMdG90YWxfY2h1bmtzGAMgASgFUgt0b3RhbENodW5rcxIdCgpj'
    'aHVua19kYXRhGAQgASgMUgljaHVua0RhdGE=');
