package com.bregger.edison.meshenger

/** Bounded retransmission policy for a framed server reply. */
internal object FramedReplyRetryPolicy {
  const val maxRetransmissions = 3

  fun canRetry(retriesUsed: Int): Boolean =
    retriesUsed >= 0 && retriesUsed < maxRetransmissions

  fun shouldReplayAll(feedbackReceived: Boolean, retryAllRequested: Boolean): Boolean =
    !feedbackReceived || retryAllRequested
}
