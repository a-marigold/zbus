//! Outgoing message.

const types = @import("types.zig");
const message_types = @import("message_types.zig");

/// If the message doesn't need a body, `Body` can be `null`.
pub fn OutMessage(comptime Body: ?type) type {
    if (Body) |BodyType|
        return struct {
            header: Header,
            body: BodyType,
        };

    return struct { header: Header };
}

/// Doesn't contain all the fields from the spec.
///
/// Instead, some fields are computed automatically during serialization.
const Header = struct {
    /// Type of the message.
    ///
    /// See `MessageTypes`.
    message_type: message_types.MessageType,

    /// `0` means no flag is selected.
    ///
    /// See `MessageFlags`.
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
        unix_fds: ?types.StaticArrayElem(FieldCode.init(9), types.StaticVariant(types.Num(u32))),
    });
};
