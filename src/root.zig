//! Ziggrade — reactive data store for Zig (simulations, tools, native apps).
//!
//! Lean core + optional layers, same idea as tardigrade-store:
//! - **core** (`store`, `value`) — props, listeners, batch `setProps`, ward hook
//! - **typed** — comptime schema facade (optional; does not replace the dynamic store)
//! - **ward** — write rules (optional)
//! - **history** — delta undo/redo (optional)
//! - **persist** — Storage adapters (optional)
//!
//! No UI framework bridges. Values are an explicit tagged union owned by the store.

const std = @import("std");

pub const value = @import("value.zig");
pub const Value = value.Value;
pub const ValueType = value.ValueType;

pub const incidents = @import("incidents.zig");
pub const IncidentsHandler = incidents.IncidentsHandler;

pub const store = @import("store.zig");
pub const Store = store.Store;
pub const StoreOptions = store.StoreOptions;
pub const PatchEntry = store.PatchEntry;
pub const Change = store.Change;
pub const SessionKey = store.SessionKey;
pub const ListenerId = store.ListenerId;
pub const WardContext = store.WardContext;
pub const WardOutcome = store.WardOutcome;
pub const WardKind = store.WardKind;

pub const typed = @import("typed.zig");
pub const TypedStore = typed.TypedStore;

pub const ward = @import("ward.zig");
pub const WardLink = ward.WardLink;

pub const history = @import("history.zig");
pub const HistoryLink = history.HistoryLink;

pub const persist = @import("persist.zig");
pub const PersistLink = persist.PersistLink;
pub const Storage = persist.Storage;
pub const MemoryStorage = persist.MemoryStorage;
pub const FileStorage = persist.FileStorage;

pub const createStore = Store.create;

test {
    std.testing.refAllDecls(@This());
}
