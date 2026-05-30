//! row_iterator: v0.0.12 — column-store -> row iteration primitive.
//!
//! tableformat stores data column-major for compression and
//! vectorized scan. Consumers periodically want a row-wise view
//! (debug print, single-row export, foreign-key join). Port a
//! cursor that takes N parallel column slices (must all be the
//! same length) and yields one row at a time.
//!
//! Scope of this revision:
//!   RowIterator(comptime T) over a single-column slice for the
//!     simple case.
//!   PairRowIterator(comptime A, comptime B) over two parallel
//!     columns yielding {.a, .b} pairs.
//!   TripletRowIterator(comptime A, comptime B, comptime C) for
//!     three columns.
//!   Each errors LengthMismatch if column lengths differ at
//!     init.
//!
//! Out of scope: variable-arity row iterator (caller composes by
//! nesting), filter/map (caller wraps), parallel column scan
//! (separate primitive when needed).

const std = @import("std");

pub const Error = error{
    LengthMismatch,
};

pub fn RowIterator(comptime T: type) type {
    return struct {
        col: []const T,
        i: usize,

        const Self = @This();

        pub fn init(col: []const T) Self {
            return .{ .col = col, .i = 0 };
        }

        pub fn next(self: *Self) ?T {
            if (self.i >= self.col.len) return null;
            const v = self.col[self.i];
            self.i += 1;
            return v;
        }

        pub fn reset(self: *Self) void {
            self.i = 0;
        }
    };
}

pub fn PairRowIterator(comptime A: type, comptime B: type) type {
    return struct {
        a: []const A,
        b: []const B,
        i: usize,

        const Self = @This();
        const Row = struct { a: A, b: B };

        pub fn init(a: []const A, b: []const B) Error!Self {
            if (a.len != b.len) return Error.LengthMismatch;
            return .{ .a = a, .b = b, .i = 0 };
        }

        pub fn next(self: *Self) ?Row {
            if (self.i >= self.a.len) return null;
            const r: Row = .{ .a = self.a[self.i], .b = self.b[self.i] };
            self.i += 1;
            return r;
        }

        pub fn reset(self: *Self) void {
            self.i = 0;
        }
    };
}

pub fn TripletRowIterator(comptime A: type, comptime B: type, comptime C: type) type {
    return struct {
        a: []const A,
        b: []const B,
        c: []const C,
        i: usize,

        const Self = @This();
        const Row = struct { a: A, b: B, c: C };

        pub fn init(a: []const A, b: []const B, c: []const C) Error!Self {
            if (a.len != b.len or b.len != c.len) return Error.LengthMismatch;
            return .{ .a = a, .b = b, .c = c, .i = 0 };
        }

        pub fn next(self: *Self) ?Row {
            if (self.i >= self.a.len) return null;
            const r: Row = .{
                .a = self.a[self.i],
                .b = self.b[self.i],
                .c = self.c[self.i],
            };
            self.i += 1;
            return r;
        }

        pub fn reset(self: *Self) void {
            self.i = 0;
        }
    };
}

// --- Tests -----------------------------------------------------------------

const testing = std.testing;

test "RowIterator yields every element then null" {
    const col = [_]i32{ 1, 2, 3 };
    var it: RowIterator(i32) = .init(&col);
    try testing.expectEqual(@as(?i32, 1), it.next());
    try testing.expectEqual(@as(?i32, 2), it.next());
    try testing.expectEqual(@as(?i32, 3), it.next());
    try testing.expectEqual(@as(?i32, null), it.next());
}

test "RowIterator on empty slice yields null immediately" {
    const col: []const i32 = &.{};
    var it: RowIterator(i32) = .init(col);
    try testing.expectEqual(@as(?i32, null), it.next());
}

test "RowIterator reset rewinds to start" {
    const col = [_]i32{ 5, 6 };
    var it: RowIterator(i32) = .init(&col);
    _ = it.next();
    _ = it.next();
    it.reset();
    try testing.expectEqual(@as(?i32, 5), it.next());
}

test "PairRowIterator yields pairs over two columns" {
    const ids = [_]u32{ 1, 2, 3 };
    const scores = [_]f32{ 0.9, 0.7, 0.5 };
    var it = try PairRowIterator(u32, f32).init(&ids, &scores);
    const r1 = it.next().?;
    try testing.expectEqual(@as(u32, 1), r1.a);
    try testing.expectEqual(@as(f32, 0.9), r1.b);
    const r2 = it.next().?;
    try testing.expectEqual(@as(u32, 2), r2.a);
    try testing.expectEqual(@as(f32, 0.7), r2.b);
    _ = it.next();
    try testing.expectEqual(@as(?@TypeOf(r1), null), it.next());
}

test "PairRowIterator rejects length mismatch" {
    const a = [_]i32{ 1, 2 };
    const b = [_]i32{1};
    try testing.expectError(Error.LengthMismatch, PairRowIterator(i32, i32).init(&a, &b));
}

test "TripletRowIterator yields three-column rows" {
    const ids = [_]u32{ 1, 2 };
    const names = [_][]const u8{ "a", "b" };
    const flags = [_]bool{ true, false };
    var it = try TripletRowIterator(u32, []const u8, bool).init(&ids, &names, &flags);
    const r1 = it.next().?;
    try testing.expectEqual(@as(u32, 1), r1.a);
    try testing.expectEqualStrings("a", r1.b);
    try testing.expect(r1.c);
    const r2 = it.next().?;
    try testing.expectEqual(@as(u32, 2), r2.a);
    try testing.expectEqualStrings("b", r2.b);
    try testing.expect(!r2.c);
}

test "TripletRowIterator rejects any mismatch" {
    const a = [_]i32{ 1, 2 };
    const b = [_]i32{ 1, 2, 3 };
    const c = [_]i32{ 1, 2 };
    try testing.expectError(Error.LengthMismatch, TripletRowIterator(i32, i32, i32).init(&a, &b, &c));
}
