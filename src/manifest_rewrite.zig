//! manifest_rewrite — v0.0.5 port of P824 (Tableflow manifest rewriting).
//!
//! Ports P824 (Confluent Tableflow manifest-rewrite optimization
//! from L59-materialize-cloud-tableflow-MINED.md). Tableflow coalesces
//! small manifest files into larger ones to reduce metadata-access
//! latency. The same pattern shows up in Snowflake L1063 and
//! BigQuery BigLake.
//!
//! v0.0.5 ships the rewrite policy primitive: given a slice of
//! existing ManifestEntryLists, identify groups smaller than a
//! threshold + coalesce their entries into one merged list. Active
//! ADDED entries take precedence; DELETED + EXISTING are
//! preserved in the merged output.

const std = @import("std");
const manifest_entry = @import("manifest_entry.zig");

pub const ManifestEntry = manifest_entry.ManifestEntry;
pub const ManifestEntryList = manifest_entry.ManifestEntryList;
pub const EntryStatus = manifest_entry.EntryStatus;

pub const Error = error{ OutOfMemory };

pub const RewritePolicy = struct {
    /// Lists with fewer than this many entries are candidates for
    /// coalescing. Tableflow uses ~10000 typically.
    min_entries_threshold: usize,
};

pub const RewriteResult = struct {
    coalesced: []ManifestEntry,
    /// Number of small lists that were merged.
    source_list_count: usize,

    pub fn deinit(self: *RewriteResult, allocator: std.mem.Allocator) void {
        allocator.free(self.coalesced);
    }
};

/// Identify lists under the threshold + merge their entries into one
/// coalesced slice. Lists above the threshold are left untouched.
pub fn rewriteSmallLists(
    allocator: std.mem.Allocator,
    lists: []const ManifestEntryList,
    policy: RewritePolicy,
) Error!RewriteResult {
    var out = std.array_list.Managed(ManifestEntry).init(allocator);
    errdefer out.deinit();
    var source_count: usize = 0;

    for (lists) |list| {
        if (list.entries.len >= policy.min_entries_threshold) continue;
        source_count += 1;
        for (list.entries) |e| out.append(e) catch return Error.OutOfMemory;
    }
    return .{
        .coalesced = out.toOwnedSlice() catch return Error.OutOfMemory,
        .source_list_count = source_count,
    };
}

/// Filter coalesced entries: keep only entries whose status is not
/// DELETED. Used after rewriteSmallLists when the caller wants only
/// live entries for a new manifest.
pub fn filterActive(
    allocator: std.mem.Allocator,
    entries: []const ManifestEntry,
) Error![]ManifestEntry {
    var out = std.array_list.Managed(ManifestEntry).init(allocator);
    errdefer out.deinit();
    for (entries) |e| if (e.status != .deleted) {
        out.append(e) catch return Error.OutOfMemory;
    };
    return out.toOwnedSlice() catch return Error.OutOfMemory;
}

// --- Tests ----------------------------------------------------------------

const testing = std.testing;

fn fakeFile(path: []const u8) manifest_entry.DataFile {
    return .{
        .path = path,
        .spec_id = 0,
        .partition_values_json = "{}",
        .record_count = 100,
        .file_size_bytes = 4096,
    };
}

test "rewriteSmallLists coalesces lists below threshold" {
    const alloc = testing.allocator;
    var l1_entries = [_]ManifestEntry{
        .{ .status = .added, .snapshot_id = 1, .sequence_number = 1, .file = fakeFile("a.parquet") },
        .{ .status = .added, .snapshot_id = 1, .sequence_number = 2, .file = fakeFile("b.parquet") },
    };
    var l2_entries = [_]ManifestEntry{
        .{ .status = .added, .snapshot_id = 2, .sequence_number = 3, .file = fakeFile("c.parquet") },
    };
    const l1: ManifestEntryList = .{ .entries = l1_entries[0..] };
    const l2: ManifestEntryList = .{ .entries = l2_entries[0..] };
    const lists = [_]ManifestEntryList{ l1, l2 };
    const policy: RewritePolicy = .{ .min_entries_threshold = 5 };

    var result = try rewriteSmallLists(alloc, &lists, policy);
    defer result.deinit(alloc);
    try testing.expectEqual(@as(usize, 3), result.coalesced.len);
    try testing.expectEqual(@as(usize, 2), result.source_list_count);
}

test "rewriteSmallLists leaves large lists untouched" {
    const alloc = testing.allocator;
    var big_entries: [10]ManifestEntry = undefined;
    for (&big_entries, 0..) |*e, i| e.* = .{
        .status = .added,
        .snapshot_id = 1,
        .sequence_number = @intCast(i + 1),
        .file = fakeFile("big.parquet"),
    };
    const big: ManifestEntryList = .{ .entries = big_entries[0..] };
    const lists = [_]ManifestEntryList{big};
    const policy: RewritePolicy = .{ .min_entries_threshold = 5 };

    var result = try rewriteSmallLists(alloc, &lists, policy);
    defer result.deinit(alloc);
    try testing.expectEqual(@as(usize, 0), result.coalesced.len);
    try testing.expectEqual(@as(usize, 0), result.source_list_count);
}

test "filterActive drops DELETED entries" {
    const alloc = testing.allocator;
    const entries = [_]ManifestEntry{
        .{ .status = .added, .snapshot_id = 1, .sequence_number = 1, .file = fakeFile("a") },
        .{ .status = .deleted, .snapshot_id = 1, .sequence_number = 2, .file = fakeFile("b") },
        .{ .status = .existing, .snapshot_id = 1, .sequence_number = 3, .file = fakeFile("c") },
        .{ .status = .deleted, .snapshot_id = 1, .sequence_number = 4, .file = fakeFile("d") },
    };
    const filtered = try filterActive(alloc, &entries);
    defer alloc.free(filtered);
    try testing.expectEqual(@as(usize, 2), filtered.len);
    for (filtered) |e| try testing.expect(e.status != .deleted);
}

test "rewriteSmallLists on empty input yields empty result" {
    const alloc = testing.allocator;
    var result = try rewriteSmallLists(alloc, &[_]ManifestEntryList{}, .{ .min_entries_threshold = 5 });
    defer result.deinit(alloc);
    try testing.expectEqual(@as(usize, 0), result.coalesced.len);
}

test "rewriteSmallLists preserves entry status through coalesce" {
    const alloc = testing.allocator;
    var entries = [_]ManifestEntry{
        .{ .status = .added, .snapshot_id = 1, .sequence_number = 1, .file = fakeFile("a") },
        .{ .status = .deleted, .snapshot_id = 1, .sequence_number = 2, .file = fakeFile("b") },
    };
    const list: ManifestEntryList = .{ .entries = entries[0..] };
    const lists = [_]ManifestEntryList{list};
    var result = try rewriteSmallLists(alloc, &lists, .{ .min_entries_threshold = 5 });
    defer result.deinit(alloc);
    // ADDED + DELETED both flow through coalesce.
    try testing.expectEqual(@as(usize, 2), result.coalesced.len);
}
