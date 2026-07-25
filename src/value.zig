//! Runtime values for Ziggrade store props.
//! JSON-friendly by construction: null, bool, int, float, string, array, object.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const ValueType = enum {
    null,
    bool,
    int,
    float,
    string,
    array,
    object,
};

pub const Value = union(ValueType) {
    null: void,
    bool: bool,
    int: i64,
    float: f64,
    string: []u8,
    array: ArrayList,
    object: ObjectMap,

    pub const ArrayList = std.ArrayList(Value);
    pub const ObjectMap = std.StringArrayHashMapUnmanaged(Value);

    pub fn nullValue() Value {
        return .{ .null = {} };
    }

    pub fn fromBool(v: bool) Value {
        return .{ .bool = v };
    }

    pub fn fromInt(v: i64) Value {
        return .{ .int = v };
    }

    pub fn fromFloat(v: f64) Value {
        return .{ .float = v };
    }

    pub fn fromString(allocator: Allocator, s: []const u8) Allocator.Error!Value {
        return .{ .string = try allocator.dupe(u8, s) };
    }

    pub fn emptyArray() Value {
        return .{ .array = .empty };
    }

    pub fn emptyObject() Value {
        return .{ .object = .empty };
    }

    pub fn valueType(self: Value) ValueType {
        return std.meta.activeTag(self);
    }

    /// Scalars skip write+notify when equal (Zig treats bool as scalar; TS tardigrade does not).
    pub fn isScalar(self: Value) bool {
        return switch (self) {
            .null, .bool, .int, .float, .string => true,
            .array, .object => false,
        };
    }

    pub fn eql(self: Value, other: Value) bool {
        if (std.meta.activeTag(self) != std.meta.activeTag(other)) return false;
        return switch (self) {
            .null => true,
            .bool => self.bool == other.bool,
            .int => self.int == other.int,
            .float => self.float == other.float,
            .string => std.mem.eql(u8, self.string, other.string),
            .array => {
                if (self.array.items.len != other.array.items.len) return false;
                for (self.array.items, other.array.items) |a, b| {
                    if (!a.eql(b)) return false;
                }
                return true;
            },
            .object => {
                if (self.object.count() != other.object.count()) return false;
                var it = self.object.iterator();
                while (it.next()) |entry| {
                    const ov = other.object.get(entry.key_ptr.*) orelse return false;
                    if (!entry.value_ptr.eql(ov)) return false;
                }
                return true;
            },
        };
    }

    pub fn deinit(self: *Value, allocator: Allocator) void {
        switch (self.*) {
            .null, .bool, .int, .float => {},
            .string => allocator.free(self.string),
            .array => {
                for (self.array.items) |*item| item.deinit(allocator);
                self.array.deinit(allocator);
            },
            .object => {
                var it = self.object.iterator();
                while (it.next()) |entry| {
                    allocator.free(entry.key_ptr.*);
                    entry.value_ptr.deinit(allocator);
                }
                self.object.deinit(allocator);
            },
        }
        self.* = .{ .null = {} };
    }

    pub fn clone(self: Value, allocator: Allocator) Allocator.Error!Value {
        return switch (self) {
            .null => .{ .null = {} },
            .bool => |v| .{ .bool = v },
            .int => |v| .{ .int = v },
            .float => |v| .{ .float = v },
            .string => |s| .{ .string = try allocator.dupe(u8, s) },
            .array => |list| blk: {
                var out: ArrayList = .empty;
                errdefer {
                    for (out.items) |*item| item.deinit(allocator);
                    out.deinit(allocator);
                }
                try out.ensureTotalCapacity(allocator, list.items.len);
                for (list.items) |item| {
                    out.appendAssumeCapacity(try item.clone(allocator));
                }
                break :blk .{ .array = out };
            },
            .object => |map| blk: {
                var out: ObjectMap = .empty;
                errdefer {
                    var it = out.iterator();
                    while (it.next()) |entry| {
                        allocator.free(entry.key_ptr.*);
                        entry.value_ptr.deinit(allocator);
                    }
                    out.deinit(allocator);
                }
                try out.ensureTotalCapacity(allocator, map.count());
                var it = map.iterator();
                while (it.next()) |entry| {
                    const key = try allocator.dupe(u8, entry.key_ptr.*);
                    errdefer allocator.free(key);
                    var val = try entry.value_ptr.clone(allocator);
                    errdefer val.deinit(allocator);
                    try out.put(allocator, key, val);
                }
                break :blk .{ .object = out };
            },
        };
    }

    pub fn toJson(self: Value, allocator: Allocator) Allocator.Error![]u8 {
        var list: std.ArrayList(u8) = .empty;
        errdefer list.deinit(allocator);
        try writeJson(self, allocator, &list);
        return try list.toOwnedSlice(allocator);
    }

    pub fn fromJson(allocator: Allocator, bytes: []const u8) !Value {
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
        defer parsed.deinit();
        return try fromJsonValue(allocator, parsed.value);
    }

    fn writeJson(self: Value, allocator: Allocator, list: *std.ArrayList(u8)) Allocator.Error!void {
        switch (self) {
            .null => try list.appendSlice(allocator, "null"),
            .bool => |v| try list.appendSlice(allocator, if (v) "true" else "false"),
            .int => |v| {
                var buf: [32]u8 = undefined;
                const s = std.fmt.bufPrint(&buf, "{d}", .{v}) catch unreachable;
                try list.appendSlice(allocator, s);
            },
            .float => |v| {
                var buf: [64]u8 = undefined;
                const s = std.fmt.bufPrint(&buf, "{d}", .{v}) catch unreachable;
                try list.appendSlice(allocator, s);
            },
            .string => |s| try appendJsonString(allocator, list, s),
            .array => |arr| {
                try list.append(allocator, '[');
                for (arr.items, 0..) |item, i| {
                    if (i != 0) try list.append(allocator, ',');
                    try writeJson(item, allocator, list);
                }
                try list.append(allocator, ']');
            },
            .object => |map| {
                try list.append(allocator, '{');
                var first = true;
                var it = map.iterator();
                while (it.next()) |entry| {
                    if (!first) try list.append(allocator, ',');
                    first = false;
                    try appendJsonString(allocator, list, entry.key_ptr.*);
                    try list.append(allocator, ':');
                    try writeJson(entry.value_ptr.*, allocator, list);
                }
                try list.append(allocator, '}');
            },
        }
    }

    fn appendJsonString(allocator: Allocator, list: *std.ArrayList(u8), s: []const u8) Allocator.Error!void {
        try list.append(allocator, '"');
        for (s) |c| {
            switch (c) {
                '"' => try list.appendSlice(allocator, "\\\""),
                '\\' => try list.appendSlice(allocator, "\\\\"),
                '\n' => try list.appendSlice(allocator, "\\n"),
                '\r' => try list.appendSlice(allocator, "\\r"),
                '\t' => try list.appendSlice(allocator, "\\t"),
                else => {
                    if (c < 0x20) {
                        var buf: [6]u8 = undefined;
                        const esc = std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{c}) catch unreachable;
                        try list.appendSlice(allocator, esc);
                    } else {
                        try list.append(allocator, c);
                    }
                },
            }
        }
        try list.append(allocator, '"');
    }

    fn fromJsonValue(allocator: Allocator, jv: std.json.Value) !Value {
        return switch (jv) {
            .null => .{ .null = {} },
            .bool => |v| .{ .bool = v },
            .integer => |v| .{ .int = v },
            .float => |v| .{ .float = v },
            .number_string => |s| blk: {
                if (std.fmt.parseInt(i64, s, 10)) |i| {
                    break :blk .{ .int = i };
                } else |_| {}
                break :blk .{ .float = try std.fmt.parseFloat(f64, s) };
            },
            .string => |s| .{ .string = try allocator.dupe(u8, s) },
            .array => |arr| blk: {
                var out: ArrayList = .empty;
                errdefer {
                    for (out.items) |*item| item.deinit(allocator);
                    out.deinit(allocator);
                }
                try out.ensureTotalCapacity(allocator, arr.items.len);
                for (arr.items) |item| {
                    out.appendAssumeCapacity(try fromJsonValue(allocator, item));
                }
                break :blk .{ .array = out };
            },
            .object => |map| blk: {
                var out: ObjectMap = .empty;
                errdefer {
                    var it = out.iterator();
                    while (it.next()) |entry| {
                        allocator.free(entry.key_ptr.*);
                        entry.value_ptr.deinit(allocator);
                    }
                    out.deinit(allocator);
                }
                var it = map.iterator();
                while (it.next()) |entry| {
                    const key = try allocator.dupe(u8, entry.key_ptr.*);
                    errdefer allocator.free(key);
                    var val = try fromJsonValue(allocator, entry.value_ptr.*);
                    errdefer val.deinit(allocator);
                    try out.put(allocator, key, val);
                }
                break :blk .{ .object = out };
            },
        };
    }
};

test "value clone and eql" {
    const gpa = std.testing.allocator;
    var obj = Value.emptyObject();
    defer obj.deinit(gpa);
    try obj.object.put(gpa, try gpa.dupe(u8, "n"), Value.fromInt(1));
    try obj.object.put(gpa, try gpa.dupe(u8, "ok"), Value.fromBool(true));

    var cloned = try obj.clone(gpa);
    defer cloned.deinit(gpa);
    try std.testing.expect(obj.eql(cloned));

    const json = try obj.toJson(gpa);
    defer gpa.free(json);
    var parsed = try Value.fromJson(gpa, json);
    defer parsed.deinit(gpa);
    try std.testing.expect(obj.eql(parsed));
}
