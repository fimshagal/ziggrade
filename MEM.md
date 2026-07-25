# MEM — agent change log

Short history of intentional changes for humans and agents working on Ziggrade.
Append a new dated section for each meaningful session; keep entries factual.

---

## 2026-07-25 — initial port from tardigrade-store

### Goal
Port the tardigrade-store approach to Zig: lean reactive core + optional layers, for simulations / native use (no UI bridges).

### Added
- **Core:** `value.zig` (`Value` tagged union), `store.zig` (props, listeners, `setProps` batch, resolvers, ward hook, lifecycle), `incidents.zig`
- **Layers:** `ward.zig`, `history.zig`, `persist.zig` (`MemoryStorage`, `FileStorage` via `std.Io`)
- **Package:** `root.zig` re-exports, demo `main.zig`, Zig 0.16 `build.zig`

### Zig adaptations (vs TS tardigrade)
- Explicit `Value` instead of JS dynamics; store clones on write
- Listeners = fn pointer + `?*anyopaque` ctx; ids instead of function identity
- `bool` treated as scalar (equality skip) — intentional divergence
- Resolvers sync-only
- Persist = `Storage` vtable (no localStorage); debounce via `poll(now_ms)`

### Tests
- Inline tests for value / store / ward / history / persist
- Soft incidents silenced in tests that expect denied/invalid writes (Zig 0.16 fails on `log.err`)

---

## 2026-07-25 — docs, typed facade, delta history

### Goal
Document the library; add comptime schema + delta undo/redo; agent memory file.

### Added
- `README.md` — features, examples, composition notes
- `.gitignore` — zig-cache, zig-out, editor junk
- `MEM.md` — this file
- `typed.zig` — `TypedStore(Schema)` comptime facade (`get` / `set` / `setPartial` / `listen`)
- History rewritten to **delta steps** (changed keys only) + one `present` snapshot

### Why comptime schema does not break reactivity
`TypedStore` only maps comptime fields ↔ string props and forwards to `Store.setProp` / `setProps`. Observer lists, ward runner, history listener, and persist listener are unchanged. Dynamic props remain available on `ts.store`.

### Why delta history
Full snapshots per step copy the entire picked prop map. Sims usually mutate few keys; deltas store `before`/`after` per changed key (null = add/remove). Undo/redo apply the delta forward/backward, then refresh `present`.

### Tests added
- `typed.zig`: get/set/batch/listen + dynamic extra prop
- `history.zig`: delta size on single-key change; add/remove via hold/unhold
