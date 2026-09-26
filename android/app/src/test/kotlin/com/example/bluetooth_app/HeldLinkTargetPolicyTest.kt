package com.example.bluetooth_app

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class HeldLinkTargetPolicyTest {
  @Test
  fun onlyReusesTheRequestedPeerAddress() {
    assertTrue(HeldLinkTargetPolicy.matches("41:F2:FD:81:9C:2D", "41:f2:fd:81:9c:2d"))
    assertFalse(HeldLinkTargetPolicy.matches("41:F2:FD:81:9C:2D", "57:9A:C9:51:19:C7"))
    assertFalse(HeldLinkTargetPolicy.matches(null, "57:9A:C9:51:19:C7"))
    assertFalse(HeldLinkTargetPolicy.matches("41:F2:FD:81:9C:2D", null))
  }
}
