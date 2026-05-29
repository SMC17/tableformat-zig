//! manifest_entry — v0.0.3 Iceberg V2 manifest-entry generation primitive.
//!
//! Iceberg V2 splits a manifest list (catalog of manifest files) from
//! per-manifest "manifest entries" (the actual list of DataFiles in
//! that manifest). v0.0.1 ships a single self-describing Manifest
//! that bundles everything; v0.0.3 adds the entry primitive so a
//! large table can keep many manifest files each holding ≤ N entries,
//! matching real Iceberg sizing patterns.
//!
//! A `ManifestEntry` wraps a DataFile with V2's status enum (ADDED /
//! EXISTING / DELETED) + sequence number + snapshot id. The sequence
//! number is monotonic across the table — used by the V2 reader to
//! merge multiple manifest entries into the snapshot view.

const std = @import("std");
const spec = @import("spec.zig");

pub const DataFile = spec.DataFile;

/// Iceberg V2 manifest-entry status.
pub const EntryStatus = enum(u8) {
    added = 1,
    existing = 0,
    deleted = 2,
};

pub const ManifestEntry = struct {
    status: EntryStatus,
    /// Snapshot at which this entry was added; for `existing` entries
    /// this is the snapshot of the original ADD.
    snapshot_id: u64,
    /// Monotonic per-table sequence number; v2 readers use this for
    /// delete-merge ordering.
    sequence_number: u64,
    file: DataFile,
};

pub const Error = error{
    OutOfMemory,
    EntryNotFound,
};

/// A bounded manifest-entry list — typically one per physical
/// manifest file. Caller owns the entries slice.
pub const ManifestEntryList = struct {
    entries: []ManifestEntry,

    pub fn deinit(self: *ManifestEntryList, allocator: std.mem.Allocator) void {
        allocator.free(self.entries);
    }

    pub fn count(self: ManifestEntryList) usize {
        return self.entries.len;
    }

    pub fn countActive(self: ManifestEntryList) usize {
        var n: usize = 0;
        for (self.entries) |e| if (e.status != .deleted) {
            n += 1;
        };
        return n;
    }

    pub fn findBySnapshot(self: ManifestEntryList, snapshot_id: u64) ?ManifestEntry {
        for (self.entries) |e| if (e.snapshot_id == snapshot_id) return e;
        return null;
    }
};

/// Build a ManifestEntryList from a slice of DataFiles. All entries
/// start with status=ADDED and the supplied snapshot_id + base
/// sequence number; subsequent entries get base + i.
pub fn entriesFromDataFiles(
    allocator: std.mem.Allocator,
    files: []const DataFile,
    snapshot_id: u64,
    base_sequence: u64,
) Error!ManifestEntryList {
    const entries = allocator.alloc(ManifestEntry, files.len) catch return Error.OutOfMemory;
    for (files, 0..) |f, i| entries[i] = .{
        .status = .added,
        .snapshot_id = snapshot_id,
        .sequence_number = base_sequence + i,
        .file = f,
    };
    return .{ .entries = entries };
}

/// Mark an existing entry as DELETED. Returns Error.EntryNotFound if
/// the entry isn't found by `file_path` match.
pub fn markDeleted(list: *ManifestEntryList, file_path: []const u8) Error!void {
    for (list.entries) |*e| {
        if (std.mem.eql(u8, e.file.path, file_path)) {
            e.status = .deleted;
            return;
        }
    }
    return Error.EntryNotFound;
}

// --- Tests ----------------------------------------------------------------

const testing = std.testing;

fn fakeFile(path: []const u8, spec_id: u32) DataFile {
    return .{
        .path = path,
        .spec_id = spec_id,
        .partition_values_json = "{}",
        .record_count = 100,
        .file_size_bytes = 4096,
    };
}

test "entriesFromDataFiles creates one ADDED entry per file" {
    const alloc = testing.allocator;
    const files = [_]DataFile{
        fakeFile("a.parquet", 0),
        fakeFile("b.parquet", 0),
        fakeFile("c.parquet", 1),
    };
    var list = try entriesFromDataFiles(alloc, &files, 42, 100);
    defer list.deinit(alloc);
    try testing.expectEqual(@as(usize, 3), list.count());
    for (list.entries) |e| try testing.expectEqual(EntryStatus.added, e.status);
}

test "entriesFromDataFiles assigns monotonic sequence numbers from base" {
    const alloc = testing.allocator;
    const files = [_]DataFile{
        fakeFile("a.parquet", 0),
        fakeFile("b.parquet", 0),
        fakeFile("c.parquet", 0),
    };
    var list = try entriesFromDataFiles(alloc, &files, 7, 1000);
    defer list.deinit(alloc);
    try testing.expectEqual(@as(u64, 1000), list.entries[0].sequence_number);
    try testing.expectEqual(@as(u64, 1001), list.entries[1].sequence_number);
    try testing.expectEqual(@as(u64, 1002), list.entries[2].sequence_number);
}

test "markDeleted flips status to DELETED" {
    const alloc = testing.allocator;
    const files = [_]DataFile{
        fakeFile("a.parquet", 0),
        fakeFile("b.parquet", 0),
    };
    var list = try entriesFromDataFiles(alloc, &files, 1, 0);
    defer list.deinit(alloc);
    try markDeleted(&list, "b.parquet");
    try testing.expectEqual(EntryStatus.deleted, list.entries[1].status);
    try testing.expectEqual(EntryStatus.added, list.entries[0].status);
}

test "markDeleted on missing path returns EntryNotFound" {
    const alloc = testing.allocator;
    const files = [_]DataFile{fakeFile("a.parquet", 0)};
    var list = try entriesFromDataFiles(alloc, &files, 1, 0);
    defer list.deinit(alloc);
    try testing.expectError(Error.EntryNotFound, markDeleted(&list, "z.parquet"));
}

test "countActive excludes DELETED entries" {
    const alloc = testing.allocator;
    const files = [_]DataFile{
        fakeFile("a.parquet", 0),
        fakeFile("b.parquet", 0),
        fakeFile("c.parquet", 0),
    };
    var list = try entriesFromDataFiles(alloc, &files, 1, 0);
    defer list.deinit(alloc);
    try testing.expectEqual(@as(usize, 3), list.countActive());
    try markDeleted(&list, "b.parquet");
    try testing.expectEqual(@as(usize, 2), list.countActive());
}

test "findBySnapshot returns the entry at the given snapshot" {
    const alloc = testing.allocator;
    const files = [_]DataFile{
        fakeFile("a.parquet", 0),
        fakeFile("b.parquet", 0),
    };
    var list = try entriesFromDataFiles(alloc, &files, 99, 0);
    defer list.deinit(alloc);
    const found = list.findBySnapshot(99);
    try testing.expect(found != null);
}

test "findBySnapshot returns null on unknown snapshot" {
    const alloc = testing.allocator;
    const files = [_]DataFile{fakeFile("a.parquet", 0)};
    var list = try entriesFromDataFiles(alloc, &files, 1, 0);
    defer list.deinit(alloc);
    try testing.expectEqual(@as(?ManifestEntry, null), list.findBySnapshot(999));
}
