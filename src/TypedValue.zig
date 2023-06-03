const std = @import("std");
const Type = @import("type.zig").Type;
const Value = @import("value.zig").Value;
const Module = @import("Module.zig");
const Allocator = std.mem.Allocator;
const TypedValue = @This();
const Target = std.Target;

ty: Type,
val: Value,

/// Memory management for TypedValue. The main purpose of this type
/// is to be small and have a deinit() function to free associated resources.
pub const Managed = struct {
    /// If the tag value is less than Tag.no_payload_count, then no pointer
    /// dereference is needed.
    typed_value: TypedValue,
    /// If this is `null` then there is no memory management needed.
    arena: ?*std.heap.ArenaAllocator.State = null,

    pub fn deinit(self: *Managed, allocator: Allocator) void {
        if (self.arena) |a| a.promote(allocator).deinit();
        self.* = undefined;
    }
};

/// Assumes arena allocation. Does a recursive copy.
pub fn copy(self: TypedValue, arena: Allocator) error{OutOfMemory}!TypedValue {
    return TypedValue{
        .ty = self.ty,
        .val = try self.val.copy(arena),
    };
}

pub fn eql(a: TypedValue, b: TypedValue, mod: *Module) bool {
    if (a.ty.toIntern() != b.ty.toIntern()) return false;
    return a.val.eql(b.val, a.ty, mod);
}

pub fn hash(tv: TypedValue, hasher: *std.hash.Wyhash, mod: *Module) void {
    return tv.val.hash(tv.ty, hasher, mod);
}

pub fn enumToInt(tv: TypedValue, mod: *Module) Allocator.Error!Value {
    return tv.val.enumToInt(tv.ty, mod);
}

const max_aggregate_items = 100;
const max_string_len = 256;

const FormatContext = struct {
    tv: TypedValue,
    mod: *Module,
};

pub fn format(
    ctx: FormatContext,
    comptime fmt: []const u8,
    options: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    _ = options;
    comptime std.debug.assert(fmt.len == 0);
    return ctx.tv.print(writer, 3, ctx.mod) catch |err| switch (err) {
        error.OutOfMemory => @panic("OOM"), // We're not allowed to return this from a format function
        else => |e| return e,
    };
}

/// Prints the Value according to the Type, not according to the Value Tag.
pub fn print(
    tv: TypedValue,
    writer: anytype,
    level: u8,
    mod: *Module,
) (@TypeOf(writer).Error || Allocator.Error)!void {
    var val = tv.val;
    var ty = tv.ty;
    while (true) switch (val.ip_index) {
        .none => switch (val.tag()) {
            .aggregate => return printAggregate(ty, val, writer, level, mod),
            .@"union" => {
                if (level == 0) {
                    return writer.writeAll(".{ ... }");
                }
                const union_val = val.castTag(.@"union").?.data;
                try writer.writeAll(".{ ");

                try print(.{
                    .ty = mod.unionPtr(mod.intern_pool.indexToKey(ty.toIntern()).union_type.index).tag_ty,
                    .val = union_val.tag,
                }, writer, level - 1, mod);
                try writer.writeAll(" = ");
                try print(.{
                    .ty = ty.unionFieldType(union_val.tag, mod),
                    .val = union_val.val,
                }, writer, level - 1, mod);

                return writer.writeAll(" }");
            },
            .bytes => return writer.print("\"{}\"", .{std.zig.fmtEscapes(val.castTag(.bytes).?.data)}),
            .repeated => {
                if (level == 0) {
                    return writer.writeAll(".{ ... }");
                }
                var i: u32 = 0;
                try writer.writeAll(".{ ");
                const elem_tv = TypedValue{
                    .ty = ty.elemType2(mod),
                    .val = val.castTag(.repeated).?.data,
                };
                const len = ty.arrayLen(mod);
                const max_len = std.math.min(len, max_aggregate_items);
                while (i < max_len) : (i += 1) {
                    if (i != 0) try writer.writeAll(", ");
                    try print(elem_tv, writer, level - 1, mod);
                }
                if (len > max_aggregate_items) {
                    try writer.writeAll(", ...");
                }
                return writer.writeAll(" }");
            },
            .slice => {
                if (level == 0) {
                    return writer.writeAll(".{ ... }");
                }
                const payload = val.castTag(.slice).?.data;
                const elem_ty = ty.elemType2(mod);
                const len = payload.len.toUnsignedInt(mod);

                if (elem_ty.eql(Type.u8, mod)) str: {
                    const max_len = @intCast(usize, std.math.min(len, max_string_len));
                    var buf: [max_string_len]u8 = undefined;

                    var i: u32 = 0;
                    while (i < max_len) : (i += 1) {
                        const elem_val = payload.ptr.elemValue(mod, i) catch |err| switch (err) {
                            error.OutOfMemory => @panic("OOM"), // TODO: eliminate this panic
                        };
                        if (elem_val.isUndef(mod)) break :str;
                        buf[i] = std.math.cast(u8, elem_val.toUnsignedInt(mod)) orelse break :str;
                    }

                    // TODO would be nice if this had a bit of unicode awareness.
                    const truncated = if (len > max_string_len) " (truncated)" else "";
                    return writer.print("\"{}{s}\"", .{ std.zig.fmtEscapes(buf[0..max_len]), truncated });
                }

                try writer.writeAll(".{ ");

                const max_len = std.math.min(len, max_aggregate_items);
                var i: u32 = 0;
                while (i < max_len) : (i += 1) {
                    if (i != 0) try writer.writeAll(", ");
                    const elem_val = payload.ptr.elemValue(mod, i) catch |err| switch (err) {
                        error.OutOfMemory => @panic("OOM"), // TODO: eliminate this panic
                    };
                    try print(.{
                        .ty = elem_ty,
                        .val = elem_val,
                    }, writer, level - 1, mod);
                }
                if (len > max_aggregate_items) {
                    try writer.writeAll(", ...");
                }
                return writer.writeAll(" }");
            },
            .eu_payload => {
                val = val.castTag(.eu_payload).?.data;
                ty = ty.errorUnionPayload(mod);
            },
            .opt_payload => {
                val = val.castTag(.opt_payload).?.data;
                ty = ty.optionalChild(mod);
            },
        },
        else => switch (mod.intern_pool.indexToKey(val.toIntern())) {
            .int_type,
            .ptr_type,
            .array_type,
            .vector_type,
            .opt_type,
            .anyframe_type,
            .error_union_type,
            .simple_type,
            .struct_type,
            .anon_struct_type,
            .union_type,
            .opaque_type,
            .enum_type,
            .func_type,
            .error_set_type,
            .inferred_error_set_type,
            => return Type.print(val.toType(), writer, mod),
            .undef => return writer.writeAll("undefined"),
            .runtime_value => return writer.writeAll("(runtime value)"),
            .simple_value => |simple_value| switch (simple_value) {
                .empty_struct => return printAggregate(ty, val, writer, level, mod),
                .generic_poison => return writer.writeAll("(generic poison)"),
                else => return writer.writeAll(@tagName(simple_value)),
            },
            .variable => return writer.writeAll("(variable)"),
            .extern_func => |extern_func| return writer.print("(extern function '{s}')", .{
                mod.intern_pool.stringToSlice(mod.declPtr(extern_func.decl).name),
            }),
            .func => |func| return writer.print("(function '{s}')", .{
                mod.intern_pool.stringToSlice(mod.declPtr(mod.funcPtr(func.index).owner_decl).name),
            }),
            .int => |int| switch (int.storage) {
                inline .u64, .i64, .big_int => |x| return writer.print("{}", .{x}),
                .lazy_align => |lazy_ty| return writer.print("{d}", .{
                    lazy_ty.toType().abiAlignment(mod),
                }),
                .lazy_size => |lazy_ty| return writer.print("{d}", .{
                    lazy_ty.toType().abiSize(mod),
                }),
            },
            .err => |err| return writer.print("error.{s}", .{
                mod.intern_pool.stringToSlice(err.name),
            }),
            .error_union => |error_union| switch (error_union.val) {
                .err_name => |err_name| return writer.print("error.{s}", .{
                    mod.intern_pool.stringToSlice(err_name),
                }),
                .payload => |payload| {
                    val = payload.toValue();
                    ty = ty.errorUnionPayload(mod);
                },
            },
            .enum_literal => |enum_literal| return writer.print(".{s}", .{
                mod.intern_pool.stringToSlice(enum_literal),
            }),
            .enum_tag => |enum_tag| {
                if (level == 0) {
                    return writer.writeAll("(enum)");
                }
                const enum_type = mod.intern_pool.indexToKey(ty.toIntern()).enum_type;
                if (enum_type.tagValueIndex(&mod.intern_pool, val.toIntern())) |tag_index| {
                    const tag_name = mod.intern_pool.stringToSlice(enum_type.names[tag_index]);
                    try writer.print(".{}", .{std.zig.fmtId(tag_name)});
                    return;
                }
                try writer.writeAll("@intToEnum(");
                try print(.{
                    .ty = Type.type,
                    .val = enum_tag.ty.toValue(),
                }, writer, level - 1, mod);
                try writer.writeAll(", ");
                try print(.{
                    .ty = mod.intern_pool.typeOf(enum_tag.int).toType(),
                    .val = enum_tag.int.toValue(),
                }, writer, level - 1, mod);
                try writer.writeAll(")");
                return;
            },
            .empty_enum_value => return writer.writeAll("(empty enum value)"),
            .float => |float| switch (float.storage) {
                inline else => |x| return writer.print("{d}", .{@floatCast(f64, x)}),
            },
            .ptr => |ptr| {
                if (ptr.addr == .int) {
                    const i = mod.intern_pool.indexToKey(ptr.addr.int).int;
                    switch (i.storage) {
                        inline else => |addr| return writer.print("{x:0>8}", .{addr}),
                    }
                }

                const ptr_ty = mod.intern_pool.indexToKey(ty.toIntern()).ptr_type;
                if (ptr_ty.flags.size == .Slice) {
                    if (level == 0) {
                        return writer.writeAll(".{ ... }");
                    }
                    const elem_ty = ptr_ty.child.toType();
                    const len = ptr.len.toValue().toUnsignedInt(mod);
                    if (elem_ty.eql(Type.u8, mod)) str: {
                        const max_len = @min(len, max_string_len);
                        var buf: [max_string_len]u8 = undefined;
                        for (buf[0..max_len], 0..) |*c, i| {
                            const elem = try val.elemValue(mod, i);
                            if (elem.isUndef(mod)) break :str;
                            c.* = @intCast(u8, elem.toUnsignedInt(mod));
                        }
                        const truncated = if (len > max_string_len) " (truncated)" else "";
                        return writer.print("\"{}{s}\"", .{ std.zig.fmtEscapes(buf[0..max_len]), truncated });
                    }
                    try writer.writeAll(".{ ");
                    const max_len = @min(len, max_aggregate_items);
                    for (0..max_len) |i| {
                        if (i != 0) try writer.writeAll(", ");
                        try print(.{
                            .ty = elem_ty,
                            .val = try val.elemValue(mod, i),
                        }, writer, level - 1, mod);
                    }
                    if (len > max_aggregate_items) {
                        try writer.writeAll(", ...");
                    }
                    return writer.writeAll(" }");
                }

                switch (ptr.addr) {
                    .decl => |decl_index| {
                        const decl = mod.declPtr(decl_index);
                        if (level == 0) return writer.print("(decl '{s}')", .{mod.intern_pool.stringToSlice(decl.name)});
                        return print(.{
                            .ty = decl.ty,
                            .val = decl.val,
                        }, writer, level - 1, mod);
                    },
                    .mut_decl => |mut_decl| {
                        const decl = mod.declPtr(mut_decl.decl);
                        if (level == 0) return writer.print("(mut decl '{s}')", .{mod.intern_pool.stringToSlice(decl.name)});
                        return print(.{
                            .ty = decl.ty,
                            .val = decl.val,
                        }, writer, level - 1, mod);
                    },
                    .comptime_field => |field_val_ip| {
                        return print(.{
                            .ty = mod.intern_pool.typeOf(field_val_ip).toType(),
                            .val = field_val_ip.toValue(),
                        }, writer, level - 1, mod);
                    },
                    .int => unreachable,
                    .eu_payload => |eu_ip| {
                        try writer.writeAll("(payload of ");
                        try print(.{
                            .ty = mod.intern_pool.typeOf(eu_ip).toType(),
                            .val = eu_ip.toValue(),
                        }, writer, level - 1, mod);
                        try writer.writeAll(")");
                    },
                    .opt_payload => |opt_ip| {
                        try print(.{
                            .ty = mod.intern_pool.typeOf(opt_ip).toType(),
                            .val = opt_ip.toValue(),
                        }, writer, level - 1, mod);
                        try writer.writeAll(".?");
                    },
                    .elem => |elem| {
                        try print(.{
                            .ty = mod.intern_pool.typeOf(elem.base).toType(),
                            .val = elem.base.toValue(),
                        }, writer, level - 1, mod);
                        try writer.print("[{}]", .{elem.index});
                    },
                    .field => |field| {
                        const container_ty = mod.intern_pool.typeOf(field.base).toType();
                        try print(.{
                            .ty = container_ty,
                            .val = field.base.toValue(),
                        }, writer, level - 1, mod);

                        switch (container_ty.zigTypeTag(mod)) {
                            .Struct => {
                                if (container_ty.isTuple(mod)) {
                                    try writer.print("[{d}]", .{field.index});
                                }
                                const field_name_ip = container_ty.structFieldName(field.index, mod);
                                const field_name = mod.intern_pool.stringToSlice(field_name_ip);
                                try writer.print(".{}", .{std.zig.fmtId(field_name)});
                            },
                            .Union => {
                                const field_name_ip = container_ty.unionFields(mod).keys()[field.index];
                                const field_name = mod.intern_pool.stringToSlice(field_name_ip);
                                try writer.print(".{}", .{std.zig.fmtId(field_name)});
                            },
                            .Pointer => {
                                std.debug.assert(container_ty.isSlice(mod));
                                try writer.writeAll(switch (field.index) {
                                    Value.slice_ptr_index => ".ptr",
                                    Value.slice_len_index => ".len",
                                    else => unreachable,
                                });
                            },
                            else => unreachable,
                        }
                    },
                }
            },
            .opt => |opt| switch (opt.val) {
                .none => return writer.writeAll("null"),
                else => |payload| {
                    val = payload.toValue();
                    ty = ty.optionalChild(mod);
                },
            },
            .aggregate => |aggregate| switch (aggregate.storage) {
                .bytes => |bytes| {
                    // Strip the 0 sentinel off of strings before printing
                    const zero_sent = blk: {
                        const sent = ty.sentinel(mod) orelse break :blk false;
                        break :blk sent.eql(Value.zero_u8, Type.u8, mod);
                    };
                    const str = if (zero_sent) bytes[0..bytes.len - 1] else bytes;
                    return writer.print("\"{}\"", .{std.zig.fmtEscapes(str)});
                },
                .elems, .repeated_elem => return printAggregate(ty, val, writer, level, mod),
            },
            .un => |un| {
                try writer.writeAll(".{ ");
                if (level > 0) {
                    try print(.{
                        .ty = ty.unionTagTypeHypothetical(mod),
                        .val = un.tag.toValue(),
                    }, writer, level - 1, mod);
                    try writer.writeAll(" = ");
                    try print(.{
                        .ty = ty.unionFieldType(un.tag.toValue(), mod),
                        .val = un.val.toValue(),
                    }, writer, level - 1, mod);
                } else try writer.writeAll("...");
                return writer.writeAll(" }");
            },
            .memoized_call => unreachable,
        },
    };
}

fn printAggregate(
    ty: Type,
    val: Value,
    writer: anytype,
    level: u8,
    mod: *Module,
) (@TypeOf(writer).Error || Allocator.Error)!void {
    if (level == 0) {
        return writer.writeAll(".{ ... }");
    }
    if (ty.zigTypeTag(mod) == .Struct) {
        try writer.writeAll(".{");
        const max_len = @min(ty.structFieldCount(mod), max_aggregate_items);

        for (0..max_len) |i| {
            if (i != 0) try writer.writeAll(", ");

            const field_name = switch (mod.intern_pool.indexToKey(ty.toIntern())) {
                .struct_type => |x| mod.structPtrUnwrap(x.index).?.fields.keys()[i].toOptional(),
                .anon_struct_type => |x| if (x.isTuple()) .none else x.names[i].toOptional(),
                else => unreachable,
            };

            if (field_name.unwrap()) |name_ip| try writer.print(".{s} = ", .{
                mod.intern_pool.stringToSlice(name_ip),
            });
            try print(.{
                .ty = ty.structFieldType(i, mod),
                .val = try val.fieldValue(mod, i),
            }, writer, level - 1, mod);
        }
        if (ty.structFieldCount(mod) > max_aggregate_items) {
            try writer.writeAll(", ...");
        }
        return writer.writeAll("}");
    } else {
        const elem_ty = ty.elemType2(mod);
        const len = ty.arrayLen(mod);

        if (elem_ty.eql(Type.u8, mod)) str: {
            const max_len = @intCast(usize, std.math.min(len, max_string_len));
            var buf: [max_string_len]u8 = undefined;

            var i: u32 = 0;
            while (i < max_len) : (i += 1) {
                const elem = try val.fieldValue(mod, i);
                if (elem.isUndef(mod)) break :str;
                buf[i] = std.math.cast(u8, elem.toUnsignedInt(mod)) orelse break :str;
            }

            const truncated = if (len > max_string_len) " (truncated)" else "";
            return writer.print("\"{}{s}\"", .{ std.zig.fmtEscapes(buf[0..max_len]), truncated });
        }

        try writer.writeAll(".{ ");

        const max_len = std.math.min(len, max_aggregate_items);
        var i: u32 = 0;
        while (i < max_len) : (i += 1) {
            if (i != 0) try writer.writeAll(", ");
            try print(.{
                .ty = elem_ty,
                .val = try val.fieldValue(mod, i),
            }, writer, level - 1, mod);
        }
        if (len > max_aggregate_items) {
            try writer.writeAll(", ...");
        }
        return writer.writeAll(" }");
    }
}
