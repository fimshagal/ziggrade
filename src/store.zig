//! Ziggrade core store: typed props, observers, batch writes, ward extension point.
//! Optional layers (ward / history / persist) attach without forking this module.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = @import("value.zig").Value;
const ValueType = @import("value.zig").ValueType;
const IncidentsHandler = @import("incidents.zig").IncidentsHandler;

pub const SessionKey = usize;

var next_session: SessionKey = 1;

pub const StoreOptions = struct {
    name: ?[]const u8 = null,
    emit_errors: bool = false,
    incidents: ?IncidentsHandler = null,
};

pub const Prop = struct {
    name: []u8,
    value: Value,
    locked_type: ValueType,
    is_value_scalar: bool,
};

pub const PatchEntry = struct {
    name: []const u8,
    value: Value,
};

/// Global listener change payload.
/// - `single`: one prop or resolver notification
/// - `batch`: setProps notify-once (names parallel to values)
pub const Change = union(enum) {
    single: struct {
        name: []const u8,
        value: Value,
    },
    batch: struct {
        names: []const []const u8,
        values: []const Value,
    },
};

pub const PropListenerFn = *const fn (ctx: ?*anyopaque, value: Value) void;
pub const GlobalListenerFn = *const fn (ctx: ?*anyopaque, change: Change) void;
pub const ResolverFn = *const fn (ctx: ?*anyopaque, store: *Store) anyerror!Value;
pub const ResolverListenerFn = *const fn (ctx: ?*anyopaque, value: Value) void;

pub const ListenerId = u64;

const PropListener = struct {
    id: ListenerId,
    ctx: ?*anyopaque,
    fn_ptr: PropListenerFn,
};

const GlobalListener = struct {
    id: ListenerId,
    ctx: ?*anyopaque,
    fn_ptr: GlobalListenerFn,
};

const ResolverListener = struct {
    id: ListenerId,
    ctx: ?*anyopaque,
    fn_ptr: ResolverListenerFn,
};

const Resolver = struct {
    ctx: ?*anyopaque,
    fn_ptr: ResolverFn,
};

pub const WardKind = enum { set_prop, add_prop, set_props };

pub const WardContext = union(WardKind) {
    set_prop: struct { name: []const u8, value: Value },
    add_prop: struct { name: []const u8, value: Value },
    set_props: struct { patch: []const PatchEntry },
};

pub const WardOutcome = union(enum) {
    allow: ?Value,
    deny: ?[]const u8,
};

pub const WardRunner = *const fn (ctx: ?*anyopaque, context: WardContext) WardOutcome;

pub const Store = struct {
    allocator: Allocator,
    session_key: SessionKey,
    name: []u8,
    alive: bool = true,
    emit_errors: bool,
    incidents: IncidentsHandler,

    props: std.StringArrayHashMapUnmanaged(Prop) = .empty,
    prop_listeners: std.StringArrayHashMapUnmanaged(std.ArrayList(PropListener)) = .empty,
    global_listeners: std.ArrayList(GlobalListener) = .empty,
    resolvers: std.StringArrayHashMapUnmanaged(Resolver) = .empty,
    resolver_listeners: std.StringArrayHashMapUnmanaged(std.ArrayList(ResolverListener)) = .empty,

    merge_agent: ?*Store = null,
    ward_runner: ?WardRunner = null,
    ward_ctx: ?*anyopaque = null,
    ward_running: bool = false,

    next_listener_id: ListenerId = 1,

    pub fn create(allocator: Allocator, options: StoreOptions) Allocator.Error!*Store {
        const self = try allocator.create(Store);
        errdefer allocator.destroy(self);

        const session = next_session;
        next_session += 1;

        const name = if (options.name) |n|
            try allocator.dupe(u8, n)
        else
            try std.fmt.allocPrint(allocator, "ziggrade-{d}", .{session});
        errdefer allocator.free(name);

        self.* = .{
            .allocator = allocator,
            .session_key = session,
            .name = name,
            .emit_errors = options.emit_errors,
            .incidents = options.incidents orelse .{ .emit_errors = options.emit_errors },
        };
        return self;
    }

    pub fn destroy(self: *Store) void {
        if (self.alive) {
            self.reset();
        } else {
            // kill() already reset contents; still need to free containers
            self.freeContainers();
        }
        self.allocator.free(self.name);
        self.allocator.destroy(self);
    }

    fn freeContainers(self: *Store) void {
        self.props.deinit(self.allocator);
        self.props = .empty;
        self.prop_listeners.deinit(self.allocator);
        self.prop_listeners = .empty;
        self.global_listeners.deinit(self.allocator);
        self.global_listeners = .empty;
        self.resolvers.deinit(self.allocator);
        self.resolvers = .empty;
        self.resolver_listeners.deinit(self.allocator);
        self.resolver_listeners = .empty;
    }

    pub fn isAlive(self: *const Store) bool {
        return self.alive;
    }

    pub fn getName(self: *const Store) []const u8 {
        return self.name;
    }

    pub fn getSessionKey(self: *const Store) SessionKey {
        return self.session_key;
    }

    // --- props ---

    pub fn hasProp(self: *Store, name: []const u8) bool {
        if (!self.ensureAlive()) return false;
        return self.props.contains(name);
    }

    pub fn addProp(self: *Store, name: []const u8, value: Value) void {
        if (!self.ensureAlive()) return;
        if (!self.silentAddProp(name, value)) return;
        self.handleOnSetProp(self.props.getPtr(name).?);
    }

    pub fn setProp(self: *Store, name: []const u8, value: Value) void {
        if (!self.ensureAlive()) return;
        if (self.writeProp(name, value)) {
            self.handleOnSetProp(self.props.getPtr(name).?);
        }
    }

    /// Write-all-then-notify. Global listeners fire once with `.batch`.
    pub fn setProps(self: *Store, patch: []const PatchEntry) void {
        if (!self.ensureAlive()) return;

        const batch_outcome = self.runWard(.{ .set_props = .{ .patch = patch } });
        if (batch_outcome) |outcome| {
            switch (outcome) {
                .deny => |reason| {
                    self.reportDeny("Ward denied batch update", reason);
                    return;
                },
                .allow => {},
            }
        }

        var updated_names: std.ArrayList([]const u8) = .empty;
        defer updated_names.deinit(self.allocator);
        var updated_values: std.ArrayList(Value) = .empty;
        defer updated_values.deinit(self.allocator);

        for (patch) |entry| {
            if (self.writeProp(entry.name, entry.value)) {
                const slot = self.props.getPtr(entry.name).?;
                updated_names.append(self.allocator, slot.name) catch {
                    self.incidents.err("Ziggrade: OOM while collecting batch updates");
                    return;
                };
                updated_values.append(self.allocator, slot.value) catch {
                    self.incidents.err("Ziggrade: OOM while collecting batch updates");
                    return;
                };
            }
        }

        if (updated_names.items.len == 0) return;

        for (updated_names.items) |n| {
            self.notifyPropListeners(self.props.getPtr(n).?);
        }

        const change = Change{ .batch = .{
            .names = updated_names.items,
            .values = updated_values.items,
        } };
        self.notifyGlobal(change);
    }

    pub fn removeProp(self: *Store, name: []const u8) void {
        if (!self.ensureAlive()) return;
        const kv = self.props.fetchSwapRemove(name) orelse {
            self.incidents.err("Prop can't be deleted, it does not exist");
            return;
        };
        self.removeAllPropListeners(kv.key);
        self.allocator.free(kv.key);
        var slot = kv.value;
        self.allocator.free(slot.name);
        slot.value.deinit(self.allocator);
    }

    pub fn removeAllProps(self: *Store) void {
        if (!self.ensureAlive()) return;
        while (self.props.count() > 0) {
            const key = self.props.keys()[0];
            self.removeProp(key);
        }
    }

    /// Borrowed internal value. Invalidated by the next mutating write to this prop.
    pub fn propRef(self: *Store, name: []const u8) ?Value {
        if (!self.ensureAlive()) return null;
        const slot = self.props.getPtr(name) orelse {
            self.incidents.err("Prop wasn't registered. Add it first");
            return null;
        };
        return slot.value;
    }

    /// Cloned value; caller must `deinit`.
    pub fn getProp(self: *Store, name: []const u8) ?Value {
        const ref = self.propRef(name) orelse return null;
        return ref.clone(self.allocator) catch {
            self.incidents.err("Ziggrade: OOM cloning prop");
            return null;
        };
    }

    /// Snapshot of all props (deep clones). Caller owns the map and every value/key.
    pub fn propsSnapshot(self: *Store) Allocator.Error!Value.ObjectMap {
        var out: Value.ObjectMap = .empty;
        errdefer {
            var it = out.iterator();
            while (it.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                entry.value_ptr.deinit(self.allocator);
            }
            out.deinit(self.allocator);
        }
        if (!self.alive) return out;

        try out.ensureTotalCapacity(self.allocator, self.props.count());
        var it = self.props.iterator();
        while (it.next()) |entry| {
            const key = try self.allocator.dupe(u8, entry.key_ptr.*);
            errdefer self.allocator.free(key);
            var val = try entry.value_ptr.value.clone(self.allocator);
            errdefer val.deinit(self.allocator);
            try out.put(self.allocator, key, val);
        }
        return out;
    }

    pub fn freePropsSnapshot(self: *Store, map: *Value.ObjectMap) void {
        var it = map.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        map.deinit(self.allocator);
        map.* = .empty;
    }

    // --- listeners ---

    pub fn addPropListener(self: *Store, name: []const u8, ctx: ?*anyopaque, fn_ptr: PropListenerFn) ?ListenerId {
        if (!self.ensureAlive()) return null;
        if (!self.props.contains(name)) {
            self.incidents.err("Prop wasn't registered. Add it first");
            return null;
        }
        const list = blk: {
            if (self.prop_listeners.getPtr(name)) |existing| break :blk existing;
            const key = self.allocator.dupe(u8, name) catch {
                self.incidents.err("Ziggrade: OOM adding prop listener");
                return null;
            };
            self.prop_listeners.put(self.allocator, key, .empty) catch {
                self.allocator.free(key);
                self.incidents.err("Ziggrade: OOM adding prop listener");
                return null;
            };
            break :blk self.prop_listeners.getPtr(name).?;
        };
        const id = self.allocListenerId();
        list.append(self.allocator, .{ .id = id, .ctx = ctx, .fn_ptr = fn_ptr }) catch {
            self.incidents.err("Ziggrade: OOM adding prop listener");
            return null;
        };
        return id;
    }

    pub fn removePropListener(self: *Store, name: []const u8, id: ListenerId) void {
        if (!self.ensureAlive()) return;
        const list = self.prop_listeners.getPtr(name) orelse return;
        for (list.items, 0..) |listener, i| {
            if (listener.id == id) {
                _ = list.orderedRemove(i);
                return;
            }
        }
    }

    pub fn removeAllPropListeners(self: *Store, name: []const u8) void {
        if (!self.alive) return;
        const kv = self.prop_listeners.fetchSwapRemove(name) orelse return;
        self.allocator.free(kv.key);
        var list = kv.value;
        list.deinit(self.allocator);
    }

    pub fn addListener(self: *Store, ctx: ?*anyopaque, fn_ptr: GlobalListenerFn) ?ListenerId {
        if (!self.ensureAlive()) return null;
        const id = self.allocListenerId();
        self.global_listeners.append(self.allocator, .{ .id = id, .ctx = ctx, .fn_ptr = fn_ptr }) catch {
            self.incidents.err("Ziggrade: OOM adding listener");
            return null;
        };
        return id;
    }

    pub fn removeListener(self: *Store, id: ListenerId) void {
        if (!self.ensureAlive()) return;
        for (self.global_listeners.items, 0..) |listener, i| {
            if (listener.id == id) {
                _ = self.global_listeners.orderedRemove(i);
                return;
            }
        }
    }

    pub fn removeAllListeners(self: *Store) void {
        if (!self.ensureAlive()) return;
        self.global_listeners.clearRetainingCapacity();
    }

    // --- resolvers (sync; call when you need derived / side work) ---

    pub fn addResolver(self: *Store, name: []const u8, ctx: ?*anyopaque, fn_ptr: ResolverFn) void {
        if (!self.ensureAlive()) return;
        if (self.resolvers.contains(name)) {
            self.incidents.err("Resolver has already been planted");
            return;
        }
        const key = self.allocator.dupe(u8, name) catch {
            self.incidents.err("Ziggrade: OOM adding resolver");
            return;
        };
        self.resolvers.put(self.allocator, key, .{ .ctx = ctx, .fn_ptr = fn_ptr }) catch {
            self.allocator.free(key);
            self.incidents.err("Ziggrade: OOM adding resolver");
        };
    }

    pub fn hasResolver(self: *Store, name: []const u8) bool {
        if (!self.ensureAlive()) return false;
        return self.resolvers.contains(name);
    }

    pub fn removeResolver(self: *Store, name: []const u8) void {
        if (!self.ensureAlive()) return;
        const kv = self.resolvers.fetchSwapRemove(name) orelse return;
        self.allocator.free(kv.key);
        self.removeAllResolverListeners(name);
    }

    pub fn removeAllResolvers(self: *Store) void {
        if (!self.ensureAlive()) return;
        while (self.resolvers.count() > 0) {
            const key = self.resolvers.keys()[0];
            self.removeResolver(key);
        }
    }

    pub fn callResolver(self: *Store, name: []const u8) void {
        if (!self.ensureAlive()) return;
        const resolver = self.resolvers.get(name) orelse {
            self.incidents.err("This resolver hasn't been created yet or been deleted");
            return;
        };
        const value = resolver.fn_ptr(resolver.ctx, self) catch {
            self.incidents.err("Resolver call failed");
            return;
        };
        defer {
            var tmp = value;
            tmp.deinit(self.allocator);
        }

        self.notifyGlobal(.{ .single = .{ .name = name, .value = value } });

        if (self.resolver_listeners.getPtr(name)) |list| {
            for (list.items) |listener| {
                listener.fn_ptr(listener.ctx, value);
            }
        }
    }

    pub fn addResolverListener(self: *Store, name: []const u8, ctx: ?*anyopaque, fn_ptr: ResolverListenerFn) ?ListenerId {
        if (!self.ensureAlive()) return null;
        if (!self.resolvers.contains(name)) {
            self.incidents.err("There is no resolver with that name");
            return null;
        }
        const list = blk: {
            if (self.resolver_listeners.getPtr(name)) |existing| break :blk existing;
            const key = self.allocator.dupe(u8, name) catch {
                self.incidents.err("Ziggrade: OOM adding resolver listener");
                return null;
            };
            self.resolver_listeners.put(self.allocator, key, .empty) catch {
                self.allocator.free(key);
                self.incidents.err("Ziggrade: OOM adding resolver listener");
                return null;
            };
            break :blk self.resolver_listeners.getPtr(name).?;
        };
        const id = self.allocListenerId();
        list.append(self.allocator, .{ .id = id, .ctx = ctx, .fn_ptr = fn_ptr }) catch {
            self.incidents.err("Ziggrade: OOM adding resolver listener");
            return null;
        };
        return id;
    }

    pub fn removeResolverListener(self: *Store, name: []const u8, id: ListenerId) void {
        if (!self.ensureAlive()) return;
        const list = self.resolver_listeners.getPtr(name) orelse return;
        for (list.items, 0..) |listener, i| {
            if (listener.id == id) {
                _ = list.orderedRemove(i);
                return;
            }
        }
    }

    pub fn removeAllResolverListeners(self: *Store, name: []const u8) void {
        if (!self.alive) return;
        const kv = self.resolver_listeners.fetchSwapRemove(name) orelse return;
        self.allocator.free(kv.key);
        var list = kv.value;
        list.deinit(self.allocator);
    }

    // --- lifecycle ---

    pub fn reset(self: *Store) void {
        if (!self.alive) {
            self.incidents.err("This store isn't alive anymore");
            return;
        }
        self.removeAllListeners();
        self.removeAllProps();
        self.removeAllResolvers();
        self.freeContainers();
    }

    pub fn kill(self: *Store, session_key: SessionKey) void {
        if (session_key != self.session_key or !self.alive) return;
        self.reset();
        self.alive = false;
    }

    pub fn importProps(self: *Store, target: *Store, override: bool) void {
        if (!self.ensureAlive()) return;
        var it = target.props.iterator();
        while (it.next()) |entry| {
            const name = entry.key_ptr.*;
            const value = entry.value_ptr.value;
            if (self.hasProp(name)) {
                if (!override) continue;
                self.setProp(name, value);
            } else {
                self.addProp(name, value);
            }
        }
    }

    pub fn merge(self: *Store, target: *Store, override: bool) void {
        if (!self.ensureAlive()) return;

        var imported_names: std.ArrayList([]const u8) = .empty;
        defer imported_names.deinit(self.allocator);
        var it = target.props.iterator();
        while (it.next()) |entry| {
            imported_names.append(self.allocator, entry.key_ptr.*) catch {};
        }

        self.silentImportProps(target, override);
        self.importAllPropListeners(target, override);
        self.importAllGlobalListeners(target);
        self.importResolvers(target, override);
        self.importAllResolverListeners(target, override);

        target.kill(target.session_key);
        target.merge_agent = self;

        for (imported_names.items) |name| {
            const slot = self.props.getPtr(name) orelse continue;
            self.handleOnSetProp(slot);
        }
    }

    // --- ward extension point ---

    pub fn registerWardRunner(self: *Store, ctx: ?*anyopaque, runner: WardRunner) !void {
        if (self.ward_runner != null) return error.WardRunnerAlreadyRegistered;
        self.ward_runner = runner;
        self.ward_ctx = ctx;
    }

    pub fn unregisterWardRunner(self: *Store) void {
        self.ward_runner = null;
        self.ward_ctx = null;
    }

    // --- internals ---

    fn ensureAlive(self: *Store) bool {
        if (self.alive) return true;
        self.incidents.err("This store isn't alive anymore");
        return false;
    }

    fn allocListenerId(self: *Store) ListenerId {
        const id = self.next_listener_id;
        self.next_listener_id += 1;
        return id;
    }

    fn reportDeny(self: *Store, prefix: []const u8, reason: ?[]const u8) void {
        if (reason) |r| {
            const msg = std.fmt.allocPrint(self.allocator, "{s}: {s}", .{ prefix, r }) catch {
                self.incidents.err(prefix);
                return;
            };
            defer self.allocator.free(msg);
            self.incidents.err(msg);
        } else {
            self.incidents.err(prefix);
        }
    }

    fn runWard(self: *Store, context: WardContext) ?WardOutcome {
        const runner = self.ward_runner orelse return null;
        if (self.ward_running) return null;
        self.ward_running = true;
        defer self.ward_running = false;
        return runner(self.ward_ctx, context);
    }

    fn silentAddProp(self: *Store, name: []const u8, value: Value) bool {
        if (self.props.contains(name)) {
            self.incidents.err("Prop can't be overridden, remove it first");
            return false;
        }

        var incoming = value;
        const outcome = self.runWard(.{ .add_prop = .{ .name = name, .value = incoming } });
        if (outcome) |o| {
            switch (o) {
                .deny => |reason| {
                    self.reportDeny("Ward denied adding prop", reason);
                    return false;
                },
                .allow => |maybe| {
                    if (maybe) |transformed| incoming = transformed;
                },
            }
        }

        if (incoming.valueType() == .null) {
            self.incidents.err("Value can't be null on add");
            return false;
        }

        const locked = incoming.valueType();
        const owned = incoming.clone(self.allocator) catch {
            self.incidents.err("Ziggrade: OOM adding prop");
            return false;
        };
        errdefer {
            var tmp = owned;
            tmp.deinit(self.allocator);
        }

        const key = self.allocator.dupe(u8, name) catch {
            self.incidents.err("Ziggrade: OOM adding prop");
            return false;
        };
        errdefer self.allocator.free(key);

        const prop_name = self.allocator.dupe(u8, name) catch {
            self.incidents.err("Ziggrade: OOM adding prop");
            return false;
        };

        self.props.put(self.allocator, key, .{
            .name = prop_name,
            .value = owned,
            .locked_type = locked,
            .is_value_scalar = owned.isScalar(),
        }) catch {
            self.allocator.free(prop_name);
            self.incidents.err("Ziggrade: OOM adding prop");
            return false;
        };
        return true;
    }

    fn writeProp(self: *Store, name: []const u8, new_value: Value) bool {
        const slot = self.props.getPtr(name) orelse {
            self.incidents.err("Prop wasn't registered. Add it first");
            return false;
        };

        var incoming = new_value;
        const outcome = self.runWard(.{ .set_prop = .{ .name = name, .value = incoming } });
        if (outcome) |o| {
            switch (o) {
                .deny => |reason| {
                    self.reportDeny("Ward denied writing prop", reason);
                    return false;
                },
                .allow => |maybe| {
                    if (maybe) |transformed| incoming = transformed;
                },
            }
        }

        if (incoming.valueType() == .null) {
            slot.value.deinit(self.allocator);
            slot.value = .{ .null = {} };
            return true;
        }

        if (slot.locked_type != incoming.valueType()) {
            self.incidents.err("New value must have same type as initial value");
            return false;
        }

        if (slot.is_value_scalar and slot.value.eql(incoming)) {
            return false;
        }

        const owned = incoming.clone(self.allocator) catch {
            self.incidents.err("Ziggrade: OOM writing prop");
            return false;
        };
        slot.value.deinit(self.allocator);
        slot.value = owned;
        return true;
    }

    fn silentImportProps(self: *Store, target: *Store, override: bool) void {
        var it = target.props.iterator();
        while (it.next()) |entry| {
            const name = entry.key_ptr.*;
            const value = entry.value_ptr.value;
            if (self.hasProp(name)) {
                if (!override) continue;
                _ = self.writeProp(name, value);
            } else {
                _ = self.silentAddProp(name, value);
            }
        }
    }

    fn importResolvers(self: *Store, target: *Store, override: bool) void {
        var it = target.resolvers.iterator();
        while (it.next()) |entry| {
            const name = entry.key_ptr.*;
            if (self.resolvers.contains(name) and !override) continue;
            if (self.resolvers.contains(name)) self.removeResolver(name);
            self.addResolver(name, entry.value_ptr.ctx, entry.value_ptr.fn_ptr);
        }
    }

    fn importAllPropListeners(self: *Store, target: *Store, override: bool) void {
        var it = target.prop_listeners.iterator();
        while (it.next()) |entry| {
            const name = entry.key_ptr.*;
            if (!self.props.contains(name)) continue;
            if (override) self.removeAllPropListeners(name);
            for (entry.value_ptr.items) |listener| {
                _ = self.addPropListener(name, listener.ctx, listener.fn_ptr);
            }
        }
    }

    fn importAllGlobalListeners(self: *Store, target: *Store) void {
        for (target.global_listeners.items) |listener| {
            _ = self.addListener(listener.ctx, listener.fn_ptr);
        }
    }

    fn importAllResolverListeners(self: *Store, target: *Store, override: bool) void {
        var it = target.resolver_listeners.iterator();
        while (it.next()) |entry| {
            const name = entry.key_ptr.*;
            if (!self.resolvers.contains(name)) continue;
            if (override) self.removeAllResolverListeners(name);
            for (entry.value_ptr.items) |listener| {
                _ = self.addResolverListener(name, listener.ctx, listener.fn_ptr);
            }
        }
    }

    fn notifyPropListeners(self: *Store, slot: *const Prop) void {
        const list = self.prop_listeners.getPtr(slot.name) orelse return;
        // Copy ids/fns in case a listener mutates the list.
        const snapshot = self.allocator.alloc(PropListener, list.items.len) catch return;
        defer self.allocator.free(snapshot);
        @memcpy(snapshot, list.items);
        for (snapshot) |listener| {
            listener.fn_ptr(listener.ctx, slot.value);
        }
    }

    fn notifyGlobal(self: *Store, change: Change) void {
        const snapshot = self.allocator.alloc(GlobalListener, self.global_listeners.items.len) catch return;
        defer self.allocator.free(snapshot);
        @memcpy(snapshot, self.global_listeners.items);
        for (snapshot) |listener| {
            listener.fn_ptr(listener.ctx, change);
        }
    }

    fn handleOnSetProp(self: *Store, slot: *const Prop) void {
        self.notifyPropListeners(slot);
        self.notifyGlobal(.{ .single = .{ .name = slot.name, .value = slot.value } });
    }
};

// --- tests ---

const TestProbe = struct {
    prop_hits: usize = 0,
    global_hits: usize = 0,
    last_batch_len: usize = 0,
};

fn onProp(ctx: ?*anyopaque, value: Value) void {
    _ = value;
    const probe: *TestProbe = @ptrCast(@alignCast(ctx.?));
    probe.prop_hits += 1;
}

fn onGlobal(ctx: ?*anyopaque, change: Change) void {
    const probe: *TestProbe = @ptrCast(@alignCast(ctx.?));
    probe.global_hits += 1;
    switch (change) {
        .batch => |b| probe.last_batch_len = b.names.len,
        .single => {},
    }
}

test "store setProp and listeners" {
    const gpa = std.testing.allocator;
    const store = try Store.create(gpa, .{ .name = "t" });
    defer store.destroy();

    var probe: TestProbe = .{};
    store.addProp("counter", Value.fromInt(0));
    _ = store.addPropListener("counter", &probe, onProp);
    _ = store.addListener(&probe, onGlobal);

    store.setProp("counter", Value.fromInt(0));
    try std.testing.expectEqual(@as(usize, 0), probe.prop_hits);

    store.setProp("counter", Value.fromInt(1));
    try std.testing.expectEqual(@as(usize, 1), probe.prop_hits);
    try std.testing.expectEqual(@as(usize, 1), probe.global_hits);
}

test "store setProps batches global notify" {
    const gpa = std.testing.allocator;
    const store = try Store.create(gpa, .{ .name = "batch" });
    defer store.destroy();

    var probe: TestProbe = .{};
    store.addProp("a", Value.fromInt(0));
    store.addProp("b", Value.fromInt(0));
    _ = store.addPropListener("a", &probe, onProp);
    _ = store.addPropListener("b", &probe, onProp);
    _ = store.addListener(&probe, onGlobal);

    store.setProps(&.{
        .{ .name = "a", .value = Value.fromInt(1) },
        .{ .name = "b", .value = Value.fromInt(2) },
    });

    try std.testing.expectEqual(@as(usize, 2), probe.prop_hits);
    try std.testing.expectEqual(@as(usize, 1), probe.global_hits);
    try std.testing.expectEqual(@as(usize, 2), probe.last_batch_len);
}

fn silentIncident(_: ?*anyopaque, _: []const u8) void {}

test "store type lock and null clear" {
    const gpa = std.testing.allocator;
    const store = try Store.create(gpa, .{
        .incidents = .{
            .on_warn = silentIncident,
            .on_error = silentIncident,
        },
    });
    defer store.destroy();

    var initial = try Value.fromString(gpa, "guest");
    defer initial.deinit(gpa);
    store.addProp("name", initial);

    store.setProp("name", Value.fromInt(1));
    const still = store.propRef("name").?;
    try std.testing.expect(still.valueType() == .string);

    store.setProp("name", Value.nullValue());
    try std.testing.expect(store.propRef("name").?.valueType() == .null);
}

test "store bool scalar skips equal write" {
    const gpa = std.testing.allocator;
    const store = try Store.create(gpa, .{ .name = "bool" });
    defer store.destroy();

    var probe: TestProbe = .{};
    store.addProp("flag", Value.fromBool(true));
    _ = store.addPropListener("flag", &probe, onProp);

    store.setProp("flag", Value.fromBool(true));
    try std.testing.expectEqual(@as(usize, 0), probe.prop_hits);
    store.setProp("flag", Value.fromBool(false));
    try std.testing.expectEqual(@as(usize, 1), probe.prop_hits);
}

test "store removeProp is silent" {
    const gpa = std.testing.allocator;
    const store = try Store.create(gpa, .{ .name = "rm" });
    defer store.destroy();

    var probe: TestProbe = .{};
    store.addProp("x", Value.fromInt(1));
    _ = store.addListener(&probe, onGlobal);
    store.removeProp("x");
    try std.testing.expectEqual(@as(usize, 0), probe.global_hits);
    try std.testing.expect(!store.hasProp("x"));
}

fn sumResolver(_: ?*anyopaque, s: *Store) anyerror!Value {
    return Value.fromInt(s.propRef("a").?.int + s.propRef("b").?.int);
}

test "store resolver notifies global" {
    const gpa = std.testing.allocator;
    const store = try Store.create(gpa, .{ .name = "res" });
    defer store.destroy();

    var probe: TestProbe = .{};
    store.addProp("a", Value.fromInt(2));
    store.addProp("b", Value.fromInt(3));
    store.addResolver("sum", null, sumResolver);
    _ = store.addListener(&probe, onGlobal);
    store.callResolver("sum");
    try std.testing.expectEqual(@as(usize, 1), probe.global_hits);
}
