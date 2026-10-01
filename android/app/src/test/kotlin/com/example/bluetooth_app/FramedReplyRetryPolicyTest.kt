package com.example.bluetooth_app

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class FramedReplyRetryPolicyTest {
  @Test
  fun `permits bounded repair rounds after initial transfer`() {
    assertTrue(FramedReplyRetryPolicy.canRetry(0))
    assertTrue(FramedReplyRetryPolicy.canRetry(1))
    assertTrue(FramedReplyRetryPolicy.canRetry(2))
    assertFalse(FramedReplyRetryPolicy.canRetry(3))
  }

  @Test
  fun `rejects an invalid negative retry count`() {
    assertFalse(FramedReplyRetryPolicy.canRetry(-1))
  }

  @Test
  fun `replays all chunks when the application acknowledgement is missing`() {
    assertTrue(FramedReplyRetryPolicy.shouldReplayAll(feedbackReceived = false, retryAllRequested = false))
  }

  @Test
  fun `honors a selective NACK without forcing a full replay`() {
    assertFalse(FramedReplyRetryPolicy.shouldReplayAll(feedbackReceived = true, retryAllRequested = false))
    assertTrue(FramedReplyRetryPolicy.shouldReplayAll(feedbackReceived = true, retryAllRequested = true))
  }
}
