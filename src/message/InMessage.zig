//! Incoming (unsolicited) message.

const std = @import("std");
const lang = std.lang;
const types = @import("../types.zig");
const message_types = @import("types.zig");

header: Header,
body: []const u8,

pub const Header = struct {
    // TODO: consider `unsupported endian` error

    /// Endianness of bytes in the header and the body.
    ///
    /// For outcoming messages, it is recommended to use the native endian.
    ///
    /// Endianness affects only on:
    /// - Numbers
    /// - Lengths of strings
    /// - Sizes of arrays
    endian: lang.Endian,

    /// See `MessageTypes`.
    ///
    /// Unknown types (`_` field of `MessageType` enum) must be ignored.
    message_type: message_types.MessageType,

    /// `0` means no flag is selected.
    ///
    /// See `message_types.MessageFlags`.
    flags: u8,

    /// Size of body in bytes.
    body_size: u32,

    /// Serial number of the message.
    serial: u32,

    fields: Fields,

    /// Despite that header fields in the spec are in
    /// array of variants, here it's `StaticArray` for performance.
    ///
    /// Values are nullable 'cause required fields depend on the message type.
    ///
    /// Codes of fields are taken from https://dbus.freedesktop.org/doc/dbus-specification.html#message-protocol-messages.
    pub const Fields = types.StaticArray(struct {
        const FieldCode = types.Num(u8);

        const StaticVariantStr = types.StaticVariant(types.Str);

        object_path: ?types.StaticArrayElem(FieldCode.init(1), types.StaticVariant(types.ObjectPath)),
        interface: ?types.StaticArrayElem(FieldCode.init(2), StaticVariantStr),
        method: ?types.StaticArrayElem(FieldCode.init(3), StaticVariantStr),
        error_name: ?types.StaticArrayElem(FieldCode.init(4), StaticVariantStr),

        /// Serial number of the message this message is a reply to.
        reply_serial: ?types.StaticArrayElem(FieldCode.init(5), types.StaticVariant(types.Num(u32))),

        destination: ?types.StaticArrayElem(FieldCode.init(6), StaticVariantStr),
        sender: ?types.StaticArrayElem(FieldCode.init(7), StaticVariantStr),
        body_signature: ?types.StaticArrayElem(FieldCode.init(8), types.StaticVariant(types.Signature)),
        unix_fds: ?types.StaticArrayElem(FieldCode.init(9), types.StaticVariant(types.Num(u32))),
    });
};
