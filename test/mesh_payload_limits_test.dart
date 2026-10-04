import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'package:bluetooth_app/services/mesh_payload_limits.dart';

void main() {
  test('accepts bounded valid envelopes', () {
    final envelope = {
      'type': 'delta',
      'sender_id': 'alice',
      'data': {
        'messages': [
          {'msg_id': 'message-1', 'text_content': 'hello'},
        ],
      },
    };
    expect(
      MeshPayloadLimits.decodeEnvelope(
        zlib.encode(utf8.encode(jsonEncode(envelope))),
      ),
      envelope,
    );
  });
  test('rejects compressed data that expands beyond the limit', () {
    final oversized = zlib.encode(
      List.filled(MeshPayloadLimits.maxDecompressedBytes + 1, 65),
    );
    expect(oversized.length, lessThan(MeshPayloadLimits.maxCompressedBytes));
    expect(
      () => MeshPayloadLimits.decodeEnvelope(oversized),
      throwsFormatException,
    );
  });
  test('rejects unknown tables, columns and oversized row batches', () {
    expect(
      () => MeshPayloadLimits.validateChangeset({'sqlite_master': []}),
      throwsFormatException,
    );
    expect(
      () => MeshPayloadLimits.validateChangeset({
        'messages': [
          {'msg_id': 'x', 'unexpected': 'value'},
        ],
      }),
      throwsFormatException,
    );
    expect(
      () => MeshPayloadLimits.validateChangeset({
        'messages': List.generate(
          MeshPayloadLimits.maxRows + 1,
          (index) => {'msg_id': '$index'},
        ),
      }),
      throwsFormatException,
    );
  });
  test('message limits account for UTF-8 size and characters', () {
    expect(MeshPayloadLimits.canSendText('a' * 2000), isTrue);
    expect(MeshPayloadLimits.canSendText('a' * 2001), isFalse);
    expect(MeshPayloadLimits.canSendText('😀' * 513), isFalse);
  });

  test(
    'large ciphertext batches fit the receiver and report only sent IDs',
    () {
      final random = Random(42);
      final rows = List.generate(
        20,
        (index) => {
          'msg_id': 'message-$index',
          'text_content': base64Encode(
            List.generate(45000, (_) => random.nextInt(256)),
          ),
        },
      );
      final envelope = <String, dynamic>{
        'type': 'delta',
        'data': {'messages': rows},
      };
      final payload = MeshPayloadLimits.encodeDelta(envelope);
      final decoded = MeshPayloadLimits.decodeEnvelope(payload);
      final sentRows = (decoded['data'] as Map)['messages'] as List;
      expect(
        payload.length,
        lessThanOrEqualTo(MeshPayloadLimits.maxCompressedBytes),
      );
      expect(sentRows, isNotEmpty);
      expect(sentRows.length, lessThan(rows.length));
      expect(sentRows, rows.take(sentRows.length).toList());
      expect(envelope['data'], decoded['data']);
      expect(rows, hasLength(20));
    },
  );

  test('compressible history is also bounded by its expanded size', () {
    final envelope = <String, dynamic>{
      'type': 'delta',
      'data': {
        'messages': List.generate(
          40,
          (index) => {
            'msg_id': 'message-$index',
            'text_content': 'a' * MeshPayloadLimits.maxFieldBytes,
          },
        ),
      },
    };
    final decoded = MeshPayloadLimits.decodeEnvelope(
      MeshPayloadLimits.encodeDelta(envelope),
    );
    expect(((decoded['data'] as Map)['messages'] as List).length, lessThan(40));
  });
}
