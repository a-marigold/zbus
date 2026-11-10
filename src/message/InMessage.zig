//! Incoming (unsolicited) message.

const std = @import("std");
const lang = std.lang;
const types = @import("../types.zig");
const message_types = @import("types.zig");

/// Raw data of a connection stream.
///
/// Contains bytes of `header.fields`, followed by `body_input`.
///
/// String-like types and `InArray` slice this `input`.
///
/// Used to easily free the message.
input: []const u8,

header: Header,

/// Slice of `header.input`, containing bytes of the message body.
body_input: []const u8,

/// Doesn't contain all fields from the spec:
/// - `body_len` is `body_input.len`
/// - `version` is handled automatically
pub const Header = struct {
    /// Endianness of bytes in the header and the body.
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
