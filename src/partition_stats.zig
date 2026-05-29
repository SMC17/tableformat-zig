//! partition_stats — v0.0.4 per-file column stats + zone-map pruning.
//!
//! Iceberg V2/V3, Delta v3, and Hudi 1.0 all carry per-DataFile column
//! statistics: min, max, null_count, distinct_count_est. Readers use
//! these for "zone-map pruning" — skip files whose [min, max] range
//! does not overlap the query predicate.
//!
//! v0.0.4 ships:
//!   - `ColumnStats`: per-column (column_id, min_value, max_value,
//!     null_count). Values are bytes — type-aware comparison is
//!     caller-supplied (matches Iceberg's typed-stats handling).
//!   - `FileStats`: bundles ColumnStats for a DataFile.
//!   - `pruneFileByRange`: classic zone-map pruning predicate.

const std = @import("std");

pub const ColumnStats = struct {
    column_id: u32,
    min_value: []const u8,
    max_value: []const u8,
    null_count: u64,
    distinct_count_est: u64 = 0,
};

pub const FileStats = struct {
    columns: []const ColumnStats,

    pub fn statsFor(self: FileStats, column_id: u32) ?ColumnStats {
        for (self.columns) |c| if (c.column_id == column_id) return c;
        return null;
    }
};

/// Predicate-range comparison result.
pub const RangeOverlap = enum {
    overlap_possible,
    no_overlap,
    contained,
};

/// Compare a query's [pred_lo, pred_hi] against the file's [min, max].
/// Returns:
///   - no_overlap: file can be skipped (zone-map prune wins)
///   - overlap_possible: must scan
///   - contained: every row in the file is in the predicate range
///
/// Comparison is bytewise lexicographic — caller is responsible for
/// supplying values in canonical bytewise sort order (e.g. big-endian
/// fixed-width ints, sortable UTF-8).
pub fn pruneFileByRange(
    file: FileStats,
    column_id: u32,
    pred_lo: []const u8,
    pred_hi: []const u8,
) RangeOverlap {
    const cs = file.statsFor(column_id) orelse return .overlap_possible;
    // pred_hi < file.min OR pred_lo > file.max → no overlap
    if (std.mem.order(u8, pred_hi, cs.min_value) == .lt) return .no_overlap;
    if (std.mem.order(u8, pred_lo, cs.max_value) == .gt) return .no_overlap;
    // pred_lo ≤ file.min AND pred_hi ≥ file.max → contained
    if (std.mem.order(u8, pred_lo, cs.min_value) != .gt and
        std.mem.order(u8, pred_hi, cs.max_value) != .lt) return .contained;
    return .overlap_possible;
}

/// Predicate-equality pruning: file can be skipped if pred_value is
/// outside [min, max].
pub fn pruneFileByEquality(file: FileStats, column_id: u32, pred_value: []const u8) RangeOverlap {
    const cs = file.statsFor(column_id) orelse return .overlap_possible;
    if (std.mem.order(u8, pred_value, cs.min_value) == .lt) return .no_overlap;
    if (std.mem.order(u8, pred_value, cs.max_value) == .gt) return .no_overlap;
    return .overlap_possible;
}

// --- Tests ----------------------------------------------------------------

const testing = std.testing;

fn mkStats(col_id: u32, lo: []const u8, hi: []const u8) ColumnStats {
    return .{
        .column_id = col_id,
        .min_value = lo,
        .max_value = hi,
        .null_count = 0,
        .distinct_count_est = 0,
    };
}

test "statsFor returns the matching column" {
    const cols = [_]ColumnStats{
        mkStats(1, "a", "z"),
        mkStats(2, "1", "9"),
    };
    const fs: FileStats = .{ .columns = &cols };
    const got = fs.statsFor(1).?;
    try testing.expectEqual(@as(u32, 1), got.column_id);
}

test "statsFor returns null for unknown column" {
    const cols = [_]ColumnStats{mkStats(1, "a", "z")};
    const fs: FileStats = .{ .columns = &cols };
    try testing.expectEqual(@as(?ColumnStats, null), fs.statsFor(99));
}

test "pruneFileByRange returns no_overlap when predicate is below min" {
    const cols = [_]ColumnStats{mkStats(1, "m", "p")};
    const fs: FileStats = .{ .columns = &cols };
    const result = pruneFileByRange(fs, 1, "a", "b");
    try testing.expectEqual(RangeOverlap.no_overlap, result);
}

test "pruneFileByRange returns no_overlap when predicate is above max" {
    const cols = [_]ColumnStats{mkStats(1, "m", "p")};
    const fs: FileStats = .{ .columns = &cols };
    const result = pruneFileByRange(fs, 1, "y", "z");
    try testing.expectEqual(RangeOverlap.no_overlap, result);
}

test "pruneFileByRange returns contained when predicate covers full range" {
    const cols = [_]ColumnStats{mkStats(1, "m", "p")};
    const fs: FileStats = .{ .columns = &cols };
    const result = pruneFileByRange(fs, 1, "a", "z");
    try testing.expectEqual(RangeOverlap.contained, result);
}

test "pruneFileByRange returns overlap_possible for partial overlap" {
    const cols = [_]ColumnStats{mkStats(1, "m", "p")};
    const fs: FileStats = .{ .columns = &cols };
    const result = pruneFileByRange(fs, 1, "n", "o");
    try testing.expectEqual(RangeOverlap.overlap_possible, result);
}

test "pruneFileByEquality skips file when value outside [min, max]" {
    const cols = [_]ColumnStats{mkStats(1, "m", "p")};
    const fs: FileStats = .{ .columns = &cols };
    try testing.expectEqual(RangeOverlap.no_overlap, pruneFileByEquality(fs, 1, "a"));
    try testing.expectEqual(RangeOverlap.no_overlap, pruneFileByEquality(fs, 1, "z"));
    try testing.expectEqual(RangeOverlap.overlap_possible, pruneFileByEquality(fs, 1, "n"));
}

test "pruneFileByRange on unknown column returns overlap_possible (conservative)" {
    const cols = [_]ColumnStats{mkStats(1, "m", "p")};
    const fs: FileStats = .{ .columns = &cols };
    try testing.expectEqual(RangeOverlap.overlap_possible, pruneFileByRange(fs, 99, "a", "z"));
}

test "pruneFileByRange with empty min/max + non-empty predicate prunes correctly" {
    const cols = [_]ColumnStats{mkStats(1, "", "")};
    const fs: FileStats = .{ .columns = &cols };
    // file min="" max="" → predicate "a".."z" is above, so prune.
    try testing.expectEqual(RangeOverlap.no_overlap, pruneFileByRange(fs, 1, "a", "z"));
}
