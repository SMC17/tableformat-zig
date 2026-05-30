//! column_histogram: v0.0.11 — fixed-width binned histogram.
//!
//! tableformat already tracks per-column min/max + null count via
//! partition_stats. Missing for query optimization: a binned
//! histogram that gives selectivity estimates (how many rows fall
//! in [lo, hi]?) cheaper than scanning. Standard equi-width with
//! caller-supplied bucket count.
//!
//! Useful across the castle: aqe-replanner cost-model
//! cardinality estimates, blackbird score-distribution
//! prefiltering, dq-zig DimensionScore distribution sketch,
//! liquid-cluster fleet pressure histograms.
//!
//! Scope of this revision:
//!   ColumnHistogram fixed-capacity with n_buckets, lo, hi,
//!     bucket counts.
//!   init(allocator, n_buckets, lo, hi) errors on n_buckets ==
//!     0 or lo >= hi.
//!   add(value) routes the sample into the correct bucket. Out-
//!     of-range values clamp to the first or last bucket.
//!   countInRange(lo, hi) returns the sum of bucket counts
//!     overlapping [lo, hi]; pessimistic (no per-bucket
//!     interpolation, returns the full overlapping bucket count).
//!   totalCount() returns the sum of all bucket counts.
//!
//! Out of scope: equi-depth histograms, multi-column joint
//! histograms, decay-weighted histograms (caller composes via a
//! sliding window + periodic reset).

const std = @import("std");

pub const Error = error{
    OutOfMemory,
    InvalidBucketCount,
    InvalidRange,
};

pub const ColumnHistogram = struct {
    allocator: std.mem.Allocator,
    n_buckets: usize,
    lo: f64,
    hi: f64,
    bucket_width: f64,
    counts: []u64,

    pub fn init(allocator: std.mem.Allocator, n_buckets: usize, lo: f64, hi: f64) Error!ColumnHistogram {
        if (n_buckets == 0) return Error.InvalidBucketCount;
        if (!(lo < hi) or !std.math.isFinite(lo) or !std.math.isFinite(hi)) return Error.InvalidRange;
        const counts = allocator.alloc(u64, n_buckets) catch return Error.OutOfMemory;
        @memset(counts, 0);
        return .{
            .allocator = allocator,
            .n_buckets = n_buckets,
            .lo = lo,
            .hi = hi,
            .bucket_width = (hi - lo) / @as(f64, @floatFromInt(n_buckets)),
            .counts = counts,
        };
    }

    pub fn deinit(self: *ColumnHistogram) void {
        self.allocator.free(self.counts);
    }

    pub fn add(self: *ColumnHistogram, value: f64) void {
        if (!std.math.isFinite(value)) return;
        var idx: usize = 0;
        if (value <= self.lo) {
            idx = 0;
        } else if (value >= self.hi) {
            idx = self.n_buckets - 1;
        } else {
            const t = (value - self.lo) / self.bucket_width;
            idx = @intFromFloat(@floor(t));
            if (idx >= self.n_buckets) idx = self.n_buckets - 1;
        }
        self.counts[idx] += 1;
    }

    pub fn totalCount(self: ColumnHistogram) u64 {
        var n: u64 = 0;
        for (self.counts) |c| n += c;
        return n;
    }

    /// Pessimistic count in [lo, hi]. Includes every bucket whose
    /// interval overlaps the query range. Returns 0 for empty
    /// range or fully out-of-range queries.
    pub fn countInRange(self: ColumnHistogram, lo: f64, hi: f64) u64 {
        if (!(lo <= hi)) return 0;
        if (hi < self.lo or lo > self.hi) return 0;
        const q_lo = @max(lo, self.lo);
        const q_hi = @min(hi, self.hi);
        var first_idx: usize = @intFromFloat(@floor((q_lo - self.lo) / self.bucket_width));
        var last_idx: usize = @intFromFloat(@floor((q_hi - self.lo) / self.bucket_width));
        if (first_idx >= self.n_buckets) first_idx = self.n_buckets - 1;
        if (last_idx >= self.n_buckets) last_idx = self.n_buckets - 1;
        var sum: u64 = 0;
        var i: usize = first_idx;
        while (i <= last_idx) : (i += 1) sum += self.counts[i];
        return sum;
    }
};

// --- Tests -----------------------------------------------------------------

const testing = std.testing;

test "init refuses zero buckets" {
    try testing.expectError(Error.InvalidBucketCount, ColumnHistogram.init(testing.allocator, 0, 0.0, 1.0));
}

test "init refuses degenerate or non-finite range" {
    try testing.expectError(Error.InvalidRange, ColumnHistogram.init(testing.allocator, 10, 1.0, 1.0));
    try testing.expectError(Error.InvalidRange, ColumnHistogram.init(testing.allocator, 10, 1.0, 0.0));
    try testing.expectError(Error.InvalidRange, ColumnHistogram.init(testing.allocator, 10, std.math.nan(f64), 1.0));
}

test "add then totalCount tracks samples" {
    var h = try ColumnHistogram.init(testing.allocator, 10, 0.0, 1.0);
    defer h.deinit();
    h.add(0.05);
    h.add(0.55);
    h.add(0.95);
    try testing.expectEqual(@as(u64, 3), h.totalCount());
}

test "out-of-range values clamp to the first/last bucket" {
    var h = try ColumnHistogram.init(testing.allocator, 10, 0.0, 1.0);
    defer h.deinit();
    h.add(-5.0);
    h.add(99.0);
    try testing.expectEqual(@as(u64, 1), h.counts[0]);
    try testing.expectEqual(@as(u64, 1), h.counts[9]);
}

test "non-finite values are dropped" {
    var h = try ColumnHistogram.init(testing.allocator, 10, 0.0, 1.0);
    defer h.deinit();
    h.add(std.math.nan(f64));
    h.add(std.math.inf(f64));
    try testing.expectEqual(@as(u64, 0), h.totalCount());
}

test "countInRange covers overlapping buckets pessimistically" {
    var h = try ColumnHistogram.init(testing.allocator, 10, 0.0, 1.0);
    defer h.deinit();
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        const x: f64 = @as(f64, @floatFromInt(i)) / 100.0;
        h.add(x);
    }
    try testing.expectEqual(@as(u64, 100), h.totalCount());
    try testing.expectEqual(@as(u64, 50), h.countInRange(0.0, 0.49));
    try testing.expectEqual(@as(u64, 100), h.countInRange(-10.0, 10.0));
    try testing.expectEqual(@as(u64, 0), h.countInRange(2.0, 3.0));
    try testing.expectEqual(@as(u64, 0), h.countInRange(0.5, 0.4));
}

test "uniform fill distributes samples across buckets" {
    var h = try ColumnHistogram.init(testing.allocator, 5, 0.0, 5.0);
    defer h.deinit();
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        const x: f64 = @as(f64, @floatFromInt(i % 50)) * 0.1;
        h.add(x);
    }
    try testing.expectEqual(@as(u64, 50), h.totalCount());
}

test "single bucket histogram is degenerate but valid" {
    var h = try ColumnHistogram.init(testing.allocator, 1, 0.0, 1.0);
    defer h.deinit();
    h.add(0.5);
    h.add(0.9);
    h.add(0.1);
    try testing.expectEqual(@as(u64, 3), h.counts[0]);
}
