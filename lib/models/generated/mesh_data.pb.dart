// This is a generated file - do not edit.
//
// Generated from mesh_data.proto.

// @dart = 3.3

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names
// ignore_for_file: curly_braces_in_flow_control_structures
// ignore_for_file: deprecated_member_use_from_same_package, library_prefixes
// ignore_for_file: non_constant_identifier_names, prefer_relative_imports

import 'dart:core' as $core;

import 'package:fixnum/fixnum.dart' as $fixnum;
import 'package:protobuf/protobuf.dart' as $pb;

export 'package:protobuf/protobuf.dart' show GeneratedMessageGenericExtensions;

/// Identity and metadata for a node in the mesh.
class NodeProfile extends $pb.GeneratedMessage {
  factory NodeProfile({
    $core.String? nodeId,
    $core.String? displayName,
    $fixnum.Int64? timestamp,
  }) {
    final result = create();
    if (nodeId != null) result.nodeId = nodeId;
    if (displayName != null) result.displayName = displayName;
    if (timestamp != null) result.timestamp = timestamp;
    return result;
  }

  NodeProfile._();

  factory NodeProfile.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory NodeProfile.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'NodeProfile',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'mesh_data'),
      createEmptyInstance: create)
    ..aOS(1, _omitFieldNames ? '' : 'nodeId')
    ..aOS(2, _omitFieldNames ? '' : 'displayName')
    ..aInt64(3, _omitFieldNames ? '' : 'timestamp')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  NodeProfile clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  NodeProfile copyWith(void Function(NodeProfile) updates) =>
      super.copyWith((message) => updates(message as NodeProfile))
          as NodeProfile;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static NodeProfile create() => NodeProfile._();
  @$core.override
  NodeProfile createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static NodeProfile getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<NodeProfile>(create);
  static NodeProfile? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get nodeId => $_getSZ(0);
  @$pb.TagNumber(1)
  set nodeId($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasNodeId() => $_has(0);
  @$pb.TagNumber(1)
  void clearNodeId() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get displayName => $_getSZ(1);
  @$pb.TagNumber(2)
  set displayName($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasDisplayName() => $_has(1);
  @$pb.TagNumber(2)
  void clearDisplayName() => $_clearField(2);

  @$pb.TagNumber(3)
  $fixnum.Int64 get timestamp => $_getI64(2);
  @$pb.TagNumber(3)
  set timestamp($fixnum.Int64 value) => $_setInt64(2, value);
  @$pb.TagNumber(3)
  $core.bool hasTimestamp() => $_has(2);
  @$pb.TagNumber(3)
  void clearTimestamp() => $_clearField(3);
}

/// User-visible text propagated through the mesh.
class TextMessage extends $pb.GeneratedMessage {
  factory TextMessage({
    $core.String? msgId,
    $core.String? originNodeId,
    $core.String? textContent,
    $fixnum.Int64? timestamp,
  }) {
    final result = create();
    if (msgId != null) result.msgId = msgId;
    if (originNodeId != null) result.originNodeId = originNodeId;
    if (textContent != null) result.textContent = textContent;
    if (timestamp != null) result.timestamp = timestamp;
    return result;
  }

  TextMessage._();

  factory TextMessage.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory TextMessage.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'TextMessage',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'mesh_data'),
      createEmptyInstance: create)
    ..aOS(1, _omitFieldNames ? '' : 'msgId')
    ..aOS(2, _omitFieldNames ? '' : 'originNodeId')
    ..aOS(3, _omitFieldNames ? '' : 'textContent')
    ..aInt64(4, _omitFieldNames ? '' : 'timestamp')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  TextMessage clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  TextMessage copyWith(void Function(TextMessage) updates) =>
      super.copyWith((message) => updates(message as TextMessage))
          as TextMessage;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static TextMessage create() => TextMessage._();
  @$core.override
  TextMessage createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static TextMessage getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<TextMessage>(create);
  static TextMessage? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get msgId => $_getSZ(0);
  @$pb.TagNumber(1)
  set msgId($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasMsgId() => $_has(0);
  @$pb.TagNumber(1)
  void clearMsgId() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get originNodeId => $_getSZ(1);
  @$pb.TagNumber(2)
  set originNodeId($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasOriginNodeId() => $_has(1);
  @$pb.TagNumber(2)
  void clearOriginNodeId() => $_clearField(2);

  @$pb.TagNumber(3)
  $core.String get textContent => $_getSZ(2);
  @$pb.TagNumber(3)
  set textContent($core.String value) => $_setString(2, value);
  @$pb.TagNumber(3)
  $core.bool hasTextContent() => $_has(2);
  @$pb.TagNumber(3)
  void clearTextContent() => $_clearField(3);

  @$pb.TagNumber(4)
  $fixnum.Int64 get timestamp => $_getI64(3);
  @$pb.TagNumber(4)
  set timestamp($fixnum.Int64 value) => $_setInt64(3, value);
  @$pb.TagNumber(4)
  $core.bool hasTimestamp() => $_has(3);
  @$pb.TagNumber(4)
  void clearTimestamp() => $_clearField(4);
}

/// Fragment of a bitmap file for chunked transfer.
class BitmapChunk extends $pb.GeneratedMessage {
  factory BitmapChunk({
    $core.String? fileId,
    $core.int? chunkIndex,
    $core.int? totalChunks,
    $core.List<$core.int>? chunkData,
  }) {
    final result = create();
    if (fileId != null) result.fileId = fileId;
    if (chunkIndex != null) result.chunkIndex = chunkIndex;
    if (totalChunks != null) result.totalChunks = totalChunks;
    if (chunkData != null) result.chunkData = chunkData;
    return result;
  }

  BitmapChunk._();

  factory BitmapChunk.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory BitmapChunk.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'BitmapChunk',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'mesh_data'),
      createEmptyInstance: create)
    ..aOS(1, _omitFieldNames ? '' : 'fileId')
    ..aI(2, _omitFieldNames ? '' : 'chunkIndex')
    ..aI(3, _omitFieldNames ? '' : 'totalChunks')
    ..a<$core.List<$core.int>>(
        4, _omitFieldNames ? '' : 'chunkData', $pb.PbFieldType.OY)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  BitmapChunk clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  BitmapChunk copyWith(void Function(BitmapChunk) updates) =>
      super.copyWith((message) => updates(message as BitmapChunk))
          as BitmapChunk;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static BitmapChunk create() => BitmapChunk._();
  @$core.override
  BitmapChunk createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static BitmapChunk getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<BitmapChunk>(create);
  static BitmapChunk? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get fileId => $_getSZ(0);
  @$pb.TagNumber(1)
  set fileId($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasFileId() => $_has(0);
  @$pb.TagNumber(1)
  void clearFileId() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.int get chunkIndex => $_getIZ(1);
  @$pb.TagNumber(2)
  set chunkIndex($core.int value) => $_setSignedInt32(1, value);
  @$pb.TagNumber(2)
  $core.bool hasChunkIndex() => $_has(1);
  @$pb.TagNumber(2)
  void clearChunkIndex() => $_clearField(2);

  @$pb.TagNumber(3)
  $core.int get totalChunks => $_getIZ(2);
  @$pb.TagNumber(3)
  set totalChunks($core.int value) => $_setSignedInt32(2, value);
  @$pb.TagNumber(3)
  $core.bool hasTotalChunks() => $_has(2);
  @$pb.TagNumber(3)
  void clearTotalChunks() => $_clearField(3);

  @$pb.TagNumber(4)
  $core.List<$core.int> get chunkData => $_getN(3);
  @$pb.TagNumber(4)
  set chunkData($core.List<$core.int> value) => $_setBytes(3, value);
  @$pb.TagNumber(4)
  $core.bool hasChunkData() => $_has(3);
  @$pb.TagNumber(4)
  void clearChunkData() => $_clearField(4);
}

const $core.bool _omitFieldNames =
    $core.bool.fromEnvironment('protobuf.omit_field_names');
const $core.bool _omitMessageNames =
    $core.bool.fromEnvironment('protobuf.omit_message_names');
