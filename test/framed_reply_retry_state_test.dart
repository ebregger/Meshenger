import 'package:flutter_test/flutter_test.dart';
import 'package:bluetooth_app/services/framed_reply_retry_state.dart';

void main() {
  group('FramedReplyRetryState', () {
    test('allows one NACK in each retransmission round', () {
      final state = FramedReplyRetryState();

      final firstRound = state.beginRound();
      expect(state.tryMarkFeedbackSent(firstRound), isTrue);
      expect(state.tryMarkFeedbackSent(firstRound), isFalse);

      final secondRound = state.beginRound();
      expect(state.tryMarkFeedbackSent(secondRound), isTrue);
      expect(state.tryMarkFeedbackSent(secondRound), isFalse);
    });

    test('ignores delayed feedback from a superseded validation round', () {
      final state = FramedReplyRetryState();
      final oldRound = state.beginRound();
      final currentRound = state.beginRound();

      expect(state.tryMarkFeedbackSent(oldRound), isFalse);
      expect(state.tryMarkFeedbackSent(currentRound), isTrue);
    });
  });
}
