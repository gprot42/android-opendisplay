package app.opendisplay.receiver.protocol

/**
 * Mirrors Shared/Protocol.swift — bump only when the wire changes.
 * See WIRE.md at the repo root.
 */
object WireProtocol {
    /** 3 = optional AUD1 system-audio frames when hello advertises audio=1. */
    const val VERSION = 3
    const val MIN_SUPPORTED_PEER = 1
    const val ASSUMED_WHEN_ABSENT = 1

    const val DEFAULT_PORT: Int = 9000
    /** Mac listens here when it cannot dial the tablet (AP client isolation). */
    const val MAC_REVERSE_PORT: Int = 9011
    /** Android NsdManager requires the trailing period; Bonjour peers still match. */
    const val SERVICE_TYPE = "_opensidecar._tcp."
    /** Mac host advertisement for reverse dial (tablet → Mac). */
    const val MAC_HOST_SERVICE_TYPE = "_opendisplay-mac._tcp."
}

object WireMessage {
    const val WELCOME = "welcome"
    const val UPDATE_REQUIRED = "updateRequired"
    const val SLEEPING = "sleeping"
    const val CLOSING = "closing"
    const val HELLO = "hello"
    const val TOUCH = "touch"
    const val SCROLL = "scroll"
    const val PING = "ping"
    const val PONG = "pong"
    const val STATS = "stats"
    const val KF = "kf"
    const val CURSOR = "cursor"
    const val CURSOR_IMG = "cursorImg"
    /** Visible content rect while pinch-zoomed — Mac crops capture for sharp zoom. */
    const val VIEWPORT = "viewport"
}
