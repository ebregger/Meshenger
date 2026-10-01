/// Tracks validation attempts for one framed reply transfer.
///
/// The sender can retransmit the chunks after a NACK. Each retransmission ends
/// with another end frame, so the receiver must be allowed to report a second
/// validation failure for that new round. A stale async validation from an
/// earlier end frame must not enqueue feedback for the newer round.
class FramedReplyRetryState {
  int _currentRound = 0;
  int? _feedbackSentRound;

  int beginRound() {
    _currentRound++;
    return _currentRound;
  }

  bool tryMarkFeedbackSent(int round) {
    if (round != _currentRound || _feedbackSentRound == round) return false;
    _feedbackSentRound = round;
    return true;
  }
}
