//! Types used by both `InMessage` and `OutMessage`.

pub const MessageType = enum(u8) {
    MethodCall = 1,
    MethodReturn = 2,
    Error = 3,
    Signal = 4,
};
pub const MessageFlags = struct {
    pub const NO_REPLY_EXPECTED = 0x1;
    pub const NO_AUTO_START = 0x2;
    pub const ALLOW_INTERACTIVE_AUTH = 0x4;
};
