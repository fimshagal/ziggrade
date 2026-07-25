//! Optional persistence layer.
//! Outside the browser there is no localStorage — plug in a Storage adapter:
//! in-memory (tests), file-backed directory, or your own (DB, redis, etc.).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Store = @import("store.zig").Store;
const Change = @import("store.zig").Change;
const ListenerId = @import("store.zig").ListenerId;
const Value = @import("value.zig").Value;

pub const Storage = struct {
    ptr: *anyopaque,
    readFn: *const fn (ptr: *anyopaque, allocator: Allocator, key: []const u8) anyerror!?[]u8,
    writeFn: *const fn (ptr: *anyopaque, key: []const u8, value: []const u8) anyerror!void,
    removeFn: *const fn (ptr: *anyopaque, key: []const u8) anyerror!void,

    pub fn read(self: Storage, allocator: Allocator, key: []const u8) anyerror!?[]u8 {
        return self.readFn(self.ptr, allocator, key);
    }

    pub fn write(self: Storage, key: []const u8, value: []const u8) anyerror!void {
        return self.writeFn(self.ptr, key, value);
    }

    pub fn remove(self: Storage, key: []const u8) anyerror!void {
        return self.removeFn(self.ptr, key);
    }
};

pub const MemoryStorage = struct {
    allocator: Allocator,
    map: std.StringHashMapUnmanaged([]u8) = .empty,

    pub fn init(allocator: Allocator) MemoryStorage {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *MemoryStorage) void {
        var it = self.map.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.map.deinit(self.allocator);
    }

    pub fn storage(self: *MemoryStorage) Storage {
        return .{
            .ptr = self,
            .readFn = read,
            .writeFn = write,
            .removeFn = remove,
        };
    }

    fn read(ptr: *anyopaque, allocator: Allocator, key: []const u8) anyerror!?[]u8 {
        const self: *MemoryStorage = @ptrCast(@alignCast(ptr));
        const value = self.map.get(key) orelse return null;
        return try allocator.dupe(u8, value);
    }

    fn write(ptr: *anyopaque, key: []const u8, value: []const u8) anyerror!void {
        const self: *MemoryStorage = @ptrCast(@alignCast(ptr));
        if (self.map.getPtr(key)) |existing| {
            self.allocator.free(existing.*);
            existing.* = try self.allocator.dupe(u8, value);
            return;
        }
        const owned_key = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(owned_key);
        const owned_val = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(owned_val);
        try self.map.put(self.allocator, owned_key, owned_val);
    }

    fn remove(ptr: *anyopaque, key: []const u8) anyerror!void {
        const self: *MemoryStorage = @ptrCast(@alignCast(ptr));
        const kv = self.map.fetchRemove(key) orelse return;
        self.allocator.free(kv.key);
        self.allocator.free(kv.value);
    }
};

/// Persists each key as `<dir>/<key>.json`. Requires Zig 0.16 `std.Io`.
pub const FileStorage = struct {
    allocator: Allocator,
    io: std.Io,
    dir_path: []u8,

    pub fn init(allocator: Allocator, io: std.Io, dir_path: []const u8) !FileStorage {
        try std.Io.Dir.cwd().createDirPath(io, dir_path);
        return .{
            .allocator = allocator,
            .io = io,
            .dir_path = try allocator.dupe(u8, dir_path),
        };
    }

    pub fn deinit(self: *FileStorage) void {
        self.allocator.free(self.dir_path);
    }

    pub fn storage(self: *FileStorage) Storage {
        return .{
            .ptr = self,
            .readFn = read,
            .writeFn = write,
            .removeFn = remove,
        };
    }

    fn pathFor(self: *FileStorage, key: []const u8) ![]u8 {
        return std.fmt.allocPrint(self.allocator, "{s}/{s}.json", .{ self.dir_path, key });
    }

    fn read(ptr: *anyopaque, allocator: Allocator, key: []const u8) anyerror!?[]u8 {
        const self: *FileStorage = @ptrCast(@alignCast(ptr));
        const path = try self.pathFor(key);
        defer self.allocator.free(path);
        return std.Io.Dir.cwd().readFileAlloc(self.io, path, allocator, .limited(16 * 1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => null,
            else => err,
        };
    }

    fn write(ptr: *anyopaque, key: []const u8, value: []const u8) anyerror!void {
        const self: *FileStorage = @ptrCast(@alignCast(ptr));
        const path = try self.pathFor(key);
        defer self.allocator.free(path);
        try std.Io.Dir.cwd().writeFile(self.io, .{
            .sub_path = path,
            .data = value,
            .flags = .{},
        });
    }

    fn remove(ptr: *anyopaque, key: []const u8) anyerror!void {
        const self: *FileStorage = @ptrCast(@alignCast(ptr));
        const path = try self.pathFor(key);
        defer self.allocator.free(path);
        std.Io.Dir.cwd().deleteFile(self.io, path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }
};

pub const PersistPickFn = *const fn (ctx: ?*anyopaque, props: Value.ObjectMap) Allocator.Error!Value.ObjectMap;
pub const PersistMigrateFn = *const fn (ctx: ?*anyopaque, from_version: u32, data: Value) anyerror!Value;

pub const PersistOptions = struct {
    key: []const u8,
    storage: Storage,
    pick: ?PersistPickFn = null,
    pick_ctx: ?*anyopaque = null,
    /// 0 = save synchronously on every change. >0 requires calling `poll(now_ms)`.
    save_after_ms: u64 = 0,
    restore_on_start: bool = true,
    version: u32 = 1,
    migrate: ?PersistMigrateFn = null,
    migrate_ctx: ?*anyopaque = null,
    on_restore: ?*const fn (ctx: ?*anyopaque, saved: Value.ObjectMap) void = null,
    on_save: ?*const fn (ctx: ?*anyopaque, saved: Value.ObjectMap) void = null,
    on_error: ?*const fn (ctx: ?*anyopaque, message: []const u8) void = null,
    callback_ctx: ?*anyopaque = null,
};

pub const PersistLink = struct {
    store: *Store,
    allocator: Allocator,
    options: PersistOptions,
    key: []u8,
    allowlist: std.StringArrayHashMapUnmanaged(void) = .empty,
    held: bool = false,
    disposed: bool = false,
    restoring: bool = false,
    dirty: bool = false,
    dirty_since_ms: u64 = 0,
    listener_id: ?ListenerId = null,

    pub fn attach(store: *Store, allocator: Allocator, options: PersistOptions) !*PersistLink {
        const self = try allocator.create(PersistLink);
        errdefer allocator.destroy(self);
        self.* = .{
            .store = store,
            .allocator = allocator,
            .options = options,
            .key = try allocator.dupe(u8, options.key),
        };
        errdefer allocator.free(self.key);

        self.listener_id = store.addListener(self, onStoreChange);
        if (self.listener_id == null) {
            allocator.free(self.key);
            allocator.destroy(self);
            return error.ListenerFailed;
        }

        if (options.restore_on_start) self.restore();
        return self;
    }

    pub fn dispose(self: *PersistLink) void {
        if (self.disposed) return;
        self.disposed = true;
        if (self.listener_id) |id| self.store.removeListener(id);
        var it = self.allowlist.iterator();
        while (it.next()) |entry| self.allocator.free(entry.key_ptr.*);
        self.allowlist.deinit(self.allocator);
        self.allocator.free(self.key);
        self.allocator.destroy(self);
    }

    pub fn hold(self: *PersistLink) void {
        self.held = true;
    }

    pub fn unhold(self: *PersistLink) void {
        self.held = false;
        self.save();
    }

    pub fn isHeld(self: *const PersistLink) bool {
        return self.held;
    }

    pub fn isDisposed(self: *const PersistLink) bool {
        return self.disposed;
    }

    pub fn retain(self: *PersistLink, key: []const u8) !void {
        if (self.allowlist.contains(key)) return;
        const owned = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(owned);
        try self.allowlist.put(self.allocator, owned, {});
    }

    pub fn drop(self: *PersistLink, key: []const u8) void {
        const kv = self.allowlist.fetchSwapRemove(key) orelse return;
        self.allocator.free(kv.key);
    }

    pub fn peek(self: *PersistLink) Allocator.Error!Value.ObjectMap {
        return self.buildSnapshot();
    }

    pub fn save(self: *PersistLink) void {
        self.dirty = false;
        if (!self.store.isAlive()) {
            self.fail("can't save, store isn't alive");
            return;
        }

        var snap = self.buildSnapshot() catch {
            self.fail("failed to build snapshot");
            return;
        };
        defer freeMap(self.allocator, &snap);

        const envelope = self.serializeEnvelope(snap) catch {
            self.fail("failed to serialize envelope");
            return;
        };
        defer self.allocator.free(envelope);

        self.options.storage.write(self.key, envelope) catch {
            self.fail("storage write failed");
            return;
        };

        if (self.options.on_save) |cb| cb(self.options.callback_ctx, snap);
    }

    pub fn restore(self: *PersistLink) void {
        if (!self.store.isAlive()) {
            self.fail("can't restore, store isn't alive");
            return;
        }

        const bytes = self.options.storage.read(self.allocator, self.key) catch {
            self.fail("storage read failed");
            return;
        } orelse return;
        defer self.allocator.free(bytes);

        var data = self.deserializeEnvelope(bytes) catch {
            self.fail("failed to deserialize envelope");
            return;
        };
        defer {
            var tmp = data;
            tmp.deinit(self.allocator);
        }

        if (data.valueType() != .object) {
            self.fail("persisted data is not an object");
            return;
        }

        self.restoring = true;
        defer self.restoring = false;

        var it = data.object.iterator();
        while (it.next()) |entry| {
            const name = entry.key_ptr.*;
            const value = entry.value_ptr.*;
            if (value.valueType() == .null and !self.store.hasProp(name)) continue;
            if (self.store.hasProp(name)) {
                self.store.setProp(name, value);
            } else {
                self.store.addProp(name, value);
            }
        }

        if (self.options.on_restore) |cb| cb(self.options.callback_ctx, data.object);
    }

    pub fn forget(self: *PersistLink) void {
        self.options.storage.remove(self.key) catch {
            self.fail("storage remove failed");
        };
    }

    /// Call from your sim/game loop when `save_after_ms > 0`.
    pub fn poll(self: *PersistLink, now_ms: u64) void {
        if (!self.dirty or self.held or self.disposed) return;
        if (self.options.save_after_ms == 0) {
            self.save();
            return;
        }
        if (self.dirty_since_ms == 0) self.dirty_since_ms = now_ms;
        if (now_ms -% self.dirty_since_ms >= self.options.save_after_ms) {
            self.save();
        }
    }

    fn onStoreChange(ctx: ?*anyopaque, change: Change) void {
        const self: *PersistLink = @ptrCast(@alignCast(ctx.?));
        if (self.held or self.restoring or self.disposed) return;
        switch (change) {
            .single => |s| if (!self.store.hasProp(s.name)) return,
            .batch => {},
        }
        if (self.options.save_after_ms == 0) {
            self.save();
            return;
        }
        if (!self.dirty) {
            self.dirty = true;
            self.dirty_since_ms = 0; // stamped on next poll(now_ms)
        }
    }

    fn buildSnapshot(self: *PersistLink) Allocator.Error!Value.ObjectMap {
        var all = try self.store.propsSnapshot();
        if (self.options.pick) |pick| {
            defer freeMap(self.allocator, &all);
            var picked = try pick(self.options.pick_ctx, all);
            try self.applyAllowlist(&picked);
            return picked;
        }
        try self.applyAllowlist(&all);
        return all;
    }

    fn applyAllowlist(self: *PersistLink, map: *Value.ObjectMap) Allocator.Error!void {
        if (self.allowlist.count() == 0) return;
        var to_remove: std.ArrayList([]const u8) = .empty;
        defer to_remove.deinit(self.allocator);
        var it = map.iterator();
        while (it.next()) |entry| {
            if (!self.allowlist.contains(entry.key_ptr.*)) {
                try to_remove.append(self.allocator, entry.key_ptr.*);
            }
        }
        for (to_remove.items) |key| {
            const kv = map.fetchSwapRemove(key) orelse continue;
            self.allocator.free(kv.key);
            var val = kv.value;
            val.deinit(self.allocator);
        }
    }

    fn serializeEnvelope(self: *PersistLink, snap: Value.ObjectMap) Allocator.Error![]u8 {
        var root = Value.emptyObject();
        defer root.deinit(self.allocator);

        try root.object.put(self.allocator, try self.allocator.dupe(u8, "version"), Value.fromInt(@intCast(self.options.version)));

        var data = Value.emptyObject();
        var it = snap.iterator();
        while (it.next()) |entry| {
            const key = try self.allocator.dupe(u8, entry.key_ptr.*);
            errdefer self.allocator.free(key);
            var val = try entry.value_ptr.clone(self.allocator);
            errdefer val.deinit(self.allocator);
            try data.object.put(self.allocator, key, val);
        }
        try root.object.put(self.allocator, try self.allocator.dupe(u8, "data"), data);

        return root.toJson(self.allocator);
    }

    fn deserializeEnvelope(self: *PersistLink, bytes: []const u8) !Value {
        var root = try Value.fromJson(self.allocator, bytes);
        errdefer root.deinit(self.allocator);

        if (root.valueType() != .object) return error.InvalidEnvelope;
        const version_v = root.object.get("version") orelse return error.InvalidEnvelope;
        const data_v = root.object.get("data") orelse return error.InvalidEnvelope;
        if (version_v.valueType() != .int) return error.InvalidEnvelope;

        const from_version: u32 = @intCast(version_v.int);
        var data = try data_v.clone(self.allocator);
        root.deinit(self.allocator);

        if (from_version < self.options.version) {
            if (self.options.migrate) |migrate| {
                const migrated = try migrate(self.options.migrate_ctx, from_version, data);
                data.deinit(self.allocator);
                data = migrated;
            }
        }
        return data;
    }

    fn fail(self: *PersistLink, message: []const u8) void {
        if (self.options.on_error) |cb| {
            cb(self.options.callback_ctx, message);
        } else {
            std.log.warn("Ziggrade persist: {s}", .{message});
        }
    }
};

fn freeMap(allocator: Allocator, map: *Value.ObjectMap) void {
    var it = map.iterator();
    while (it.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        entry.value_ptr.deinit(allocator);
    }
    map.deinit(allocator);
    map.* = .empty;
}

test "persist memory roundtrip" {
    const gpa = std.testing.allocator;
    var mem = MemoryStorage.init(gpa);
    defer mem.deinit();

    {
        const store = try Store.create(gpa, .{ .name = "p1" });
        defer store.destroy();

        store.addProp("hp", Value.fromInt(100));
        var name = try Value.fromString(gpa, "hero");
        defer name.deinit(gpa);
        store.addProp("name", name);

        const link = try PersistLink.attach(store, gpa, .{
            .key = "save1",
            .storage = mem.storage(),
            .restore_on_start = false,
        });
        defer link.dispose();
        link.save();
    }

    {
        const store = try Store.create(gpa, .{ .name = "p2" });
        defer store.destroy();
        store.addProp("hp", Value.fromInt(0));
        var name = try Value.fromString(gpa, "");
        defer name.deinit(gpa);
        store.addProp("name", name);

        const link = try PersistLink.attach(store, gpa, .{
            .key = "save1",
            .storage = mem.storage(),
            .restore_on_start = true,
        });
        defer link.dispose();

        try std.testing.expectEqual(@as(i64, 100), store.propRef("hp").?.int);
        try std.testing.expectEqualStrings("hero", store.propRef("name").?.string);
    }
}
