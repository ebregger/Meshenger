package com.bregger.edison.meshenger

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class InboundIdlePolicyTest {
  @Test
  fun `keeps a client that is still within its handshake window`() {
    assertFalse(InboundIdlePolicy.shouldEvict(false, 11_999L, false))
  }

  @Test
  fun `drops an unsubscribed client once it has been silent too long`() {
    assertTrue(InboundIdlePolicy.shouldEvict(false, 12_000L, false))
  }

  @Test
  fun `gives a subscribed client more room than the longest held link`() {
    assertFalse(InboundIdlePolicy.shouldEvict(true, 30_000L, false))
    assertTrue(InboundIdlePolicy.shouldEvict(true, 45_000L, false))
  }

  @Test
  fun `does not evict twice or on a clock that moved backwards`() {
    assertFalse(InboundIdlePolicy.shouldEvict(false, 60_000L, true))
    assertFalse(InboundIdlePolicy.shouldEvict(false, -5L, false))
  }
}
