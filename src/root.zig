//! `zautomerge` — a direct Zig 0.16 translation of the `automerge` library.
//!
//! A JSON-like CRDT that several devices can edit concurrently and merge
//! without conflict-resolution code, with an efficient binary document format
//! and a sync protocol for any reliable in-order transport.
//!
//! Nothing is implemented yet. The port plan is in `docs/plan.md`, the target
//! public surface is in `API.md`, and the status is in `PROJECT.md`. This file
//! becomes the re-export point for the public modules as each plan phase lands.

/// The version of this port. Tracks the upstream `automerge` crate it targets.
pub const version = "0.0.0";
