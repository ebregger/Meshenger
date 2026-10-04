package com.bregger.edison.meshenger

/** A held GATT client link may only carry payloads addressed to that peer. */
internal object HeldLinkTargetPolicy {
  fun matches(heldMac: String?, requestedMac: String?): Boolean {
    if (heldMac.isNullOrBlank() || requestedMac.isNullOrBlank()) return false
    return heldMac.trim().equals(requestedMac.trim(), ignoreCase = true)
  }
}
