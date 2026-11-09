//! Types and constants used by both `InMessage` and `OutMessage`.

/// The current D-Bus protocol version.
///
/// All incoming and outcoming messages
/// must have only this version in the header.
pub const PROTOCOL_VERSION = 1;

pub const MessageType = enum(u8) {
    MethodCall = 1,
    MethodReturn = 2,
    Error = 3,
    Signal = 4,
    /// Unknown message type.
    ///
    /// If this appears in an incoming message,
    /// the whole message must be ignored.
    _,
};
pub const MessageFlags = struct {
    pub const NO_REPLY_EXPECTED = 0x1;
    pub const NO_AUTO_START = 0x2;
    pub const ALLOW_INTERACTIVE_AUTH = 0x4;
};
