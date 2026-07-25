const std = @import("std");
const Io = std.Io;
const Ziggrade = @import("Ziggrade");

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const io = init.io;

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout_file_writer.interface;

    const store = try Ziggrade.createStore(gpa, .{ .name = "demo" });
    defer store.destroy();

    store.addProp("tick", Ziggrade.Value.fromInt(0));
    store.addProp("running", Ziggrade.Value.fromBool(true));

    var name = try Ziggrade.Value.fromString(gpa, "sim");
    defer name.deinit(gpa);
    store.addProp("name", name);

    _ = store.addListener(null, struct {
        fn onChange(_: ?*anyopaque, change: Ziggrade.Change) void {
            switch (change) {
                .single => |s| std.log.info("change: {s}", .{s.name}),
                .batch => |b| std.log.info("batch: {d} props", .{b.names.len}),
            }
        }
    }.onChange);

    store.setProps(&.{
        .{ .name = "tick", .value = Ziggrade.Value.fromInt(1) },
        .{ .name = "running", .value = Ziggrade.Value.fromBool(false) },
    });

    try out.print("Ziggrade store \"{s}\" ready. Props: tick={d}, running={}\n", .{
        store.getName(),
        store.propRef("tick").?.int,
        store.propRef("running").?.bool,
    });
    try out.flush();
}
