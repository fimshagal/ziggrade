//! Optional undo/redo (timeline). Attaches via a global store listener.
//!
//! Stores **deltas** (only changed keys) on the undo/redo stacks, plus one full
//! `present` snapshot for equality checks. That keeps memory low when a large
//! store changes a few props per step — the usual sim / editor pattern.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Store = @import("store.zig").Store;
const Change = @import("store.zig").Change;
const ListenerId = @import("store.zig").ListenerId;
const Value = @import("value.zig").Value;

pub const HistoryPickFn = *const fn (ctx: ?*anyopaque, props: Value.ObjectMap) Allocator.Error!Value.ObjectMap;

pub const HistoryOptions = struct {
    limit: usize = 50,
    record_on_start: bool = true,
    pick: ?HistoryPickFn = null,
    pick_ctx: ?*anyopaque = null,
    on_undo: ?*const fn (ctx: ?*anyopaque, props: Value.ObjectMap) void = null,
    on_redo: ?*const fn (ctx: ?*anyopaque, props: Value.ObjectMap) void = null,
    callback_ctx: ?*anyopaque = null,
};

const Snapshot = Value.ObjectMap;

/// One key transition. `null` before = prop was added; `null` after = prop was removed.
const DeltaItem = struct {
    name: []u8,
    before: ?Value,
    after: ?Value,

    fn deinit(self: *DeltaItem, allocator: Allocator) void {
        allocator.free(self.name);
        if (self.before) |*v| v.deinit(allocator);
        if (self.after) |*v| v.deinit(allocator);
        self.* = undefined;
    }
};

const DeltaStep = struct {
    items: []DeltaItem,

    fn deinit(self: *DeltaStep, allocator: Allocator) void {
        for (self.items) |*item| item.deinit(allocator);
        allocator.free(self.items);
        self.* = undefined;
    }
};

pub const HistoryLink = struct {
    store: *Store,
    allocator: Allocator,
    options: HistoryOptions,
    past: std.ArrayList(DeltaStep) = .empty,
    future: std.ArrayList(DeltaStep) = .empty,
    present: Snapshot = .empty,
    has_baseline: bool = false,
    held: bool = false,
    disposed: bool = false,
    restoring: bool = false,
    listener_id: ?ListenerId = null,

    pub fn attach(store: *Store, allocator: Allocator, options: HistoryOptions) !*HistoryLink {
        const self = try allocator.create(HistoryLink);
        errdefer allocator.destroy(self);
        self.* = .{
            .store = store,
            .allocator = allocator,
            .options = options,
        };

        self.listener_id = store.addListener(self, onStoreChange);
        if (self.listener_id == null) {
            allocator.destroy(self);
            return error.ListenerFailed;
        }

        if (options.record_on_start) self.record();
        return self;
    }

    pub fn dispose(self: *HistoryLink) void {
        if (self.disposed) return;
        self.disposed = true;
        if (self.listener_id) |id| self.store.removeListener(id);
        self.clearStacks();
        freeSnapshotMap(self.allocator, &self.present);
        self.past.deinit(self.allocator);
        self.future.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn hold(self: *HistoryLink) void {
        self.held = true;
    }

    pub fn unhold(self: *HistoryLink) void {
        self.held = false;
        self.record();
    }

    pub fn isHeld(self: *const HistoryLink) bool {
        return self.held;
    }

    pub fn isDisposed(self: *const HistoryLink) bool {
        return self.disposed;
    }

    pub fn canUndo(self: *const HistoryLink) bool {
        return self.past.items.len > 0;
    }

    pub fn canRedo(self: *const HistoryLink) bool {
        return self.future.items.len > 0;
    }

    pub fn record(self: *HistoryLink) void {
        if (self.disposed or !self.store.isAlive()) return;
        var next = self.takeSnapshot() catch return;

        if (!self.has_baseline) {
            self.present = next;
            self.has_baseline = true;
            return;
        }

        var step = diffSnapshots(self.allocator, self.present, next) catch {
            freeSnapshotMap(self.allocator, &next);
            return;
        };

        if (step.items.len == 0) {
            step.deinit(self.allocator);
            freeSnapshotMap(self.allocator, &next);
            return;
        }

        self.past.append(self.allocator, step) catch {
            step.deinit(self.allocator);
            freeSnapshotMap(self.allocator, &next);
            return;
        };

        freeSnapshotMap(self.allocator, &self.present);
        self.present = next;
        self.trimPast();
        self.clearFuture();
    }

    pub fn undo(self: *HistoryLink) bool {
        if (self.disposed or self.past.items.len == 0) return false;
        const step = self.past.pop().?;
        self.applyDelta(step, .backward);
        self.rebuildPresent() catch {};
        self.future.append(self.allocator, step) catch {
            // Keep step alive in future failed — still applied; drop it.
            var doomed = step;
            doomed.deinit(self.allocator);
            return true;
        };
        if (self.options.on_undo) |cb| cb(self.options.callback_ctx, self.present);
        return true;
    }

    pub fn redo(self: *HistoryLink) bool {
        if (self.disposed or self.future.items.len == 0) return false;
        const step = self.future.pop().?;
        self.applyDelta(step, .forward);
        self.rebuildPresent() catch {};
        self.past.append(self.allocator, step) catch {
            var doomed = step;
            doomed.deinit(self.allocator);
            return true;
        };
        if (self.options.on_redo) |cb| cb(self.options.callback_ctx, self.present);
        return true;
    }

    pub fn clear(self: *HistoryLink) void {
        self.clearStacks();
        freeSnapshotMap(self.allocator, &self.present);
        self.has_baseline = false;
        if (self.store.isAlive()) self.record();
    }

    pub fn peek(self: *HistoryLink) Allocator.Error!Snapshot {
        return self.takeSnapshot();
    }

    /// Number of keys stored in the last recorded delta (0 if none). Useful in tests.
    pub fn lastDeltaSize(self: *const HistoryLink) usize {
        if (self.past.items.len == 0) return 0;
        return self.past.items[self.past.items.len - 1].items.len;
    }

    fn onStoreChange(ctx: ?*anyopaque, change: Change) void {
        const self: *HistoryLink = @ptrCast(@alignCast(ctx.?));
        if (self.held or self.restoring or self.disposed) return;
        switch (change) {
            .single => |s| if (!self.store.hasProp(s.name)) return,
            .batch => {},
        }
        self.record();
    }

    fn takeSnapshot(self: *HistoryLink) Allocator.Error!Snapshot {
        var all = try self.store.propsSnapshot();
        if (self.options.pick) |pick| {
            defer freeSnapshotMap(self.allocator, &all);
            return pick(self.options.pick_ctx, all);
        }
        return all;
    }

    fn rebuildPresent(self: *HistoryLink) Allocator.Error!void {
        freeSnapshotMap(self.allocator, &self.present);
        self.present = try self.takeSnapshot();
        self.has_baseline = true;
    }

    const Direction = enum { forward, backward };

    fn applyDelta(self: *HistoryLink, step: DeltaStep, direction: Direction) void {
        self.restoring = true;
        defer self.restoring = false;

        for (step.items) |item| {
            const target: ?Value = switch (direction) {
                .backward => item.before,
                .forward => item.after,
            };

            if (target) |value| {
                if (self.store.hasProp(item.name)) {
                    self.store.setProp(item.name, value);
                } else {
                    self.store.addProp(item.name, value);
                }
            } else {
                if (self.store.hasProp(item.name)) {
                    self.store.removeProp(item.name);
                }
            }
        }
    }

    fn trimPast(self: *HistoryLink) void {
        while (self.past.items.len > self.options.limit) {
            var oldest = self.past.orderedRemove(0);
            oldest.deinit(self.allocator);
        }
    }

    fn clearFuture(self: *HistoryLink) void {
        for (self.future.items) |*step| step.deinit(self.allocator);
        self.future.clearRetainingCapacity();
    }

    fn clearStacks(self: *HistoryLink) void {
        for (self.past.items) |*step| step.deinit(self.allocator);
        self.past.clearRetainingCapacity();
        self.clearFuture();
    }
};

fn freeSnapshotMap(allocator: Allocator, snap: *Snapshot) void {
    var it = snap.iterator();
    while (it.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        entry.value_ptr.deinit(allocator);
    }
    snap.deinit(allocator);
    snap.* = .empty;
}

fn diffSnapshots(allocator: Allocator, before: Snapshot, after: Snapshot) Allocator.Error!DeltaStep {
    var items: std.ArrayList(DeltaItem) = .empty;
    errdefer {
        for (items.items) |*item| item.deinit(allocator);
        items.deinit(allocator);
    }

    var bit = before.iterator();
    while (bit.next()) |entry| {
        const name = entry.key_ptr.*;
        const bval = entry.value_ptr.*;
        if (after.get(name)) |aval| {
            if (!bval.eql(aval)) {
                try items.append(allocator, .{
                    .name = try allocator.dupe(u8, name),
                    .before = try bval.clone(allocator),
                    .after = try aval.clone(allocator),
                });
            }
        } else {
            try items.append(allocator, .{
                .name = try allocator.dupe(u8, name),
                .before = try bval.clone(allocator),
                .after = null,
            });
        }
    }

    var ait = after.iterator();
    while (ait.next()) |entry| {
        const name = entry.key_ptr.*;
        if (!before.contains(name)) {
            try items.append(allocator, .{
                .name = try allocator.dupe(u8, name),
                .before = null,
                .after = try entry.value_ptr.clone(allocator),
            });
        }
    }

    return .{ .items = try items.toOwnedSlice(allocator) };
}

test "history undo redo with deltas" {
    const gpa = std.testing.allocator;
    const store = try Store.create(gpa, .{ .name = "hist" });
    defer store.destroy();

    store.addProp("n", Value.fromInt(0));
    store.addProp("big", Value.fromInt(100));
    const hist = try HistoryLink.attach(store, gpa, .{ .limit = 10 });
    defer hist.dispose();

    store.setProp("n", Value.fromInt(1));
    try std.testing.expectEqual(@as(usize, 1), hist.lastDeltaSize());

    store.setProp("n", Value.fromInt(2));
    try std.testing.expect(hist.canUndo());
    try std.testing.expect(hist.undo());
    try std.testing.expectEqual(@as(i64, 1), store.propRef("n").?.int);
    try std.testing.expectEqual(@as(i64, 100), store.propRef("big").?.int);
    try std.testing.expect(hist.redo());
    try std.testing.expectEqual(@as(i64, 2), store.propRef("n").?.int);
}

test "history delta tracks add and remove" {
    const gpa = std.testing.allocator;
    const store = try Store.create(gpa, .{ .name = "hist2" });
    defer store.destroy();

    store.addProp("keep", Value.fromInt(1));
    const hist = try HistoryLink.attach(store, gpa, .{});
    defer hist.dispose();

    hist.hold();
    store.addProp("tmp", Value.fromInt(7));
    hist.unhold(); // one step: tmp added

    try std.testing.expect(store.hasProp("tmp"));
    try std.testing.expect(hist.undo());
    try std.testing.expect(!store.hasProp("tmp"));
    try std.testing.expect(hist.redo());
    try std.testing.expect(store.hasProp("tmp"));
}
