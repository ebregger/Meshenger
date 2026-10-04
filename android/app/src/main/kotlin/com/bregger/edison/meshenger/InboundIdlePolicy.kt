package com.bregger.edison.meshenger

/**
 * Decides when a silent inbound GATT client is a zombie that should be dropped.
 *
 * The single inbound slot is advertised as "busy", so a peer whose app died
 * mid-handshake (but whose radio link lingers) would otherwise block every
 * other peer from dialing until the link supervision timeout, which may never
 * fire. Held links are leased for at most 15 s, so a subscribed client that has
 * been silent far longer than that is not doing useful work either.
 */
internal object InboundIdlePolicy {
  /** Connected but never subscribed to NOTIFY. */
  const val unreadyIdleMs = 12_000L

  /** Subscribed, but no reads, writes, or descriptor traffic. */
  const val readyIdleMs = 45_000L

  /** How often the sweep runs while any inbound client is attached. */
  const val sweepIntervalMs = 5_000L

  fun shouldEvict(notifyReady: Boolean, idleMs: Long, alreadyEvicting: Boolean): Boolean {
    if (alreadyEvicting || idleMs < 0) return false
    return idleMs >= if (notifyReady) readyIdleMs else unreadyIdleMs
  }
}
