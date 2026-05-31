//! histogram_quantile: v0.0.14 — quantile estimate from ColumnHistogram.
//!
//! v0.0.11 ColumnHistogram is equi-width and tracks bucket
//! counts. Common consumer need: extract P50/P95/P99 from the
//! histogram without keeping the raw samples. Standard approach:
//! find the bucket containing the target rank, then linearly
//! interpolate within that bucket assuming uniform distribution.
//!
//! Cross-primitive composition: ColumnHistogram (v0.0.11) + this
//! module gives you cheap streaming quantiles complementing
//! dq-zig PSquare (which is exact-streaming).
//!
//! Scope of this revision:
//!   quantileEstimate(hist, q) returns the q-quantile estimate
//!     by walking buckets to find the one containing target rank,
//!     then linear-interpolating inside. q must be in [0, 1].
//!     Returns NaN on empty histogram.
//!   medianEstimate(hist) sugar for quantileEstimate(hist, 0.5).
//!
//! Out of scope: P-square streaming variant (dq-zig PSquare),
//! cumulative distribution accessor, sample-weighted bucket
//! representation.

const std = @import("std");
const column_histogram = @import("column_histogram.zig");

pub const ColumnHistogram = column_histogram.ColumnHistogram;

pub const Error = error{
    QuantileOutOfRange,
};

pub fn quantileEstimate(hist: ColumnHistogram, q: f64) Error!f64 {
    if (!std.math.isFinite(q) or q < 0.0 or q > 1.0) return Error.QuantileOutOfRange;
    const total = hist.totalCount();
    if (total == 0) return std.math.nan(f64);
    const target_rank = q * @as(f64, @floatFromInt(total));
    var cumulative: f64 = 0.0;
    var i: usize = 0;
    while (i < hist.n_buckets) : (i += 1) {
        const c = @as(f64, @floatFromInt(hist.counts[i]));
        if (c == 0.0) continue;
        if (cumulative + c >= target_rank) {
            const local_rank = target_rank - cumulative;
            const t = local_rank / c;
            return hist.lo + (@as(f64, @floatFromInt(i)) + t) * hist.bucket_width;
        }
        cumulative += c;
    }
    return hist.hi;
}

pub fn medianEstimate(hist: ColumnHistogram) Error!f64 {
    return quantileEstimate(hist, 0.5);
}

// --- Tests -----------------------------------------------------------------

const testing = std.testing;

test "quantileEstimate refuses out-of-range q" {
    var h = try ColumnHistogram.init(testing.allocator, 10, 0.0, 1.0);
    defer h.deinit();
    h.add(0.5);
    try testing.expectError(Error.QuantileOutOfRange, quantileEstimate(h, -0.1));
    try testing.expectError(Error.QuantileOutOfRange, quantileEstimate(h, 1.5));
    try testing.expectError(Error.QuantileOutOfRange, quantileEstimate(h, std.math.nan(f64)));
}

test "quantileEstimate on empty histogram returns NaN" {
    var h = try ColumnHistogram.init(testing.allocator, 10, 0.0, 1.0);
    defer h.deinit();
    const v = try quantileEstimate(h, 0.5);
    try testing.expect(std.math.isNan(v));
}

test "medianEstimate on uniform 0..100 is near 50" {
    var h = try ColumnHistogram.init(testing.allocator, 20, 0.0, 100.0);
    defer h.deinit();
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        h.add(@floatFromInt(i));
    }
    const m = try medianEstimate(h);
    try testing.expect(m >= 45.0 and m <= 55.0);
}

test "P99 estimate on uniform 0..1000 is near 990" {
    var h = try ColumnHistogram.init(testing.allocator, 100, 0.0, 1000.0);
    defer h.deinit();
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        h.add(@floatFromInt(i));
    }
    const p99 = try quantileEstimate(h, 0.99);
    try testing.expect(p99 >= 980.0 and p99 <= 1000.0);
}

test "P50 P95 P99 ordering holds" {
    var h = try ColumnHistogram.init(testing.allocator, 50, 0.0, 100.0);
    defer h.deinit();
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        h.add(@as(f64, @floatFromInt(i % 100)));
    }
    const p50 = try quantileEstimate(h, 0.50);
    const p95 = try quantileEstimate(h, 0.95);
    const p99 = try quantileEstimate(h, 0.99);
    try testing.expect(p50 <= p95);
    try testing.expect(p95 <= p99);
}

test "quantileEstimate single-bucket histogram returns interpolated value" {
    var h = try ColumnHistogram.init(testing.allocator, 1, 0.0, 100.0);
    defer h.deinit();
    h.add(25.0);
    h.add(50.0);
    h.add(75.0);
    const m = try medianEstimate(h);
    try testing.expect(m >= 0.0 and m <= 100.0);
}

test "quantileEstimate at q=0 returns near-bottom" {
    var h = try ColumnHistogram.init(testing.allocator, 10, 0.0, 10.0);
    defer h.deinit();
    h.add(5.0);
    const v = try quantileEstimate(h, 0.0);
    try testing.expect(v >= 5.0 and v < 6.0);
}

test "quantileEstimate at q=1 returns top of bucket containing only sample" {
    var h = try ColumnHistogram.init(testing.allocator, 10, 0.0, 10.0);
    defer h.deinit();
    h.add(5.0);
    const v = try quantileEstimate(h, 1.0);
    try testing.expectApproxEqAbs(@as(f64, 6.0), v, 1e-9);
}
