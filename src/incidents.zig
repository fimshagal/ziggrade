//! Soft incident reporting for store operations (warn/error without aborting by default).

const std = @import("std");

pub const IncidentsHandler = struct {
    emit_errors: bool = false,
    ctx: ?*anyopaque = null,
    on_warn: ?*const fn (ctx: ?*anyopaque, message: []const u8) void = null,
    on_error: ?*const fn (ctx: ?*anyopaque, message: []const u8) void = null,

    pub fn warn(self: IncidentsHandler, message: []const u8) void {
        if (self.on_warn) |cb| {
            cb(self.ctx, message);
            return;
        }
        std.log.warn("{s}", .{message});
    }

    pub fn err(self: IncidentsHandler, message: []const u8) void {
        if (self.on_error) |cb| {
            cb(self.ctx, message);
        } else {
            std.log.err("{s}", .{message});
        }
        if (self.emit_errors) {
            @panic(message);
        }
    }
};
