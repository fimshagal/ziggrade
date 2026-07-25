# Ziggrade

Reactive data store for Zig — simulations, tools, native apps. Same idea as [tardigrade-store](https://www.npmjs.com/package/tardigrade-store): a tiny core that holds data and notifies on change, plus optional layers you attach only when needed.

```
core (store + value)     ← always
  ├─ typed               ← comptime schema facade (optional)
  ├─ ward                ← write rules (optional)
  ├─ history             ← delta undo/redo (optional)
  └─ persist             ← Storage adapters (optional)
```

No React / Vue / Svelte bridges. Values are an explicit tagged union; the store owns them.

Requires **Zig 0.16+**.

---

## Install

Add this repo as a dependency (path or fetch), then in `build.zig`:

```zig
const ziggrade = b.dependency("Ziggrade", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("Ziggrade", ziggrade.module("Ziggrade"));
```

```zig
const Ziggrade = @import("Ziggrade");
```

---

## Quick start

```zig
const std = @import("std");
const Ziggrade = @import("Ziggrade");

pub fn main() !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    const store = try Ziggrade.createStore(gpa, .{ .name = "sim" });
    defer store.destroy();

    store.addProp("tick", Ziggrade.Value.fromInt(0));
    store.addProp("running", Ziggrade.Value.fromBool(true));

    _ = store.addListener(null, struct {
        fn onChange(_: ?*anyopaque, change: Ziggrade.Change) void {
            switch (change) {
                .single => |s| std.log.info("changed {s}", .{s.name}),
                .batch => |b| std.log.info("batch ({d})", .{b.names.len}),
            }
        }
    }.onChange);

    // Batch: write all, then notify globals once
    store.setProps(&.{
        .{ .name = "tick", .value = Ziggrade.Value.fromInt(1) },
        .{ .name = "running", .value = Ziggrade.Value.fromBool(false) },
    });
}
```

---

## Core features

### Props

- `addProp(name, value)` — type is locked on first non-null value
- `setProp(name, value)` — must match locked type; `null` clears without changing type
- `propRef(name)` — borrowed internal value (fast; invalidated by the next write)
- `getProp(name)` — deep clone; caller must `deinit`
- Scalars (`bool`, `int`, `float`, `string`) skip notify when equal
- Complex (`array`, `object`) always write + notify

> **Ownership:** `addProp` / `setProp` / `setProps` **clone** into the store. Temporaries you allocated (e.g. `Value.fromString`) must be `deinit`’d by you.

### Listeners

| API | When it fires |
|-----|----------------|
| `addPropListener(name, ctx, fn)` | That prop changed |
| `addListener(ctx, fn)` | Any prop/resolver change |

No sync-on-subscribe — handlers run only on later writes. Global handler receives `Change.single` or `Change.batch`.

### Batch — `setProps`

```zig
store.setProps(&.{
    .{ .name = "hp", .value = Ziggrade.Value.fromInt(80) },
    .{ .name = "mp", .value = Ziggrade.Value.fromInt(20) },
});
```

1. Optional ward batch rule (can deny the whole patch)
2. Write every key
3. Prop listeners for keys that actually changed
4. **One** global notification with `.batch`

### Resolvers

Named sync functions for derived / imperative work (not auto-tracked computeds):

```zig
store.addResolver("score", null, struct {
    fn run(_: ?*anyopaque, s: *Ziggrade.Store) anyerror!Ziggrade.Value {
        const a = s.propRef("a").?.int;
        const b = s.propRef("b").?.int;
        return Ziggrade.Value.fromInt(a + b);
    }
}.run);
store.callResolver("score");
```

---

## TypedStore (comptime schema)

Optional typed API over the store. You declare a struct once; field names and types are checked at compile time. Under the hood it still talks to the same `Store` (string keys + `Value`), so layers attach as usual. Dynamic props remain available on `ts.store`.

```zig
const Sim = struct {
    tick: i64 = 0,
    running: bool = true,
    name: []const u8 = "sim",
};

const ts = try Ziggrade.TypedStore(Sim).create(gpa, .{ .name = "sim" }, .{});
defer ts.destroy();

ts.set(.tick, 1);
const n: i64 = ts.get(.tick);

ts.setPartial(.{ .tick = 2, .running = false });

_ = ts.listen(.tick, null, struct {
    fn onTick(_: ?*anyopaque, v: Ziggrade.Value) void {
        std.log.info("tick={}", .{v.int});
    }
}.onTick);
```

Supported field types today: `bool`, integers, floats, `[]const u8` / `[]u8`.

---

## Ward (write rules)

```zig
const link = try Ziggrade.WardLink.attach(store, gpa, .{});
defer link.dispose();

_ = try link.addPropRule("hp", null, struct {
    fn rule(_: ?*anyopaque, value: Ziggrade.Value) Ziggrade.WardOutcome {
        if (value == .int and value.int < 0) return .{ .deny = "hp >= 0" };
        return .{ .allow = null };
    }
}.rule);

link.hold();   // suspend rules (bulk import / restore)
link.unhold();
```

Order: global → kind → prop. One runner per store.

---

## History (delta undo/redo)

Stacks keep **only changed keys** per step (plus one full `present` snapshot for diffing). Changing `tick` in a store with 200 props records one delta entry, not 200 copies.

```zig
const hist = try Ziggrade.HistoryLink.attach(store, gpa, .{ .limit = 50 });
defer hist.dispose();

store.setProp("tick", Ziggrade.Value.fromInt(1));
_ = hist.undo();
_ = hist.redo();

hist.hold();
// ... many writes as one step ...
hist.unhold();
```

`removeProp` does not auto-notify — call `hist.record()` after structural edits if you need a step.

---

## Persist

Optional layer that snapshots store props to a `Storage` backend and can restore them on attach. You choose where bytes live:

| Adapter | Use |
|---------|-----|
| `MemoryStorage` | in-memory map (handy for tests) |
| `FileStorage` | `<dir>/<key>.json` via `std.Io` |
| custom | anything with `read` / `write` / `remove` |

```zig
var mem = Ziggrade.MemoryStorage.init(gpa);
defer mem.deinit();

const link = try Ziggrade.PersistLink.attach(store, gpa, .{
    .key = "slot-1",
    .storage = mem.storage(),
    .restore_on_start = true,
    .save_after_ms = 0, // sync; >0 → call link.poll(now_ms) from your loop
});
defer link.dispose();
```

Envelope: `{ "version": 1, "data": { ... } }` with optional `migrate`.

---

## Composition tip

```zig
// typical order
const ward = try Ziggrade.WardLink.attach(store, gpa, .{});
const persist = try Ziggrade.PersistLink.attach(store, gpa, .{ .key = "s", .storage = mem.storage() });
const hist = try Ziggrade.HistoryLink.attach(store, gpa, .{});
// hold all three around bulk restore/merge so rules/history/save don't thrash
```

---

## Tests & demo

```bash
zig build test
zig build run
```

Tests live next to the code (`test` blocks in `value.zig`, `store.zig`, `typed.zig`, `ward.zig`, `history.zig`, `persist.zig`).

Agent-oriented change log: see [`MEM.md`](./MEM.md).

---

## Layout

```
src/
  root.zig       exports
  value.zig      Value tagged union + JSON
  store.zig      core store
  typed.zig      TypedStore(Schema)
  ward.zig       rules layer
  history.zig    delta timeline
  persist.zig    Storage + PersistLink
  incidents.zig  soft warn/error
  main.zig       tiny demo CLI
```
