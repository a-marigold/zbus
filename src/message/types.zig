//! Types and constants used by both `InMessage` and `OutMessage`.

/// The current D-Bus protocol version.
///
/// All incoming and outcoming messages
/// must have only this version in the header.
pub const PROTOCOL_VERSION = 1;

/// The part of header before content of `fields`:
///
/// - Four u8: endian, message type, message flags, version
/// - Two u32: serial, body length
/// - One u32: size of `fields`
pub const HEADER_START_SIZE = 16;

/// The part of header before content of `fields`:
///
/// Header start has `u32` integers,
/// so its alignment is the alignment of `u32`.
pub const HEADER_START_ALIGNMENT = @alignOf(u32);

/// Body of a message must always be aligned by this value.
pub const BODY_ALIGNMENT = 8;

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
