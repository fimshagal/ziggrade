//! Optional comptime-typed facade over the dynamic Store.
//!
//! Declares a schema struct once; get/set become type-checked at compile time.
//! Reactivity is unchanged: this only forwards to Store (listeners, batch, ward
//! still see the same string-keyed props). Dynamic props remain available via `.store`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Store = @import("store.zig").Store;
const StoreOptions = @import("store.zig").StoreOptions;
const PatchEntry = @import("store.zig").PatchEntry;
const Value = @import("value.zig").Value;

fn assertSupported(comptime T: type) void {
    switch (@typeInfo(T)) {
        .bool, .int, .float => {},
        .pointer => |p| {
            if (p.size != .slice or p.child != u8) {
                @compileError("TypedStore supports []const u8 / []u8 string slices, not " ++ @typeName(T));
            }
        },
        else => @compileError("TypedStore unsupported field type: " ++ @typeName(T)),
    }
}

fn zigToValue(allocator: Allocator, comptime T: type, value: T) Allocator.Error!Value {
    assertSupported(T);
    return switch (@typeInfo(T)) {
        .bool => Value.fromBool(value),
        .int => Value.fromInt(@intCast(value)),
        .float => Value.fromFloat(@floatCast(value)),
        .pointer => try Value.fromString(allocator, value),
        else => unreachable,
    };
}

fn valueToZig(comptime T: type, value: Value) T {
    assertSupported(T);
    return switch (@typeInfo(T)) {
        .bool => value.bool,
        .int => @intCast(value.int),
        .float => @floatCast(value.float),
        .pointer => value.string,
        else => unreachable,
    };
}

fn freeTemp(allocator: Allocator, comptime T: type, value: *Value) void {
    switch (@typeInfo(T)) {
        .pointer => value.deinit(allocator),
        else => {},
    }
}

/// `Schema` is a struct of supported field types (`bool`, ints, floats, `[]const u8`).
/// Example:
/// ```zig
/// const Sim = struct { tick: i64 = 0, running: bool = true, name: []const u8 = "sim" };
/// var ts = try TypedStore(Sim).create(gpa, .{}, .{});
/// ts.set(.tick, 1);
/// const n = ts.get(.tick);
/// ```
pub fn TypedStore(comptime Schema: type) type {
    if (@typeInfo(Schema) != .@"struct") {
        @compileError("TypedStore schema must be a struct");
    }
    inline for (std.meta.fields(Schema)) |field| {
        assertSupported(field.type);
    }

    return struct {
        const Self = @This();

        allocator: Allocator,
        store: *Store,
        owns_store: bool,

        pub const Field = std.meta.FieldEnum(Schema);

        pub fn FieldType(comptime field: Field) type {
            return std.meta.fieldInfo(Schema, field).type;
        }

        /// Creates an owned Store and seeds every schema field from `initial`.
        pub fn create(allocator: Allocator, options: StoreOptions, initial: Schema) !*Self {
            const raw = try Store.create(allocator, options);
            errdefer raw.destroy();

            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);
            self.* = .{
                .allocator = allocator,
                .store = raw,
                .owns_store = true,
            };

            inline for (std.meta.fields(Schema)) |field| {
                var tmp = try zigToValue(allocator, field.type, @field(initial, field.name));
                defer freeTemp(allocator, field.type, &tmp);
                raw.addProp(field.name, tmp);
            }
            return self;
        }

        /// Wraps an existing store. Does not add missing schema props; call `ensure` if needed.
        pub fn wrap(allocator: Allocator, store: *Store) !*Self {
            const self = try allocator.create(Self);
            self.* = .{
                .allocator = allocator,
                .store = store,
                .owns_store = false,
            };
            return self;
        }

        /// Adds any schema props that are missing (keeps existing values).
        pub fn ensure(self: *Self, initial: Schema) void {
            inline for (std.meta.fields(Schema)) |field| {
                if (self.store.hasProp(field.name)) continue;
                var tmp = zigToValue(self.allocator, field.type, @field(initial, field.name)) catch return;
                defer freeTemp(self.allocator, field.type, &tmp);
                self.store.addProp(field.name, tmp);
            }
        }

        pub fn destroy(self: *Self) void {
            if (self.owns_store) self.store.destroy();
            self.allocator.destroy(self);
        }

        /// Borrowed for strings (valid until the next write to that prop).
        pub fn get(self: *Self, comptime field: Field) FieldType(field) {
            const T = FieldType(field);
            const name = @tagName(field);
            const ref = self.store.propRef(name) orelse {
                @panic("TypedStore: missing schema prop — call ensure() or create()");
            };
            return valueToZig(T, ref);
        }

        pub fn set(self: *Self, comptime field: Field, value: FieldType(field)) void {
            const T = FieldType(field);
            const name = @tagName(field);
            var tmp = zigToValue(self.allocator, T, value) catch return;
            defer freeTemp(self.allocator, T, &tmp);
            self.store.setProp(name, tmp);
        }

        /// Batch-set several schema fields. Pass a struct with a subset of Schema fields.
        pub fn setPartial(self: *Self, partial: anytype) void {
            const Partial = @TypeOf(partial);
            if (@typeInfo(Partial) != .@"struct") {
                @compileError("setPartial expects a struct literal");
            }
            const n = std.meta.fields(Partial).len;
            var entries: [n]PatchEntry = undefined;
            var temps: [n]Value = undefined;
            var count: usize = 0;

            inline for (std.meta.fields(Partial)) |field| {
                const ST = @FieldType(Schema, field.name);
                const coerced: ST = @field(partial, field.name);
                temps[count] = zigToValue(self.allocator, ST, coerced) catch {
                    for (temps[0..count]) |*tmp| tmp.deinit(self.allocator);
                    return;
                };
                entries[count] = .{ .name = field.name, .value = temps[count] };
                count += 1;
            }

            self.store.setProps(entries[0..count]);
            for (temps[0..count]) |*tmp| tmp.deinit(self.allocator);
        }

        pub fn listen(
            self: *Self,
            comptime field: Field,
            ctx: ?*anyopaque,
            fn_ptr: @import("store.zig").PropListenerFn,
        ) ?@import("store.zig").ListenerId {
            return self.store.addPropListener(@tagName(field), ctx, fn_ptr);
        }
    };
}

const Probe = struct { hits: usize = 0 };

fn onTick(ctx: ?*anyopaque, value: Value) void {
    _ = value;
    const probe: *Probe = @ptrCast(@alignCast(ctx.?));
    probe.hits += 1;
}

test "typed store get set batch and listen" {
    const gpa = std.testing.allocator;
    const Sim = struct {
        tick: i64 = 0,
        running: bool = true,
        name: []const u8 = "sim",
    };

    const ts = try TypedStore(Sim).create(gpa, .{ .name = "typed" }, .{});
    defer ts.destroy();

    try std.testing.expectEqual(@as(i64, 0), ts.get(.tick));
    try std.testing.expectEqual(true, ts.get(.running));
    try std.testing.expectEqualStrings("sim", ts.get(.name));

    var probe: Probe = .{};
    _ = ts.listen(.tick, &probe, onTick);

    ts.set(.tick, 3);
    try std.testing.expectEqual(@as(i64, 3), ts.get(.tick));
    try std.testing.expectEqual(@as(usize, 1), probe.hits);

    ts.setPartial(.{ .tick = 4, .running = false });
    try std.testing.expectEqual(@as(i64, 4), ts.get(.tick));
    try std.testing.expectEqual(false, ts.get(.running));
    try std.testing.expectEqual(@as(usize, 2), probe.hits);

    // Dynamic prop still works alongside the schema.
    ts.store.addProp("extra", Value.fromInt(9));
    try std.testing.expectEqual(@as(i64, 9), ts.store.propRef("extra").?.int);
}
