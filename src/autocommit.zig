//! Owning lazy-transaction facade over the raw Document and its existing transaction engine.
//! Ordinary reads see pending writes without committing. History, save, diff, setters and sync
//! close the held transaction. Closed values can move; open values must keep a stable address.
const std = @import("std");
const docmod = @import("doc.zig");
const transact = @import("transact.zig");
const transactionmod = @import("transaction.zig");
const readmod = @import("read.zig");
const types = @import("types.zig");
const patchesmod = @import("patches.zig");
const hydmod = @import("hydrate.zig");
const marksmod = @import("marks.zig");
const cursormod = @import("cursor.zig");
const protocol = @import("sync/protocol.zig");
const statemod = @import("sync/state.zig");
const messagemod = @import("sync/message.zig");
const changemod = @import("change.zig");
const anonymizemod = @import("anonymize.zig");
const Allocator = std.mem.Allocator;
const ExId = types.ExId;
const ChangeHash = types.ChangeHash;
const ActorId = types.ActorId;
const Prop = types.Prop;
const ObjType = types.ObjType;
const OpId = types.OpId;
const ScalarValue = @import("value.zig").ScalarValue;
/// Nonclosing reader failures use the canonical shared reader error contract.
pub const ReadError = readmod.ReadError;

/// One document owner, one optional transaction, and one independent diff cache.
/// Assignment transfers ownership only while closed. Use cloneInto for an independent copy.
/// Once a transaction opens, do not relocate this value until commit or rollback succeeds.
/// The allocator and I/O provider supplied at construction must outlive the owner.
/// All borrowed reads are invalidated by mutation or deinit; owned outputs name their allocator.
pub const AutoCommit = struct {
    /// Embedded raw state. Direct raw mutation while a transaction is open is invalid.
    doc: docmod.Document,
    /// The sole held transaction and recovery owner; null means closed.
    transaction: ?transact.Transaction = null,
    /// Owns keys, actor identity and patches independently of returned batches.
    diff_cache: ?DiffCache = null,

    const DiffCache = struct {
        hashes: []ChangeHash,
        before_len: usize,
        counter: ?u64,
        actor: []u8,
        recursive: bool,
        patches: patchesmod.Patches,

        fn deinit(self: *DiffCache, gpa: Allocator) void {
            gpa.free(self.hashes);
            gpa.free(self.actor);
            self.patches.deinit();
        }

        fn matches(self: *const DiffCache, before: []const ChangeHash, after: []const ChangeHash, counter: ?u64, actor: []const u8, recursive: bool) bool {
            return self.before_len == before.len and self.counter == counter and
                self.recursive == recursive and std.mem.eql(u8, self.actor, actor) and
                std.mem.eql(u8, std.mem.sliceAsBytes(self.hashes[0..self.before_len]), std.mem.sliceAsBytes(before)) and
                std.mem.eql(u8, std.mem.sliceAsBytes(self.hashes[self.before_len..]), std.mem.sliceAsBytes(after));
        }
    };

    /// Constructs a closed owner using the declared default text encoding.
    pub fn init(gpa: Allocator, io: std.Io) docmod.InitError!AutoCommit {
        return .{ .doc = try docmod.Document.init(gpa, io) };
    }

    /// Constructs a closed owner with explicit native text indexing units.
    pub fn initWithEncoding(gpa: Allocator, io: std.Io, encoding: types.TextEncoding) docmod.InitError!AutoCommit {
        return .{ .doc = try docmod.Document.initWithEncoding(gpa, io, encoding) };
    }

    /// Consumes a raw document with no externally held transaction.
    pub fn fromDocument(document_value: docmod.Document) AutoCommit {
        return .{ .doc = document_value };
    }

    /// Loads a closed owner; bytes are borrowed only during the call.
    pub fn load(gpa: Allocator, io: std.Io, bytes: []const u8, encoding: types.TextEncoding) docmod.LoadError!AutoCommit {
        return loadWithOptions(gpa, io, bytes, .{ .text_encoding = encoding });
    }

    /// Loads with the raw loader's complete policies and borrowed external log.
    pub fn loadWithOptions(gpa: Allocator, io: std.Io, bytes: []const u8, options: docmod.LoadOptions) docmod.LoadError!AutoCommit {
        return .{ .doc = try docmod.Document.loadWithOptions(gpa, io, bytes, options) };
    }

    /// Skips stored-head verification only, retaining framing and column validation.
    pub fn loadUnverifiedHeads(gpa: Allocator, io: std.Io, bytes: []const u8, options: docmod.LoadOptions) docmod.LoadError!AutoCommit {
        return .{ .doc = try docmod.Document.loadUnverifiedHeads(gpa, io, bytes, options) };
    }

    /// Destroys the transaction journal together with its document, without publishing a change.
    /// Every resource is released once; the owner is unusable afterward.
    pub fn deinit(self: *AutoCommit) void {
        if (self.transaction) |*tx| tx.deinitClosed();
        self.invalidateDiffCache();
        self.doc.deinit();
        self.* = undefined;
    }

    /// The retained allocator used for owner state and pending journals.
    pub fn allocator(self: *const AutoCommit) Allocator {
        return self.doc.allocator();
    }

    fn invalidateDiffCache(self: *AutoCommit) void {
        if (self.diff_cache) |*cache| cache.deinit(self.allocator());
        self.diff_cache = null;
    }

    /// Opens the sole held engine lazily. Refusal retains the closed log and owner.
    pub fn ensureTransactionOpen(self: *AutoCommit) transact.WriteError!*transact.Transaction {
        if (self.transaction) |*tx| return tx;
        self.transaction = try transact.Transaction.openWithPatchLog(self.allocator(), &self.doc, &self.doc.patch_log, self.doc.isolation);
        return &self.transaction.?;
    }

    /// Closes only an existing transaction; refusal retains it for commit or rollback retry.
    pub fn ensureTransactionClosed(self: *AutoCommit) transact.WriteError!void {
        if (self.transaction != null) _ = try self.commitWith(.{});
    }

    /// Number of operations currently owned by the pending journal, without closing.
    pub fn pendingOps(self: *const AutoCommit) usize {
        return if (self.transaction) |*tx| tx.count() else 0;
    }

    /// Borrowed current isolation or full graph heads, without publishing pending writes.
    pub fn baseHeads(self: *const AutoCommit) []const ChangeHash {
        return self.doc.viewHeads();
    }

    /// Commits pending work; null is a no-op commit, never a synthetic empty change.
    pub fn commit(self: *AutoCommit) transact.WriteError!?ChangeHash {
        return self.commitWith(.{});
    }

    /// Commits under borrowed options. On refusal the journal and complete log stay owned here.
    pub fn commitWith(self: *AutoCommit, options: transactionmod.CommitOptions) transact.WriteError!?ChangeHash {
        const tx = try self.ensureTransactionOpen();
        const isolated_heads = if (self.doc.isolation != null and tx.count() != 0)
            try self.allocator().alloc(ChangeHash, 1)
        else
            null;
        errdefer if (isolated_heads) |heads| self.allocator().free(heads);
        const result = try tx.commitWith(options);
        self.doc.patch_log.deinit();
        self.doc.patch_log = result.patch_log;
        tx.deinitClosed();
        self.transaction = null;
        if (isolated_heads) |heads| {
            if (result.hash) |hash| {
                heads[0] = hash;
                self.doc.installIsolationOwned(heads);
            } else self.allocator().free(heads);
        }
        if (result.hash != null) self.invalidateDiffCache();
        return result.hash;
    }

    /// Cancels pending work. A refusal retains the sole journal and its cancellation progress.
    pub fn rollback(self: *AutoCommit) transact.WriteError!usize {
        const tx = if (self.transaction) |*held| held else return 0;
        const cancelled = try tx.rollback();
        self.doc.patch_log.deinit();
        self.doc.patch_log = tx.takePatchLog();
        tx.deinitClosed();
        self.transaction = null;
        self.invalidateDiffCache();
        return cancelled;
    }

    /// Closes pending work first, then publishes a distinct zero-operation change.
    pub fn emptyChange(self: *AutoCommit, options: transactionmod.CommitOptions) transact.WriteError!ChangeHash {
        try self.ensureTransactionClosed();
        const isolated_heads = if (self.doc.isolation != null)
            try self.allocator().alloc(ChangeHash, 1)
        else
            null;
        errdefer if (isolated_heads) |heads| self.allocator().free(heads);
        const hash = try self.doc.emptyCommit(self.allocator(), options.message, options.time);
        if (isolated_heads) |heads| {
            heads[0] = hash;
            self.doc.installIsolationOwned(heads);
        }
        self.invalidateDiffCache();
        return hash;
    }

    /// Initializes an independent copy at its final address without closing the source.
    /// On failure destination is uninitialized; source and its pending owner remain unchanged.
    pub fn cloneInto(self: *const AutoCommit, gpa: Allocator, destination: *AutoCommit) !void {
        destination.* = .{ .doc = try @constCast(&self.doc).clonePending(gpa) };
        errdefer destination.deinit();
        if (self.transaction) |*tx| {
            destination.transaction = try tx.cloneInto(gpa, &destination.doc);
        }
        if (self.diff_cache) |*cache| {
            const hashes = try gpa.dupe(ChangeHash, cache.hashes);
            errdefer gpa.free(hashes);
            const actor = try gpa.dupe(u8, cache.actor);
            errdefer gpa.free(actor);
            destination.diff_cache = .{
                .hashes = hashes,
                .before_len = cache.before_len,
                .counter = cache.counter,
                .actor = actor,
                .recursive = cache.recursive,
                .patches = try cache.patches.clone(gpa),
            };
        }
    }

    /// Closes pending work and returns a fresh closed fork with independent cursors and cache.
    pub fn fork(self: *AutoCommit, gpa: Allocator) !AutoCommit {
        try self.ensureTransactionClosed();
        return freshFork(try self.doc.fork(gpa));
    }

    /// Closes pending work and forks the historical heads into a new closed owner.
    pub fn forkAt(self: *AutoCommit, gpa: Allocator, heads: []const ChangeHash) !AutoCommit {
        try self.ensureTransactionClosed();
        return freshFork(try self.doc.forkAt(gpa, heads));
    }

    /// Raw forks start fresh cursors; the facade additionally starts outside isolation.
    fn freshFork(document_value: docmod.Document) AutoCommit {
        var owner = AutoCommit.fromDocument(document_value);
        if (owner.doc.isolation) |heads| owner.allocator().free(heads);
        owner.doc.isolation = null;
        return owner;
    }

    /// Closes pending work and returns an independent anonymized closed owner.
    pub fn anonymize(self: *AutoCommit, gpa: Allocator, seed: [anonymizemod.seed_length]u8) !AutoCommit {
        try self.ensureTransactionClosed();
        return .{ .doc = try anonymizemod.anonymize(gpa, &self.doc, seed) };
    }

    /// Returns a raw borrowed document only after the pending transaction closes.
    pub fn document(self: *AutoCommit) !*docmod.Document {
        try self.ensureTransactionClosed();
        return &self.doc;
    }

    /// Closes pending work and changes the actor used by subsequent transactions.
    pub fn setActorId(self: *AutoCommit, actor: ActorId) !void {
        try self.ensureTransactionClosed();
        self.invalidateDiffCache();
        const kept = try self.doc.arena.allocator().dupe(u8, actor.bytes);
        self.doc.setActorId(.{ .bytes = kept });
    }

    /// Closes pending work and changes arbitrary author bytes for subsequent transactions.
    pub fn setAuthor(self: *AutoCommit, gpa: Allocator, author: ?[]const u8) !void {
        try self.ensureTransactionClosed();
        self.invalidateDiffCache();
        try self.doc.setAuthor(gpa, author);
    }

    /// Changes the actor and returns this same address-stable owner for chaining.
    pub fn withActor(self: *AutoCommit, actor: ActorId) !*AutoCommit {
        try self.setActorId(actor);
        return self;
    }

    /// Changes author bytes and returns this same address-stable owner for chaining.
    pub fn withAuthor(self: *AutoCommit, gpa: Allocator, author: ?[]const u8) !*AutoCommit {
        try self.setAuthor(gpa, author);
        return self;
    }

    /// Closes pending work and selects a historical read/write view without deleting history.
    pub fn isolate(self: *AutoCommit, gpa: Allocator, heads: []const ChangeHash) !void {
        try self.ensureTransactionClosed();
        self.invalidateDiffCache();
        try self.doc.isolate(gpa, heads);
    }

    /// Closes pending work before returning to the full committed view; refusal preserves scope.
    pub fn integrate(self: *AutoCommit) !void {
        try self.ensureTransactionClosed();
        self.invalidateDiffCache();
        try self.doc.integrate();
    }

    /// Closes pending work and copies the isolation view's heads into caller-owned storage.
    pub fn getHeads(self: *AutoCommit, gpa: Allocator) ![]ChangeHash {
        try self.ensureTransactionClosed();
        return gpa.dupe(ChangeHash, self.doc.viewHeads());
    }

    /// Closes pending work and compares exact ordered peer heads against the full graph.
    pub fn hasOurChanges(self: *AutoCommit, state: *const statemod.State) !bool {
        try self.ensureTransactionClosed();
        return self.doc.hasOurChanges(state);
    }

    /// Closes pending work and starts indexed patch recording from the current view.
    pub fn updateDiffCursor(self: *AutoCommit) !void {
        try self.ensureTransactionClosed();
        try self.doc.updateDiffCursor();
    }

    /// Closes pending work, erases the diff cursor and disables indexed recording.
    pub fn resetDiffCursor(self: *AutoCommit) !void {
        try self.ensureTransactionClosed();
        self.doc.resetDiffCursor();
    }

    /// Copies the cursor without closing; caller releases the returned hashes with gpa.
    pub fn diffCursor(self: *const AutoCommit, gpa: Allocator) ![]ChangeHash {
        return self.doc.diffCursor(gpa);
    }

    /// Materializes caller-owned patches from a borrowed external log without closing.
    pub fn makePatches(self: *AutoCommit, log: *patchesmod.PatchLog) !patchesmod.Patches {
        return self.doc.makePatches(log);
    }

    /// Closes pending work and returns an independent cached root diff.
    pub fn diff(self: *AutoCommit, gpa: Allocator, before: []const ChangeHash, after: []const ChangeHash) !patchesmod.Patches {
        return self.diffObj(gpa, .root, before, after, true);
    }

    /// Closes pending work. Cache owns exact ordered ranges, durable actor bytes and its patches.
    /// Every returned batch is independent. Allocation refusal leaves a valid previous cache intact.
    pub fn diffObj(self: *AutoCommit, gpa: Allocator, obj: ExId, before: []const ChangeHash, after: []const ChangeHash, recursive: bool) !patchesmod.Patches {
        try self.ensureTransactionClosed();
        const live = self.doc.resolve(obj) orelse return error.NotAnObject;
        _ = try self.doc.objectType(live);
        const counter = live.counter();
        const actor = if (live.opId()) |id|
            (self.doc.getActor(id.actor) orelse return error.InvalidActorIndex).bytes
        else
            "";
        if (self.diff_cache) |*cache| {
            if (cache.matches(before, after, counter, actor, recursive)) {
                return cache.patches.clone(gpa);
            }
        }
        var output = if (switch (live) {
            .root => recursive,
            else => false,
        })
            try self.doc.diffInner(gpa, live, before, after, recursive)
        else
            try self.doc.diffObj(gpa, live, before, after, recursive);
        errdefer output.deinit();
        const owner_gpa = self.allocator();
        const hashes = try owner_gpa.alloc(ChangeHash, try std.math.add(usize, before.len, after.len));
        errdefer owner_gpa.free(hashes);
        @memcpy(hashes[0..before.len], before);
        @memcpy(hashes[before.len..], after);
        const actor_copy = try owner_gpa.dupe(u8, actor);
        errdefer owner_gpa.free(actor_copy);
        const retained = try output.clone(owner_gpa);
        self.invalidateDiffCache();
        self.diff_cache = .{ .hashes = hashes, .before_len = before.len, .counter = counter, .actor = actor_copy, .recursive = recursive, .patches = retained };
        return output;
    }

    /// Returns an independent diff then advances the cursor only after the diff succeeds.
    pub fn diffIncremental(self: *AutoCommit, gpa: Allocator) !patchesmod.Patches {
        try self.ensureTransactionClosed();
        var output = try self.diff(gpa, self.doc.diff_cursor.items, self.doc.viewHeads());
        errdefer output.deinit();
        try self.updateDiffCursor();
        return output;
    }

    /// Closes pending writes before participating in the existing sync protocol.
    pub fn sync(self: *AutoCommit) !Sync {
        try self.ensureTransactionClosed();
        return .{ .owner = self };
    }

    /// Closes pending writes and generates a message owned by the caller.
    pub fn generateSyncMessage(self: *AutoCommit, gpa: Allocator, state: *statemod.State) !?messagemod.Message {
        try self.ensureTransactionClosed();
        return protocol.generateSyncMessage(gpa, &self.doc, state);
    }

    /// Consumes message on every path; pending-close refusal is also ownership-safe.
    pub fn receiveSyncMessage(self: *AutoCommit, gpa: Allocator, state: *statemod.State, message: messagemod.Message) !void {
        self.ensureTransactionClosed() catch |err| {
            var consumed = message;
            consumed.deinit();
            return err;
        };
        self.invalidateDiffCache();
        if (self.doc.isolation != null) {
            var null_log = patchesmod.PatchLog.inactive(self.allocator());
            defer null_log.deinit();
            return protocol.receiveSyncMessageWithPatchLog(gpa, &self.doc, state, message, &null_log);
        }
        return protocol.receiveSyncMessageWithPatchLog(gpa, &self.doc, state, message, &self.doc.patch_log);
    }

    /// Consumes message, borrows log, and closes pending work before external-log sync receive.
    /// Actor compatibility is checked by Document after the close barrier; the log stays caller-owned.
    pub fn receiveSyncMessageWithPatchLog(self: *AutoCommit, gpa: Allocator, state: *statemod.State, message: messagemod.Message, log: *patchesmod.PatchLog) !void {
        self.ensureTransactionClosed() catch |err| {
            var consumed = message;
            consumed.deinit();
            return err;
        };
        self.invalidateDiffCache();
        return protocol.receiveSyncMessageWithPatchLog(gpa, &self.doc, state, message, log);
    }

    /// Borrowed sync facade. The AutoCommit must stay alive at the same address during use.
    pub const Sync = struct {
        owner: *AutoCommit,
        /// Generates through the owner's sole close barrier and existing protocol.
        pub fn generateSyncMessage(self: Sync, gpa: Allocator, state: *statemod.State) !?messagemod.Message {
            return self.owner.generateSyncMessage(gpa, state);
        }
        /// Consumes message through the owner's scope-aware patch sink.
        pub fn receiveSyncMessage(self: Sync, gpa: Allocator, state: *statemod.State, message: messagemod.Message) !void {
            return self.owner.receiveSyncMessage(gpa, state, message);
        }
        /// Consumes message while borrowing the caller's independent patch log.
        pub fn receiveSyncMessageWithPatchLog(self: Sync, gpa: Allocator, state: *statemod.State, message: messagemod.Message, log: *patchesmod.PatchLog) !void {
            return self.owner.receiveSyncMessageWithPatchLog(gpa, state, message, log);
        }
    };

    /// Nonclosing scoped read; ownership and iterator lifetime follow read.get.
    pub fn get(self: *AutoCommit, obj: ExId, prop: Prop) ReadError!?readmod.DocItem {
        if (self.transaction) |*tx| return tx.get(obj, prop);
        return readmod.get(&self.doc, obj, prop);
    }

    /// Nonclosing scoped read; ownership and iterator lifetime follow read.getAt.
    pub fn getAt(self: *AutoCommit, obj: ExId, prop: Prop, heads: []const ChangeHash) ReadError!?readmod.DocItem {
        if (self.transaction) |*tx| return tx.getAt(obj, prop, heads);
        return readmod.getAt(&self.doc, obj, prop, heads);
    }

    /// Nonclosing scoped read; ownership and iterator lifetime follow read.getAll.
    pub fn getAll(self: *AutoCommit, obj: ExId, prop: Prop, gpa: Allocator) ReadError![]readmod.DocItem {
        if (self.transaction) |*tx| return tx.getAll(obj, prop, gpa);
        return readmod.getAll(&self.doc, obj, prop, gpa);
    }

    /// Nonclosing scoped read; ownership and iterator lifetime follow read.getAllAt.
    pub fn getAllAt(self: *AutoCommit, obj: ExId, prop: Prop, heads: []const ChangeHash, gpa: Allocator) ReadError![]readmod.DocItem {
        if (self.transaction) |*tx| return tx.getAllAt(obj, prop, heads, gpa);
        return readmod.getAllAt(&self.doc, obj, prop, heads, gpa);
    }

    /// Nonclosing scoped read; ownership and iterator lifetime follow read.keys.
    pub fn keys(self: *AutoCommit, obj: ExId) ReadError!readmod.Keys {
        if (self.transaction) |*tx| return tx.keys(obj);
        return readmod.keys(&self.doc, obj);
    }

    /// Nonclosing scoped read; ownership and iterator lifetime follow read.keysAt.
    pub fn keysAt(self: *AutoCommit, obj: ExId, heads: []const ChangeHash) ReadError!readmod.Keys {
        if (self.transaction) |*tx| return tx.keysAt(obj, heads);
        return readmod.keysAt(&self.doc, obj, heads);
    }

    /// Nonclosing scoped read; ownership and iterator lifetime follow read.length.
    pub fn length(self: *AutoCommit, obj: ExId) ReadError!usize {
        if (self.transaction) |*tx| return tx.length(obj);
        return readmod.length(&self.doc, obj);
    }

    /// Nonclosing scoped read; ownership and iterator lifetime follow read.lengthAt.
    pub fn lengthAt(self: *AutoCommit, obj: ExId, heads: []const ChangeHash) ReadError!usize {
        if (self.transaction) |*tx| return tx.lengthAt(obj, heads);
        return readmod.lengthAt(&self.doc, obj, heads);
    }

    /// Nonclosing scoped read; ownership and iterator lifetime follow read.text.
    pub fn text(self: *AutoCommit, obj: ExId, gpa: Allocator) ReadError![]u8 {
        if (self.transaction) |*tx| return tx.text(obj, gpa);
        return readmod.text(&self.doc, obj, gpa);
    }

    /// Nonclosing scoped read; ownership and iterator lifetime follow read.textAt.
    pub fn textAt(self: *AutoCommit, obj: ExId, heads: []const ChangeHash, gpa: Allocator) ReadError![]u8 {
        if (self.transaction) |*tx| return tx.textAt(obj, heads, gpa);
        return readmod.textAt(&self.doc, obj, heads, gpa);
    }

    /// Nonclosing scoped read; ownership and iterator lifetime follow read.spans.
    pub fn spans(self: *AutoCommit, obj: ExId, gpa: Allocator) ReadError!readmod.Spans {
        if (self.transaction) |*tx| return tx.spans(obj, gpa);
        return readmod.spans(&self.doc, obj, gpa);
    }

    /// Nonclosing scoped read; ownership and iterator lifetime follow read.spansAt.
    pub fn spansAt(self: *AutoCommit, obj: ExId, heads: []const ChangeHash, gpa: Allocator) ReadError!readmod.Spans {
        if (self.transaction) |*tx| return tx.spansAt(obj, heads, gpa);
        return readmod.spansAt(&self.doc, obj, heads, gpa);
    }

    /// Nonclosing scoped read; ownership and iterator lifetime follow read.marks.
    pub fn marks(self: *AutoCommit, obj: ExId, gpa: Allocator) ReadError![]marksmod.Mark {
        if (self.transaction) |*tx| return tx.marks(obj, gpa);
        return readmod.marks(&self.doc, obj, gpa);
    }

    /// Nonclosing scoped read; ownership and iterator lifetime follow read.marksAt.
    pub fn marksAt(self: *AutoCommit, obj: ExId, heads: []const ChangeHash, gpa: Allocator) ReadError![]marksmod.Mark {
        if (self.transaction) |*tx| return tx.marksAt(obj, heads, gpa);
        return readmod.marksAt(&self.doc, obj, heads, gpa);
    }

    /// Reads mark runs clipped to a window without closing pending writes.
    /// Caller owns the run slice; mark names and values retain the read module's lifetime.
    pub fn getMarks(self: *AutoCommit, obj: ExId, start: usize, end: usize, gpa: Allocator) ReadError![]marksmod.Mark {
        if (self.transaction) |*tx| return tx.getMarks(obj, start, end, gpa);
        return readmod.getMarks(&self.doc, obj, start, end, gpa);
    }

    /// Nonclosing scoped read; ownership and iterator lifetime follow read.markSetAtIndex.
    pub fn markSetAtIndex(self: *AutoCommit, obj: ExId, index: usize, heads: ?[]const ChangeHash, gpa: Allocator) ReadError!marksmod.MarkSet {
        if (self.transaction) |*tx| return tx.markSetAtIndex(obj, index, heads, gpa);
        return readmod.markSetAtIndex(&self.doc, obj, index, heads, gpa);
    }

    /// Nonclosing scoped read; ownership and iterator lifetime follow read.parents.
    pub fn parents(self: *AutoCommit, obj: ExId) ReadError!readmod.Parents {
        if (self.transaction) |*tx| return tx.parents(obj);
        return readmod.parents(&self.doc, obj);
    }

    /// Nonclosing scoped read; ownership and iterator lifetime follow read.parentsAt.
    pub fn parentsAt(self: *AutoCommit, obj: ExId, heads: []const ChangeHash) ReadError!readmod.Parents {
        if (self.transaction) |*tx| return tx.parentsAt(obj, heads);
        return readmod.parentsAt(&self.doc, obj, heads);
    }

    /// Nonclosing scoped read; ownership and iterator lifetime follow read.mapRange.
    pub fn mapRange(self: *AutoCommit, obj: ExId, range: readmod.KeyRange) ReadError!readmod.MapRange {
        if (self.transaction) |*tx| return tx.mapRange(obj, range);
        return readmod.mapRange(&self.doc, obj, range);
    }

    /// Nonclosing scoped read; ownership and iterator lifetime follow read.mapRangeAt.
    pub fn mapRangeAt(self: *AutoCommit, obj: ExId, range: readmod.KeyRange, heads: []const ChangeHash) ReadError!readmod.MapRange {
        if (self.transaction) |*tx| return tx.mapRangeAt(obj, range, heads);
        return readmod.mapRangeAt(&self.doc, obj, range, heads);
    }

    /// Nonclosing scoped read; ownership and iterator lifetime follow read.listRange.
    pub fn listRange(self: *AutoCommit, obj: ExId, range: readmod.IndexRange) ReadError!readmod.ListRange {
        if (self.transaction) |*tx| return tx.listRange(obj, range);
        return readmod.listRange(&self.doc, obj, range);
    }

    /// Nonclosing scoped read; ownership and iterator lifetime follow read.listRangeAt.
    pub fn listRangeAt(self: *AutoCommit, obj: ExId, range: readmod.IndexRange, heads: []const ChangeHash) ReadError!readmod.ListRange {
        if (self.transaction) |*tx| return tx.listRangeAt(obj, range, heads);
        return readmod.listRangeAt(&self.doc, obj, range, heads);
    }

    /// Nonclosing scoped read; ownership and iterator lifetime follow read.values.
    pub fn values(self: *AutoCommit, obj: ExId, term: *readmod.ValueTerm) ReadError!readmod.Values {
        if (self.transaction) |*tx| return tx.values(obj, term);
        return readmod.values(&self.doc, obj, term);
    }

    /// Nonclosing scoped read; ownership and iterator lifetime follow read.valuesAt.
    pub fn valuesAt(self: *AutoCommit, obj: ExId, heads: []const ChangeHash, term: *readmod.ValueTerm) ReadError!readmod.Values {
        if (self.transaction) |*tx| return tx.valuesAt(obj, heads, term);
        return readmod.valuesAt(&self.doc, obj, heads, term);
    }

    /// Nonclosing scoped read; ownership and iterator lifetime follow read.iter.
    pub fn iter(self: *AutoCommit, gpa: Allocator) docmod.DiffError!readmod.DocIter {
        if (self.transaction) |*tx| return tx.iter(gpa);
        return readmod.iter(&self.doc, gpa);
    }

    /// Nonclosing scoped read; ownership and iterator lifetime follow read.iterAt.
    pub fn iterAt(self: *AutoCommit, obj: ExId, heads: ?[]const ChangeHash, gpa: Allocator) docmod.DiffError!readmod.DocIter {
        if (self.transaction) |*tx| return tx.iterAt(obj, heads, gpa);
        return readmod.iterAt(&self.doc, obj, heads, gpa);
    }

    /// Nonclosing scoped read; ownership and iterator lifetime follow read.getCursor.
    pub fn getCursor(self: *AutoCommit, obj: ExId, pos: cursormod.CursorPosition, heads: ?[]const ChangeHash, gpa: Allocator) ReadError!cursormod.Cursor {
        if (self.transaction) |*tx| return tx.getCursor(obj, pos, heads, gpa);
        return readmod.getCursor(&self.doc, obj, pos, heads, gpa);
    }

    /// Nonclosing scoped read; ownership and iterator lifetime follow read.getCursorMoving.
    pub fn getCursorMoving(self: *AutoCommit, obj: ExId, pos: cursormod.CursorPosition, heads: ?[]const ChangeHash, bias: cursormod.MoveCursor, gpa: Allocator) ReadError!cursormod.Cursor {
        if (self.transaction) |*tx| return tx.getCursorMoving(obj, pos, heads, bias, gpa);
        return readmod.getCursorMoving(&self.doc, obj, pos, heads, bias, gpa);
    }

    /// Nonclosing scoped read; ownership and iterator lifetime follow read.getCursorPosition.
    pub fn getCursorPosition(self: *AutoCommit, obj: ExId, cursor: cursormod.Cursor, heads: ?[]const ChangeHash) ReadError!usize {
        if (self.transaction) |*tx| return tx.getCursorPosition(obj, cursor, heads);
        return readmod.getCursorPosition(&self.doc, obj, cursor, heads);
    }

    /// Hydrates the raw current view for null heads, deliberately bypassing isolation and pending scope.
    pub fn hydrate(self: *AutoCommit, obj: ExId, heads: ?[]const ChangeHash, gpa: Allocator) readmod.HydrateError!hydmod.Value {
        return readmod.hydrate(&self.doc, obj, heads, gpa);
    }

    /// The object's kind, including objects created by pending operations; does not close.
    pub fn objectType(self: *const AutoCommit, obj: ExId) @import("error.zig").Error!ObjType {
        return self.doc.objectType(obj);
    }

    /// Writes through the sole held transaction; producer errors retain that owner and earlier work.
    pub fn put(self: *AutoCommit, obj: ExId, prop: Prop, value: ScalarValue) transact.WriteError!?OpId {
        const tx = try self.ensureTransactionOpen();
        self.invalidateDiffCache();
        return tx.put(obj, prop, value);
    }

    /// Writes through the sole held transaction; producer errors retain that owner and earlier work.
    pub fn putObject(self: *AutoCommit, obj: ExId, prop: Prop, typ: ObjType) transact.WriteError!ExId {
        const tx = try self.ensureTransactionOpen();
        self.invalidateDiffCache();
        return tx.putObject(obj, prop, typ);
    }

    /// Writes through the sole held transaction; producer errors retain that owner and earlier work.
    pub fn insert(self: *AutoCommit, obj: ExId, index: usize, value: ScalarValue) transact.WriteError!OpId {
        const tx = try self.ensureTransactionOpen();
        self.invalidateDiffCache();
        return tx.insert(obj, index, value);
    }

    /// Writes through the sole held transaction; producer errors retain that owner and earlier work.
    pub fn insertObject(self: *AutoCommit, obj: ExId, index: usize, typ: ObjType) transact.WriteError!ExId {
        const tx = try self.ensureTransactionOpen();
        self.invalidateDiffCache();
        return tx.insertObject(obj, index, typ);
    }

    /// Writes through the sole held transaction; producer errors retain that owner and earlier work.
    pub fn increment(self: *AutoCommit, obj: ExId, prop: Prop, by: i64) transact.WriteError!void {
        const tx = try self.ensureTransactionOpen();
        self.invalidateDiffCache();
        return tx.increment(obj, prop, by);
    }

    /// Writes through the sole held transaction; producer errors retain that owner and earlier work.
    pub fn delete(self: *AutoCommit, obj: ExId, prop: Prop) transact.WriteError!usize {
        const tx = try self.ensureTransactionOpen();
        self.invalidateDiffCache();
        return tx.delete(obj, prop);
    }

    /// Writes through the sole held transaction; producer errors retain that owner and earlier work.
    pub fn splitBlock(self: *AutoCommit, obj: ExId, index: usize) transact.WriteError!ExId {
        const tx = try self.ensureTransactionOpen();
        self.invalidateDiffCache();
        return tx.splitBlock(obj, index);
    }

    /// Writes through the sole held transaction; producer errors retain that owner and earlier work.
    pub fn joinBlock(self: *AutoCommit, obj: ExId, index: usize) transact.WriteError!void {
        const tx = try self.ensureTransactionOpen();
        self.invalidateDiffCache();
        return tx.joinBlock(obj, index);
    }

    /// Writes through the sole held transaction; producer errors retain that owner and earlier work.
    pub fn replaceBlock(self: *AutoCommit, obj: ExId, index: usize) transact.WriteError!ExId {
        const tx = try self.ensureTransactionOpen();
        self.invalidateDiffCache();
        return tx.replaceBlock(obj, index);
    }

    /// Writes through the sole held transaction; producer errors retain that owner and earlier work.
    pub fn mark(self: *AutoCommit, obj: ExId, from: usize, to: usize, name: []const u8, expand: marksmod.ExpandMark, value: ?ScalarValue) transact.WriteError!void {
        const tx = try self.ensureTransactionOpen();
        self.invalidateDiffCache();
        return tx.mark(obj, from, to, name, expand, value);
    }

    /// Writes through the sole held transaction; producer errors retain that owner and earlier work.
    pub fn unmark(self: *AutoCommit, obj: ExId, from: usize, to: usize, expand: marksmod.ExpandMark, name: []const u8, value: ?ScalarValue) transact.WriteError!void {
        const tx = try self.ensureTransactionOpen();
        self.invalidateDiffCache();
        return tx.unmark(obj, from, to, expand, name, value);
    }

    /// Writes through the sole held transaction; producer errors retain that owner and earlier work.
    pub fn spliceText(self: *AutoCommit, obj: ExId, index: usize, del: isize, text_value: []const u8) transact.WriteError!void {
        const tx = try self.ensureTransactionOpen();
        self.invalidateDiffCache();
        return tx.spliceText(obj, index, del, text_value);
    }

    /// Writes through the sole held transaction; producer errors retain that owner and earlier work.
    pub fn splice(self: *AutoCommit, obj: ExId, index: usize, del: isize, inserted_values: []const hydmod.Value) transact.WriteError!void {
        const tx = try self.ensureTransactionOpen();
        self.invalidateDiffCache();
        return tx.splice(obj, index, del, inserted_values);
    }

    /// Writes through the sole held transaction; producer errors retain that owner and earlier work.
    pub fn updateText(self: *AutoCommit, obj: ExId, text_value: []const u8) transact.WriteError!void {
        const tx = try self.ensureTransactionOpen();
        self.invalidateDiffCache();
        return tx.updateText(obj, text_value);
    }

    /// Writes through the sole held transaction; producer errors retain that owner and earlier work.
    pub fn updateObject(self: *AutoCommit, obj: ExId, value: *const hydmod.Value) transact.WriteError!void {
        const tx = try self.ensureTransactionOpen();
        self.invalidateDiffCache();
        return tx.updateObject(obj, value);
    }

    /// Writes through the sole held transaction; producer errors retain that owner and earlier work.
    pub fn batchCreateObject(self: *AutoCommit, obj: ExId, prop: Prop, typ: ObjType) transact.WriteError!ExId {
        const tx = try self.ensureTransactionOpen();
        self.invalidateDiffCache();
        return tx.batchCreateObject(obj, prop, typ);
    }

    /// Writes through the sole held transaction; producer errors retain that owner and earlier work.
    pub fn batchCreateValue(self: *AutoCommit, obj: ExId, prop: Prop, value: hydmod.Value, as_insert: bool) transact.WriteError!ExId {
        const tx = try self.ensureTransactionOpen();
        self.invalidateDiffCache();
        return tx.batchCreateValue(obj, prop, value, as_insert);
    }

    /// Writes through the sole held transaction; producer errors retain that owner and earlier work.
    pub fn initRootFromHydrate(self: *AutoCommit, value: *const hydmod.Map) transact.WriteError!void {
        const tx = try self.ensureTransactionOpen();
        self.invalidateDiffCache();
        return tx.initRootFromHydrate(value);
    }

    /// Writes through the sole held transaction; producer errors retain that owner and earlier work.
    pub fn updateSpans(self: *AutoCommit, obj: ExId, spans_value: []const @import("iter/spans.zig").SpanInput) transact.WriteError!void {
        const tx = try self.ensureTransactionOpen();
        self.invalidateDiffCache();
        return tx.updateSpans(obj, spans_value);
    }

    /// Writes through the sole held transaction; producer errors retain that owner and earlier work.
    pub fn updateSpansWithConfig(self: *AutoCommit, obj: ExId, config: *const marksmod.UpdateSpansConfig, spans_value: []const @import("iter/spans.zig").SpanInput) transact.WriteError!void {
        const tx = try self.ensureTransactionOpen();
        self.invalidateDiffCache();
        return tx.updateSpansWithConfig(obj, config, spans_value);
    }

    /// Closes pending work before save; returned owned output follows the raw Document contract.
    pub fn save(self: *AutoCommit, gpa: Allocator) ![]u8 {
        try self.ensureTransactionClosed();
        return self.doc.save(gpa);
    }

    /// Closes pending work before saveWithOptions; returned owned output follows the raw Document contract.
    pub fn saveWithOptions(self: *AutoCommit, gpa: Allocator, options: docmod.Document.SaveOptions) ![]u8 {
        try self.ensureTransactionClosed();
        return self.doc.saveWithOptions(gpa, options);
    }

    /// Closes pending work before saveAfter; returned owned output follows the raw Document contract.
    pub fn saveAfter(self: *AutoCommit, gpa: Allocator, heads: []const ChangeHash) ![]u8 {
        try self.ensureTransactionClosed();
        return self.doc.saveAfter(gpa, heads);
    }

    /// Closes pending work before saveIncremental; returned owned output follows the raw Document contract.
    pub fn saveIncremental(self: *AutoCommit, gpa: Allocator) ![]u8 {
        try self.ensureTransactionClosed();
        return self.doc.saveIncremental(gpa);
    }

    /// Closes pending work before getChanges; returned owned output follows the raw Document contract.
    pub fn getChanges(self: *AutoCommit, gpa: Allocator, have: []const ChangeHash) !docmod.Changes {
        try self.ensureTransactionClosed();
        return self.doc.getChanges(gpa, have);
    }

    /// Closes pending work before getChangesMeta; returned owned output follows the raw Document contract.
    pub fn getChangesMeta(self: *AutoCommit, gpa: Allocator, have: []const ChangeHash) !docmod.ChangeMetas {
        try self.ensureTransactionClosed();
        return self.doc.getChangesMeta(gpa, have);
    }

    /// Closes pending work before getMissingDeps; returned owned output follows the raw Document contract.
    pub fn getMissingDeps(self: *AutoCommit, gpa: Allocator, heads: []const ChangeHash) ![]ChangeHash {
        try self.ensureTransactionClosed();
        return self.doc.getMissingDeps(gpa, heads);
    }

    /// Closes pending work before getChangeByHash; returned owned output follows the raw Document contract.
    pub fn getChangeByHash(self: *AutoCommit, gpa: Allocator, hash: ChangeHash) !?docmod.Built {
        try self.ensureTransactionClosed();
        return self.doc.getChangeByHash(gpa, hash);
    }

    /// Closes pending work before getChangeMetaByHash; returned owned output follows the raw Document contract.
    pub fn getChangeMetaByHash(self: *AutoCommit, gpa: Allocator, hash: ChangeHash) !?docmod.ChangeMetadata {
        try self.ensureTransactionClosed();
        return self.doc.getChangeMetaByHash(gpa, hash);
    }

    /// Closes pending work before getLastLocalChange; returned owned output follows the raw Document contract.
    pub fn getLastLocalChange(self: *AutoCommit, gpa: Allocator) !?docmod.Built {
        try self.ensureTransactionClosed();
        return self.doc.getLastLocalChange(gpa);
    }

    /// Saves then reloads using the same encoding to verify the produced bytes; caller owns output.
    pub fn saveAndVerify(self: *AutoCommit, gpa: Allocator) ![]u8 {
        const bytes = try self.save(gpa);
        errdefer gpa.free(bytes);
        var loaded = try docmod.Document.loadWithOptions(gpa, self.doc.io, bytes, .{ .text_encoding = self.textEncoding() });
        loaded.deinit();
        return bytes;
    }

    /// Closes both owners and returns independent changes absent from this owner's history.
    pub fn getChangesAdded(self: *AutoCommit, gpa: Allocator, other: *AutoCommit) !docmod.Changes {
        try self.ensureTransactionClosed();
        try other.ensureTransactionClosed();
        return self.doc.getChangesAdded(gpa, &other.doc);
    }

    /// Closes both owners before merging through the existing scope-aware borrowed log sink.
    pub fn merge(self: *AutoCommit, gpa: Allocator, other: *AutoCommit) ![]ChangeHash {
        try self.ensureTransactionClosed();
        try other.ensureTransactionClosed();
        self.invalidateDiffCache();
        if (self.doc.isolation != null) {
            var null_log = patchesmod.PatchLog.inactive(self.allocator());
            defer null_log.deinit();
            return self.doc.mergeWithPatchLog(gpa, &other.doc, &null_log);
        }
        return self.doc.mergeWithPatchLog(gpa, &other.doc, &self.doc.patch_log);
    }

    /// Closes both owners and borrows an external log for the merge only.
    pub fn mergeWithPatchLog(self: *AutoCommit, gpa: Allocator, other: *AutoCommit, log: *patchesmod.PatchLog) ![]ChangeHash {
        try self.ensureTransactionClosed();
        try other.ensureTransactionClosed();
        self.invalidateDiffCache();
        return self.doc.mergeWithPatchLog(gpa, &other.doc, log);
    }

    /// Closes pending work; isolated incoming changes use a null sink rather than changing view logs.
    pub fn applyChanges(self: *AutoCommit, gpa: Allocator, incoming: []const changemod.Change) !usize {
        try self.ensureTransactionClosed();
        self.invalidateDiffCache();
        if (self.doc.isolation != null) {
            var null_log = patchesmod.PatchLog.inactive(self.allocator());
            defer null_log.deinit();
            return self.doc.applyChangesWithPatchLog(gpa, incoming, &null_log);
        }
        return self.doc.applyChangesWithPatchLog(gpa, incoming, &self.doc.patch_log);
    }

    /// Public batch route uses the same existing batch engine and close/scope policy.
    pub fn applyChangesBatch(self: *AutoCommit, gpa: Allocator, incoming: []const changemod.Change) !usize {
        return self.applyChanges(gpa, incoming);
    }

    /// Closes pending work and borrows the caller's log only during batch application.
    pub fn applyChangesWithPatchLog(self: *AutoCommit, gpa: Allocator, incoming: []const changemod.Change, log: *patchesmod.PatchLog) !usize {
        try self.ensureTransactionClosed();
        self.invalidateDiffCache();
        return self.doc.applyChangesWithPatchLog(gpa, incoming, log);
    }

    /// Logged batch application uses the same validated sink and existing batch engine.
    pub fn applyChangesBatchWithPatchLog(self: *AutoCommit, gpa: Allocator, incoming: []const changemod.Change, log: *patchesmod.PatchLog) !usize {
        return self.applyChangesWithPatchLog(gpa, incoming, log);
    }

    /// Closes pending work before loading incremental bytes through the scope-aware sink.
    pub fn loadIncremental(self: *AutoCommit, gpa: Allocator, bytes: []const u8) !usize {
        try self.ensureTransactionClosed();
        self.invalidateDiffCache();
        if (self.doc.isolation != null) {
            var null_log = patchesmod.PatchLog.inactive(self.allocator());
            defer null_log.deinit();
            return self.doc.loadIncrementalWithPatchLog(gpa, bytes, &null_log);
        }
        return self.doc.loadIncrementalWithPatchLog(gpa, bytes, &self.doc.patch_log);
    }

    /// Closes pending work and borrows the caller's log during incremental loading.
    pub fn loadIncrementalWithPatchLog(self: *AutoCommit, gpa: Allocator, bytes: []const u8, log: *patchesmod.PatchLog) !usize {
        try self.ensureTransactionClosed();
        self.invalidateDiffCache();
        return self.doc.loadIncrementalWithPatchLog(gpa, bytes, log);
    }

    /// Delegates the raw getActorId inspection without closing pending work.
    pub fn getActorId(self: *const AutoCommit) ActorId {
        return self.doc.getActorId();
    }

    /// Delegates the raw getActorIndex inspection without closing pending work.
    pub fn getActorIndex(self: *const AutoCommit) ?types.ActorIdx {
        return self.doc.getActorIndex();
    }

    /// Delegates the raw getActor inspection without closing pending work.
    pub fn getActor(self: *const AutoCommit, idx: types.ActorIdx) ?ActorId {
        return self.doc.getActor(idx);
    }

    /// Delegates the raw getAuthor inspection without closing pending work.
    pub fn getAuthor(self: *const AutoCommit) ?[]const u8 {
        return self.doc.getAuthor();
    }

    /// Delegates the raw getAuthorForActor inspection without closing pending work.
    pub fn getAuthorForActor(self: *const AutoCommit, actor: ActorId) ?[]const u8 {
        return self.doc.getAuthorForActor(actor);
    }

    /// Delegates the raw getActorForAuthor inspection without closing pending work.
    pub fn getActorForAuthor(self: *const AutoCommit, gpa: Allocator, author: []const u8) ![]ActorId {
        return self.doc.getActorForAuthor(gpa, author);
    }

    /// Delegates the raw getActors inspection without closing pending work.
    pub fn getActors(self: *const AutoCommit, gpa: Allocator) ![]ActorId {
        return self.doc.getActors(gpa);
    }

    /// Delegates the raw getAuthors inspection without closing pending work.
    pub fn getAuthors(self: *const AutoCommit, gpa: Allocator) ![]const []const u8 {
        return self.doc.getAuthors(gpa);
    }

    /// Delegates the raw textEncoding inspection without closing pending work.
    pub fn textEncoding(self: *const AutoCommit) types.TextEncoding {
        return self.doc.textEncoding();
    }

    /// Delegates the raw stats inspection without closing pending work.
    pub fn stats(self: *const AutoCommit) docmod.Stats {
        return self.doc.stats();
    }

    /// Delegates the raw isEmpty inspection without closing pending work.
    pub fn isEmpty(self: *const AutoCommit) bool {
        return self.doc.isEmpty();
    }

    /// Delegates the raw hashForOpid inspection without closing pending work.
    pub fn hashForOpid(self: *const AutoCommit, id: ExId) ?ChangeHash {
        return self.doc.hashForOpid(id);
    }

    /// Delegates the raw fragments inspection without closing pending work.
    pub fn fragments(self: *const AutoCommit, gpa: Allocator, levels: @import("change_graph.zig").LevelRange) ![]@import("change_graph.zig").Fragment {
        return self.doc.fragments(gpa, levels);
    }

    /// Delegates the raw getFragment inspection without closing pending work.
    pub fn getFragment(self: *const AutoCommit, gpa: Allocator, head: ChangeHash) !?@import("change_graph.zig").Fragment {
        return self.doc.getFragment(gpa, head);
    }

    /// Delegates the raw objectParent inspection without closing pending work.
    pub fn objectParent(self: *const AutoCommit, obj: ExId) ?ExId {
        return self.doc.objectParent(obj);
    }

    /// Encodes committed history fragments without publishing pending writes; caller owns all buffers.
    pub fn bundle(self: *AutoCommit, gpa: Allocator, hashes: []const ChangeHash) !@import("storage/bundle.zig").Bundle {
        return self.doc.bundle(gpa, hashes);
    }

    /// Encodes selected committed fragments without closing; caller releases each buffer and array.
    pub fn bundleFragments(self: *AutoCommit, gpa: Allocator, wanted: []const @import("change_graph.zig").Fragment) ![][]u8 {
        return self.doc.bundleFragments(gpa, wanted);
    }

    /// Compares complete operation sets without closing either pending journal.
    /// Writer and diagnostic errors are propagated; the writer remains caller-owned.
    pub fn diffOpSet(self: *const AutoCommit, gpa: Allocator, other: *const AutoCommit, writer: *std.Io.Writer) !void {
        return self.doc.diffOpSet(gpa, &other.doc, writer);
    }

    /// Closes pending work before writing a diagnostic dump to the borrowed writer.
    pub fn dump(self: *AutoCommit, gpa: Allocator, writer: *std.Io.Writer) !void {
        try self.ensureTransactionClosed();
        return self.doc.dump(gpa, writer);
    }

    /// Parses a durable object identifier; any actor bytes in the result borrow this owner.
    pub fn importObj(self: *const AutoCommit, gpa: Allocator, string: []const u8) !ExId {
        return self.doc.importObj(gpa, string);
    }

    /// Parses and validates an object identifier plus its live object type without closing.
    pub fn import(self: *const AutoCommit, gpa: Allocator, string: []const u8) !docmod.ImportedObject {
        return self.doc.import(gpa, string);
    }
};

test "AutoCommit holds writes and ordinary reads without publishing history" {
    // A consumer sees pending writes, but only an explicit barrier publishes a change.
    const gpa = std.testing.allocator;
    var owner = try @This().AutoCommit.init(gpa, std.testing.io);
    defer owner.deinit();
    _ = try owner.put(.root, .{ .key = "first" }, .{ .int = 1 });
    _ = try owner.put(.root, .{ .key = "second" }, .{ .int = 2 });
    try std.testing.expectEqual(@as(usize, 2), owner.pendingOps());
    const found = (try owner.get(.root, .{ .key = "second" })).?;
    try std.testing.expectEqual(@as(i64, 2), found.value.scalar.int);
    try std.testing.expectEqual(@as(usize, 2), owner.pendingOps());
    try std.testing.expect((try owner.commit()) != null);
    try std.testing.expectEqual(@as(usize, 0), owner.pendingOps());
    var changes = try owner.getChanges(gpa, &.{});
    defer changes.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), changes.len());
    try std.testing.expect((try owner.commit()) == null);
}

test "AutoCommit pending clone can rollback independently without closing its source" {
    // Clone at a stable destination preserves both independent pending owners.
    const gpa = std.testing.allocator;
    var source = try @This().AutoCommit.init(gpa, std.testing.io);
    defer source.deinit();
    _ = try source.put(.root, .{ .key = "pending" }, .{ .int = 7 });
    var copy: @This().AutoCommit = undefined;
    try source.cloneInto(gpa, &copy);
    defer copy.deinit();
    try std.testing.expectEqual(@as(usize, 1), source.pendingOps());
    try std.testing.expectEqual(@as(usize, 1), copy.pendingOps());
    try std.testing.expectEqual(@as(usize, 1), try copy.rollback());
    try std.testing.expect((try copy.get(.root, .{ .key = "pending" })) == null);
    try std.testing.expectEqual(@as(usize, 1), source.pendingOps());
    try std.testing.expect((try source.commit()) != null);
    const found = (try source.get(.root, .{ .key = "pending" })).?;
    try std.testing.expectEqual(@as(i64, 7), found.value.scalar.int);
}

test "AutoCommit isolated heads differ from full graph sync acknowledgement" {
    // Isolation affects public heads, not whether a peer has the full committed graph.
    const State = @import("sync/state.zig").State;
    const gpa = std.testing.allocator;
    var owner = try @This().AutoCommit.init(gpa, std.testing.io);
    defer owner.deinit();
    _ = try owner.put(.root, .{ .key = "value" }, .{ .int = 1 });
    const old_heads = try owner.getHeads(gpa);
    defer gpa.free(old_heads);
    _ = try owner.put(.root, .{ .key = "value" }, .{ .int = 2 });
    const full_heads = try owner.getHeads(gpa);
    defer gpa.free(full_heads);
    try owner.isolate(gpa, old_heads);
    const visible_heads = try owner.getHeads(gpa);
    defer gpa.free(visible_heads);
    try std.testing.expectEqualSlices(@import("types.zig").ChangeHash, old_heads, visible_heads);
    var state = State.new(gpa);
    defer state.deinit();
    state.shared_heads = try gpa.dupe(@import("types.zig").ChangeHash, full_heads);
    try std.testing.expect(try owner.hasOurChanges(&state));
}

test "AutoCommit cached diff owns keys and returns independent patch batches" {
    // Releasing both input hashes and one result must not invalidate a repeated diff.
    const gpa = std.testing.allocator;
    var owner = try @This().AutoCommit.init(gpa, std.testing.io);
    defer owner.deinit();
    _ = try owner.put(.root, .{ .key = "value" }, .{ .int = 1 });
    const heads = try owner.getHeads(gpa);
    const hash = heads[0];
    var first = try owner.diff(gpa, &.{}, heads);
    gpa.free(heads);
    try std.testing.expectEqual(@as(usize, 1), first.len());
    first.deinit();
    var second = try owner.diff(gpa, &.{}, &.{hash});
    defer second.deinit();
    try std.testing.expectEqual(@as(usize, 1), second.len());
    var reverse = try owner.diff(gpa, &.{hash}, &.{});
    defer reverse.deinit();
    try std.testing.expectEqual(@as(usize, 1), reverse.len());
    try std.testing.expectEqual(@as(usize, 1), second.len());
}

test "AutoCommit empty change publishes pending work as a distinct earlier change" {
    // Empty commit is not an empty change, and emptyChange is a close barrier first.
    const gpa = std.testing.allocator;
    var owner = try @This().AutoCommit.init(gpa, std.testing.io);
    defer owner.deinit();
    try std.testing.expect((try owner.commit()) == null);
    _ = try owner.put(.root, .{ .key = "pending" }, .{ .int = 1 });
    _ = try owner.emptyChange(.{});
    var changes = try owner.getChanges(gpa, &.{});
    defer changes.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), changes.len());
    try std.testing.expectEqual(@as(usize, 0), owner.pendingOps());
}

test "AutoCommit actor setter closes pending work before changing identity" {
    // A pending change belongs to the identity in force when its writes began.
    const gpa = std.testing.allocator;
    var owner = try @This().AutoCommit.init(gpa, std.testing.io);
    defer owner.deinit();
    try owner.setActorId(.{ .bytes = "old actor" });
    _ = try owner.put(.root, .{ .key = "first" }, .{ .int = 1 });
    try owner.setActorId(.{ .bytes = "new actor" });
    try std.testing.expectEqual(@as(usize, 0), owner.pendingOps());
    var changes = try owner.getChanges(gpa, &.{});
    defer changes.deinit(gpa);
    try std.testing.expectEqualStrings("old actor", changes.at(0).actor.bytes);
    _ = try owner.put(.root, .{ .key = "second" }, .{ .int = 2 });
    const bytes = try owner.saveAndVerify(gpa);
    defer gpa.free(bytes);
    try std.testing.expectEqual(@as(usize, 0), owner.pendingOps());
}

test "AutoCommit explicit historical reads exclude pending operations at committed heads" {
    // Matching graph heads must not shortcut a historical read to pending rows.
    const gpa = std.testing.allocator;
    var owner = try @This().AutoCommit.init(gpa, std.testing.io);
    defer owner.deinit();
    _ = try owner.put(.root, .{ .key = "value" }, .{ .int = 1 });
    const heads = try owner.getHeads(gpa);
    defer gpa.free(heads);
    _ = try owner.put(.root, .{ .key = "value" }, .{ .int = 2 });
    const historical = (try owner.getAt(.root, .{ .key = "value" }, heads)).?;
    try std.testing.expectEqual(@as(i64, 1), historical.value.scalar.int);
    const present = (try owner.get(.root, .{ .key = "value" })).?;
    try std.testing.expectEqual(@as(i64, 2), present.value.scalar.int);
    try std.testing.expectEqual(@as(usize, 1), owner.pendingOps());
}

test "AutoCommit incremental patches include one held change and advance the cursor" {
    // Logged local writes become independent patches at the diff barrier.
    const gpa = std.testing.allocator;
    var owner = try @This().AutoCommit.init(gpa, std.testing.io);
    defer owner.deinit();
    _ = try owner.put(.root, .{ .key = "before" }, .{ .int = 1 });
    try owner.updateDiffCursor();
    _ = try owner.put(.root, .{ .key = "after" }, .{ .int = 2 });
    var patches = try owner.diffIncremental(gpa);
    defer patches.deinit();
    try std.testing.expectEqual(@as(usize, 1), patches.len());
    try std.testing.expectEqual(@as(usize, 0), owner.pendingOps());
    var empty = try owner.diffIncremental(gpa);
    defer empty.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty.len());
}

test "AutoCommit sync generation closes pending work before advertising heads" {
    // Sync uses the same commit owner as explicit history and save barriers.
    const State = @import("sync/state.zig").State;
    const gpa = std.testing.allocator;
    var owner = try @This().AutoCommit.init(gpa, std.testing.io);
    defer owner.deinit();
    var state = State.new(gpa);
    defer state.deinit();
    _ = try owner.put(.root, .{ .key = "pending" }, .{ .int = 1 });
    var message = (try owner.generateSyncMessage(gpa, &state)).?;
    defer message.deinit();
    try std.testing.expectEqual(@as(usize, 0), owner.pendingOps());
    const heads = try owner.getHeads(gpa);
    defer gpa.free(heads);
    try std.testing.expectEqualSlices(@import("types.zig").ChangeHash, heads, message.heads);
}

test "AutoCommit commit allocation refusal retains the pending owner for retry" {
    // Observe each refused commit on the same owner before retrying with memory restored.
    const gpa = std.testing.allocator;
    var saw_refusal = false;
    var completed = false;
    for (0..4096) |offset| {
        var failing = std.testing.FailingAllocator.init(gpa, .{});
        var owner = try @This().AutoCommit.init(failing.allocator(), std.testing.io);
        defer owner.deinit();
        _ = try owner.put(.root, .{ .key = "pending" }, .{ .int = 42 });
        failing.fail_index = failing.alloc_index + offset;
        const hash = owner.commit() catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            saw_refusal = true;
            failing.fail_index = std.math.maxInt(usize);
            try std.testing.expectEqual(@as(usize, 1), owner.pendingOps());
            const present = (try owner.get(.root, .{ .key = "pending" })).?;
            try std.testing.expectEqual(@as(i64, 42), present.value.scalar.int);
            try std.testing.expect((try owner.commit()) != null);
            try std.testing.expectEqual(@as(usize, 0), owner.pendingOps());
            var changes = try owner.getChanges(gpa, &.{});
            defer changes.deinit(gpa);
            try std.testing.expectEqual(@as(usize, 1), changes.len());
            continue;
        };
        try std.testing.expect(hash != null);
        completed = true;
        break;
    }
    try std.testing.expect(saw_refusal);
    try std.testing.expect(completed);
}

test "AutoCommit pending clone allocation refusal leaves source readable and open" {
    // A failed clone initializes no destination owner and cannot close the source.
    const gpa = std.testing.allocator;
    var source = try @This().AutoCommit.init(gpa, std.testing.io);
    defer source.deinit();
    _ = try source.put(.root, .{ .key = "pending" }, .{ .int = 42 });
    var completed = false;
    for (0..4096) |offset| {
        var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = offset });
        var copy: @This().AutoCommit = undefined;
        source.cloneInto(failing.allocator(), &copy) catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expectEqual(@as(usize, 1), source.pendingOps());
            const present = (try source.get(.root, .{ .key = "pending" })).?;
            try std.testing.expectEqual(@as(i64, 42), present.value.scalar.int);
            continue;
        };
        copy.deinit();
        completed = true;
        break;
    }
    try std.testing.expect(completed);
    try std.testing.expectEqual(@as(usize, 1), source.pendingOps());
    try std.testing.expectEqual(@as(usize, 1), try source.rollback());
}

test "AutoCommit producer allocation refusal retains earlier pending writes and primary error" {
    // A refused producer must not hide OutOfMemory behind a fallible automatic rollback.
    const gpa = std.testing.allocator;
    var completed = false;
    for (0..4096) |offset| {
        var failing = std.testing.FailingAllocator.init(gpa, .{});
        var owner = try @This().AutoCommit.init(failing.allocator(), std.testing.io);
        defer owner.deinit();
        _ = try owner.put(.root, .{ .key = "earlier" }, .{ .int = 1 });
        failing.fail_index = failing.alloc_index + offset;
        _ = owner.put(.root, .{ .key = "later" }, .{ .str = "owned pending string" }) catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            failing.fail_index = std.math.maxInt(usize);
            const earlier = (try owner.get(.root, .{ .key = "earlier" })).?;
            try std.testing.expectEqual(@as(i64, 1), earlier.value.scalar.int);
            try std.testing.expect(owner.pendingOps() >= 1);
            _ = try owner.rollback();
            try std.testing.expect((try owner.get(.root, .{ .key = "earlier" })) == null);
            continue;
        };
        completed = true;
        break;
    }
    try std.testing.expect(completed);
}

test "AutoCommit rollback allocation refusal retains the sole owner for continued cancellation" {
    // Cancellation may make progress, but refusal never loses the journal needed to finish it.
    const gpa = std.testing.allocator;
    var completed = false;
    for (0..4096) |offset| {
        var failing = std.testing.FailingAllocator.init(gpa, .{});
        var owner = try @This().AutoCommit.init(failing.allocator(), std.testing.io);
        defer owner.deinit();
        _ = try owner.put(.root, .{ .key = "first" }, .{ .int = 1 });
        _ = try owner.put(.root, .{ .key = "second" }, .{ .int = 2 });
        failing.fail_index = failing.alloc_index + offset;
        const cancelled = owner.rollback() catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            failing.fail_index = std.math.maxInt(usize);
            _ = try owner.rollback();
            try std.testing.expectEqual(@as(usize, 0), owner.pendingOps());
            try std.testing.expect((try owner.get(.root, .{ .key = "first" })) == null);
            try std.testing.expect((try owner.get(.root, .{ .key = "second" })) == null);
            continue;
        };
        try std.testing.expectEqual(@as(usize, 2), cancelled);
        completed = true;
        break;
    }
    try std.testing.expect(completed);
}

test "AutoCommit cached object diffs distinguish durable object identities" {
    const gpa = std.testing.allocator;
    var owner = try AutoCommit.init(gpa, std.testing.io);
    defer owner.deinit();
    const left = try owner.putObject(.root, .{ .key = "left" }, .map);
    const right = try owner.putObject(.root, .{ .key = "right" }, .map);
    _ = try owner.put(left, .{ .key = "one" }, .{ .int = 1 });
    _ = try owner.put(right, .{ .key = "two" }, .{ .int = 2 });
    _ = try owner.put(right, .{ .key = "three" }, .{ .int = 3 });
    const heads = try owner.getHeads(gpa);
    defer gpa.free(heads);
    var one = try owner.diffObj(gpa, left, &.{}, heads, false);
    defer one.deinit();
    var two = try owner.diffObj(gpa, right, &.{}, heads, false);
    defer two.deinit();
    try std.testing.expectEqual(@as(usize, 1), one.len());
    try std.testing.expectEqual(@as(usize, 2), two.len());
    var one_again = try owner.diffObj(gpa, left, &.{}, heads, false);
    defer one_again.deinit();
    try std.testing.expectEqual(@as(usize, 1), one_again.len());
}

test "AutoCommit diff cache allocation refusal preserves the previous independent batch" {
    const gpa = std.testing.allocator;
    var failing = std.testing.FailingAllocator.init(gpa, .{});
    var owner = try AutoCommit.init(failing.allocator(), std.testing.io);
    defer owner.deinit();
    _ = try owner.put(.root, .{ .key = "value" }, .{ .int = 1 });
    const before = try owner.getHeads(gpa);
    defer gpa.free(before);
    _ = try owner.put(.root, .{ .key = "value" }, .{ .int = 2 });
    const after = try owner.getHeads(gpa);
    defer gpa.free(after);
    var cached = try owner.diff(gpa, &.{}, after);
    defer cached.deinit();
    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(error.OutOfMemory, owner.diff(gpa, before, after));
    // A cache hit allocates only the independently returned caller-owned batch.
    var retained = try owner.diff(gpa, &.{}, after);
    defer retained.deinit();
    failing.fail_index = std.math.maxInt(usize);
    try std.testing.expectEqual(@as(usize, 1), retained.len());
    try std.testing.expectEqual(@as(usize, 1), cached.len());
}

test "AutoCommit fork resets isolation and cursors while clone preserves them independently" {
    const gpa = std.testing.allocator;
    var source = try AutoCommit.init(gpa, std.testing.io);
    defer source.deinit();
    _ = try source.put(.root, .{ .key = "value" }, .{ .int = 1 });
    const old_heads = try source.getHeads(gpa);
    defer gpa.free(old_heads);
    _ = try source.put(.root, .{ .key = "value" }, .{ .int = 2 });
    const full_heads = try source.getHeads(gpa);
    defer gpa.free(full_heads);
    try source.isolate(gpa, old_heads);
    try source.updateDiffCursor();
    const saved = try source.saveIncremental(gpa);
    defer gpa.free(saved);
    var copy: AutoCommit = undefined;
    try source.cloneInto(gpa, &copy);
    defer copy.deinit();
    const clone_heads = try copy.getHeads(gpa);
    defer gpa.free(clone_heads);
    try std.testing.expectEqualSlices(ChangeHash, old_heads, clone_heads);
    const clone_cursor = try copy.diffCursor(gpa);
    defer gpa.free(clone_cursor);
    try std.testing.expectEqualSlices(ChangeHash, old_heads, clone_cursor);
    var forked = try source.fork(gpa);
    defer forked.deinit();
    const fork_heads = try forked.getHeads(gpa);
    defer gpa.free(fork_heads);
    try std.testing.expectEqualSlices(ChangeHash, full_heads, fork_heads);
    const fork_cursor = try forked.diffCursor(gpa);
    defer gpa.free(fork_cursor);
    try std.testing.expectEqual(@as(usize, 0), fork_cursor.len);
    const fork_save = try forked.saveIncremental(gpa);
    defer gpa.free(fork_save);
    try std.testing.expect(fork_save.len != 0);
    try copy.integrate();
    const still_isolated = try source.getHeads(gpa);
    defer gpa.free(still_isolated);
    try std.testing.expectEqualSlices(ChangeHash, old_heads, still_isolated);
}

test "AutoCommit isolated commit advances only the isolated heads and preserves full graph history" {
    const gpa = std.testing.allocator;
    var owner = try AutoCommit.init(gpa, std.testing.io);
    defer owner.deinit();
    _ = try owner.put(.root, .{ .key = "first" }, .{ .int = 1 });
    const first = try owner.getHeads(gpa);
    defer gpa.free(first);
    _ = try owner.put(.root, .{ .key = "later" }, .{ .int = 2 });
    _ = try owner.commit();
    try owner.isolate(gpa, first);
    _ = try owner.put(.root, .{ .key = "branch" }, .{ .int = 3 });
    const branch = (try owner.commit()).?;
    const visible = try owner.getHeads(gpa);
    defer gpa.free(visible);
    try std.testing.expectEqualSlices(ChangeHash, &.{branch}, visible);
    try std.testing.expect((try owner.get(.root, .{ .key = "later" })) == null);
    try owner.integrate();
    try std.testing.expect((try owner.get(.root, .{ .key = "later" })) != null);
    try std.testing.expect((try owner.get(.root, .{ .key = "branch" })) != null);
}

test "AutoCommit integrate refuses without losing the pending isolated owner" {
    const gpa = std.testing.allocator;
    var failing = std.testing.FailingAllocator.init(gpa, .{});
    var owner = try AutoCommit.init(failing.allocator(), std.testing.io);
    defer owner.deinit();
    _ = try owner.put(.root, .{ .key = "old" }, .{ .int = 1 });
    const old_heads = try owner.getHeads(gpa);
    defer gpa.free(old_heads);
    _ = try owner.put(.root, .{ .key = "new" }, .{ .int = 2 });
    _ = try owner.commit();
    try owner.isolate(failing.allocator(), old_heads);
    _ = try owner.put(.root, .{ .key = "branch" }, .{ .int = 3 });
    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(error.OutOfMemory, owner.integrate());
    failing.fail_index = std.math.maxInt(usize);
    try std.testing.expectEqual(@as(usize, 1), owner.pendingOps());
    try std.testing.expect((try owner.get(.root, .{ .key = "new" })) == null);
    try std.testing.expect((try owner.get(.root, .{ .key = "branch" })) != null);
    try owner.integrate();
    try std.testing.expectEqual(@as(usize, 0), owner.pendingOps());
    try std.testing.expect((try owner.get(.root, .{ .key = "new" })) != null);
    try std.testing.expect((try owner.get(.root, .{ .key = "branch" })) != null);
}

test "AutoCommit cloned diff cache outlives the source and every returned batch" {
    const gpa = std.testing.allocator;
    var copied: AutoCommit = undefined;
    const hash = blk: {
        var source = try AutoCommit.init(gpa, std.testing.io);
        defer source.deinit();
        _ = try source.put(.root, .{ .key = "value" }, .{ .str = "owned" });
        const heads = try source.getHeads(gpa);
        defer gpa.free(heads);
        var initial = try source.diff(gpa, &.{}, heads);
        defer initial.deinit();
        try source.cloneInto(gpa, &copied);
        break :blk heads[0];
    };
    defer copied.deinit();
    var first = try copied.diff(gpa, &.{}, &.{hash});
    try std.testing.expectEqual(@as(usize, 1), first.len());
    first.deinit();
    var second = try copied.diff(gpa, &.{}, &.{hash});
    defer second.deinit();
    try std.testing.expectEqual(@as(usize, 1), second.len());
    const found = (try copied.get(.root, .{ .key = "value" })).?;
    try std.testing.expectEqualStrings("owned", found.value.scalar.str);
}

test "AutoCommit author setter publishes pending work under the previous author" {
    const gpa = std.testing.allocator;
    var owner = try AutoCommit.init(gpa, std.testing.io);
    defer owner.deinit();
    _ = try owner.put(.root, .{ .key = "before" }, .{ .int = 1 });
    try owner.setAuthor(gpa, "alice");
    try std.testing.expectEqual(@as(usize, 0), owner.pendingOps());
    _ = try owner.put(.root, .{ .key = "after" }, .{ .int = 2 });
    var changes = try owner.getChanges(gpa, &.{});
    defer changes.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), changes.len());
    try std.testing.expect((try changes.slice()[0].change.author(gpa)) == null);
    try std.testing.expectEqualStrings("alice", (try changes.slice()[1].change.author(gpa)).?);
}

test "AutoCommit borrowed compatible sync closes pending writes but ordinary reads do not" {
    // External sync uses the held engine's close barrier and keeps its own event sink.
    const gpa = std.testing.allocator;
    var source = try docmod.Document.init(gpa, std.testing.io);
    defer source.deinit();
    source.setActorId(.{ .bytes = "A" });
    var tx = try transact.Transaction.open(gpa, &source);
    defer tx.deinitClosed();
    _ = try tx.put(.root, .{ .key = "incoming" }, .{ .int = 2 });
    var committed = try tx.commit();
    defer committed.deinit(gpa);
    var log = committed.patch_log.take();
    defer log.deinit();
    const prefix = log.events.items.len;
    var owner = try AutoCommit.init(gpa, std.testing.io);
    defer owner.deinit();
    try owner.setActorId(.{ .bytes = "B" });
    owner.doc.patch_log.deinit();
    owner.doc.patch_log = patchesmod.PatchLog.active(gpa);
    _ = try owner.put(.root, .{ .key = "pending" }, .{ .int = 1 });
    try std.testing.expectEqual(@as(usize, 1), owner.pendingOps());
    const pending = (try owner.get(.root, .{ .key = "pending" })).?;
    try std.testing.expectEqual(@as(i64, 1), pending.value.scalar.int);
    try std.testing.expectEqual(@as(usize, 1), owner.pendingOps());
    try std.testing.expectEqual(@as(usize, 0), owner.doc.graph.len());
    var state = statemod.State.new(gpa);
    defer state.deinit();
    var message = messagemod.Message.init(gpa);
    errdefer message.deinit();
    message.heads = try source.getHeads(gpa);
    {
        var incoming = (try source.getLastLocalChange(gpa)).?;
        defer incoming.deinit(gpa);
        const encoded = try incoming.change.encode(gpa);
        errdefer gpa.free(encoded);
        message.changes.items = try gpa.alloc([]u8, 1);
        message.changes.items[0] = encoded;
    }
    const borrowed_sync = try owner.sync();
    const consumed = message;
    message = messagemod.Message.init(gpa);
    try borrowed_sync.receiveSyncMessageWithPatchLog(gpa, &state, consumed, &log);
    try std.testing.expectEqual(@as(usize, 0), owner.pendingOps());
    try std.testing.expectEqual(@as(usize, 2), owner.doc.graph.len());
    try std.testing.expectEqual(@as(i64, 2), (try owner.get(.root, .{ .key = "incoming" })).?.value.scalar.int);
    try std.testing.expect(log.events.items.len > prefix);
    var internal = try owner.doc.makePatches(&owner.doc.patch_log);
    defer internal.deinit();
    try std.testing.expectEqual(@as(usize, 1), internal.items.items.len);
    try std.testing.expectEqualStrings("pending", internal.items.items[0].action.put_map.key);
    var external = try owner.doc.makePatches(&log);
    defer external.deinit();
    try std.testing.expect(external.items.items.len != 0);
    for (external.items.items) |patch| {
        try std.testing.expectEqualStrings("incoming", patch.action.put_map.key);
    }
}
