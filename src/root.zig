const std = @import("std");
const testing = std.testing;

const types = @import("types.zig");
const message_types = @import("message_types.zig");

pub const InMessage = @import("InMessage.zig");
const out_message = @import("out_message.zig");

pub const parser = @import("parser.zig");
pub const serializer = @import("serializer.zig");

pub const Conn = @import("Conn.zig");

pub const Num = types.Num;
pub const Bool = types.Bool;
pub const UnixFd = types.UnixFd;
pub const Str = types.Str;
pub const ObjectPath = types.ObjectPath;
pub const Signature = types.Signature;
pub const Struct = types.Struct;
pub const DictEntry = types.DictEntry;
pub const InArray = types.InArray;
pub const OutArray = types.OutArray;
pub const Variant = types.Variant;
pub const StaticArray = types.StaticArray;
pub const StaticArrayElem = types.StaticArrayElem;
pub const StaticVariant = types.StaticVariant;
pub const validateSignature = types.validateSignature;
pub const signatureFromType = types.signatureFromType;

pub const MessageType = message_types.MessageType;
pub const MessageFlags = message_types.MessageFlags;

pub const OutMessage = out_message.OutMessage;

test {
    testing.refAllDecls(types);
    testing.refAllDecls(InMessage);
    testing.refAllDecls(out_message);
    testing.refAllDecls(parser);
    testing.refAllDecls(serializer);
    testing.refAllDecls(Conn);
}
