//! Optional write-rules layer. Plugs into Store via a single ward runner.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Store = @import("store.zig").Store;
const WardContext = @import("store.zig").WardContext;
const WardOutcome = @import("store.zig").WardOutcome;
const WardKind = @import("store.zig").WardKind;
const Value = @import("value.zig").Value;

pub const RuleId = u64;

pub const WardRuleFn = *const fn (ctx: ?*anyopaque, context: WardContext) WardOutcome;
pub const WardPropRuleFn = *const fn (ctx: ?*anyopaque, value: Value) WardOutcome;

const RuleScope = enum { global, kind, prop };

const RuleEntry = struct {
    id: RuleId,
    scope: RuleScope,
    kind: WardKind = .set_prop,
    prop_name: ?[]u8 = null,
    ctx: ?*anyopaque,
    /// For global/kind rules.
    rule: ?WardRuleFn = null,
    /// For prop rules.
    prop_rule: ?WardPropRuleFn = null,
};

pub const WardOptions = struct {
    on_deny: ?*const fn (ctx: ?*anyopaque, context: WardContext, reason: ?[]const u8) void = null,
    on_deny_ctx: ?*anyopaque = null,
};

pub const WardLink = struct {
    store: *Store,
    allocator: Allocator,
    rules: std.ArrayList(RuleEntry) = .empty,
    held: bool = false,
    disposed: bool = false,
    next_id: RuleId = 1,
    options: WardOptions,

    pub fn attach(store: *Store, allocator: Allocator, options: WardOptions) !*WardLink {
        const self = try allocator.create(WardLink);
        errdefer allocator.destroy(self);
        self.* = .{
            .store = store,
            .allocator = allocator,
            .options = options,
        };
        try store.registerWardRunner(self, runner);
        return self;
    }

    pub fn dispose(self: *WardLink) void {
        if (self.disposed) return;
        self.disposed = true;
        self.clearRules();
        self.store.unregisterWardRunner();
        self.rules.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn hold(self: *WardLink) void {
        self.held = true;
    }

    pub fn unhold(self: *WardLink) void {
        self.held = false;
    }

    pub fn isHeld(self: *const WardLink) bool {
        return self.held;
    }

    pub fn isDisposed(self: *const WardLink) bool {
        return self.disposed;
    }

    pub fn ruleCount(self: *const WardLink) usize {
        return self.rules.items.len;
    }

    pub fn addGlobalRule(self: *WardLink, ctx: ?*anyopaque, rule: WardRuleFn) !RuleId {
        try self.ensureActive();
        const id = self.allocId();
        try self.rules.append(self.allocator, .{
            .id = id,
            .scope = .global,
            .ctx = ctx,
            .rule = rule,
        });
        return id;
    }

    pub fn addKindRule(self: *WardLink, kind: WardKind, ctx: ?*anyopaque, rule: WardRuleFn) !RuleId {
        try self.ensureActive();
        const id = self.allocId();
        try self.rules.append(self.allocator, .{
            .id = id,
            .scope = .kind,
            .kind = kind,
            .ctx = ctx,
            .rule = rule,
        });
        return id;
    }

    pub fn addPropRule(self: *WardLink, prop_name: []const u8, ctx: ?*anyopaque, rule: WardPropRuleFn) !RuleId {
        try self.ensureActive();
        if (isReservedKindName(prop_name)) return error.ReservedPropName;
        const id = self.allocId();
        const owned_name = try self.allocator.dupe(u8, prop_name);
        errdefer self.allocator.free(owned_name);
        try self.rules.append(self.allocator, .{
            .id = id,
            .scope = .prop,
            .prop_name = owned_name,
            .ctx = ctx,
            .prop_rule = rule,
        });
        return id;
    }

    pub fn removeRule(self: *WardLink, id: RuleId) void {
        for (self.rules.items, 0..) |entry, i| {
            if (entry.id == id) {
                const removed = self.rules.orderedRemove(i);
                if (removed.prop_name) |n| self.allocator.free(n);
                return;
            }
        }
    }

    pub fn clearRules(self: *WardLink) void {
        for (self.rules.items) |entry| {
            if (entry.prop_name) |n| self.allocator.free(n);
        }
        self.rules.clearRetainingCapacity();
    }

    fn ensureActive(self: *WardLink) !void {
        if (self.disposed) return error.WardDisposed;
    }

    fn allocId(self: *WardLink) RuleId {
        const id = self.next_id;
        self.next_id += 1;
        return id;
    }

    fn runner(ctx: ?*anyopaque, context: WardContext) WardOutcome {
        const self: *WardLink = @ptrCast(@alignCast(ctx.?));
        if (self.held or self.rules.items.len == 0) return .{ .allow = null };

        const outcome = runRules(self.rules.items, context);
        if (outcome == .deny) {
            if (self.options.on_deny) |cb| {
                cb(self.options.on_deny_ctx, context, outcome.deny);
            }
        }
        return outcome;
    }
};

fn isReservedKindName(name: []const u8) bool {
    return std.mem.eql(u8, name, "setProp") or
        std.mem.eql(u8, name, "addProp") or
        std.mem.eql(u8, name, "setProps") or
        std.mem.eql(u8, name, "set_prop") or
        std.mem.eql(u8, name, "add_prop") or
        std.mem.eql(u8, name, "set_props");
}

fn runRules(rules: []const RuleEntry, context: WardContext) WardOutcome {
    var current = context;
    var transformed: ?Value = null;

    // global → kind → prop, insertion order within each group
    for ([_]RuleScope{ .global, .kind, .prop }) |scope| {
        for (rules) |entry| {
            if (entry.scope != scope) continue;
            if (!matches(entry, current)) continue;

            const outcome = switch (entry.scope) {
                .prop => entry.prop_rule.?(entry.ctx, switch (current) {
                    .set_prop => |sp| sp.value,
                    .add_prop => |ap| ap.value,
                    .set_props => return .{ .deny = "prop rules do not apply to set_props" },
                }),
                else => entry.rule.?(entry.ctx, current),
            };

            switch (outcome) {
                .deny => return outcome,
                .allow => |maybe| {
                    if (maybe) |v| {
                        transformed = v;
                        current = switch (current) {
                            .set_prop => |sp| .{ .set_prop = .{ .name = sp.name, .value = v } },
                            .add_prop => |ap| .{ .add_prop = .{ .name = ap.name, .value = v } },
                            .set_props => current, // batch transform unsupported
                        };
                    }
                },
            }
        }
    }

    return .{ .allow = transformed };
}

fn matches(entry: RuleEntry, context: WardContext) bool {
    return switch (entry.scope) {
        .global => true,
        .kind => switch (context) {
            .set_prop => entry.kind == .set_prop,
            .add_prop => entry.kind == .add_prop,
            .set_props => entry.kind == .set_props,
        },
        .prop => switch (context) {
            .set_prop => |sp| entry.prop_name != null and std.mem.eql(u8, entry.prop_name.?, sp.name),
            .add_prop => |ap| entry.prop_name != null and std.mem.eql(u8, entry.prop_name.?, ap.name),
            .set_props => false,
        },
    };
}

fn denyNegative(_: ?*anyopaque, value: Value) WardOutcome {
    if (value == .int and value.int < 0) return .{ .deny = "counter must be >= 0" };
    return .{ .allow = null };
}

fn silentIncident(_: ?*anyopaque, _: []const u8) void {}

test "ward denies prop write" {
    const gpa = std.testing.allocator;
    const store = try Store.create(gpa, .{
        .name = "warded",
        .incidents = .{
            .on_warn = silentIncident,
            .on_error = silentIncident,
        },
    });
    defer store.destroy();

    const link = try WardLink.attach(store, gpa, .{});
    defer link.dispose();

    store.addProp("counter", Value.fromInt(0));
    _ = try link.addPropRule("counter", null, denyNegative);

    store.setProp("counter", Value.fromInt(-1));
    try std.testing.expectEqual(@as(i64, 0), store.propRef("counter").?.int);

    store.setProp("counter", Value.fromInt(3));
    try std.testing.expectEqual(@as(i64, 3), store.propRef("counter").?.int);
}
