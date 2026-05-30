//! price_time_buffer: v0.0.13 substrate from L122 orderbook.
//!
//! L122 named OrderVectorBuffer[N] as the implied primitive:
//! fixed-capacity insertion-sorted bounded buffer prioritized by
//! (price, time). Used in every HFT matching engine to maintain
//! the top-N best bids or top-N best asks without sorting the
//! full book.
//!
//! Generic shape: any system that needs "top-N items ranked by a
//! caller-supplied composite key" with O(log N) insert and O(1)
//! peek. PriceTimeBuffer is the price-time-priority specialization;
//! a generic SortedBoundedBuffer(T, less) sibling would land if
//! a non-CLOB consumer demands.
//!
//! Scope of this revision:
//!   PriceTickX10000 = i64 (matches wflog v0.0.31 SpatialSpread).
//!   PriceTimeKey { price_x10000, ts_ns }. Lower price first
//!     (best-bid convention; flip for best-ask).
//!   Order { id, price_x10000, ts_ns, qty }.
//!   PriceTimeBuffer { allocator, items, cap }. init / deinit /
//!     offer / peek / drain (returns sorted slice, caller owns).
//!     Insertion preserves price-then-time ordering; capacity
//!     overflow drops the WORST (highest-price) entry.
//!
//! Out of scope: matching logic (caller composes), best-ask
//! variant (caller supplies reversed comparator via a sibling
//! primitive when needed), cancel-by-id (caller composes
//! O(N) find + remove).

const std = @import("std");

pub const PriceTickX10000 = i64;

pub const PriceTimeKey = struct {
    price_x10000: PriceTickX10000,
    ts_ns: i64,
};

pub const Order = struct {
    id: u64,
    price_x10000: PriceTickX10000,
    ts_ns: i64,
    qty: u32,

    pub fn key(self: Order) PriceTimeKey {
        return .{ .price_x10000 = self.price_x10000, .ts_ns = self.ts_ns };
    }
};

pub const Error = error{
    OutOfMemory,
    InvalidCapacity,
};

/// Returns true iff a is strictly better than b for bid side
/// (lower price wins; older timestamp breaks ties).
fn bidLess(a: PriceTimeKey, b: PriceTimeKey) bool {
    if (a.price_x10000 != b.price_x10000) return a.price_x10000 < b.price_x10000;
    return a.ts_ns < b.ts_ns;
}

pub const PriceTimeBuffer = struct {
    allocator: std.mem.Allocator,
    items: []Order,
    len_: usize,
    cap: usize,

    pub fn init(allocator: std.mem.Allocator, cap: usize) Error!PriceTimeBuffer {
        if (cap == 0) return Error.InvalidCapacity;
        const items = allocator.alloc(Order, cap) catch return Error.OutOfMemory;
        return .{
            .allocator = allocator,
            .items = items,
            .len_ = 0,
            .cap = cap,
        };
    }

    pub fn deinit(self: *PriceTimeBuffer) void {
        self.allocator.free(self.items);
    }

    pub fn len(self: PriceTimeBuffer) usize {
        return self.len_;
    }

    pub fn isFull(self: PriceTimeBuffer) bool {
        return self.len_ == self.cap;
    }

    /// Offer an order. If buffer not full, insert sorted. If full,
    /// only insert if the new order is strictly better than the
    /// current worst (highest price-time key); the worst then
    /// drops.
    pub fn offer(self: *PriceTimeBuffer, order: Order) void {
        if (self.len_ < self.cap) {
            self.items[self.len_] = order;
            self.len_ += 1;
            self.bubbleUp();
            return;
        }
        const worst = self.items[self.len_ - 1];
        if (bidLess(order.key(), worst.key())) {
            self.items[self.len_ - 1] = order;
            self.bubbleUp();
        }
    }

    fn bubbleUp(self: *PriceTimeBuffer) void {
        var i: usize = self.len_;
        while (i > 1) : (i -= 1) {
            const a = self.items[i - 1];
            const b = self.items[i - 2];
            if (bidLess(a.key(), b.key())) {
                self.items[i - 1] = b;
                self.items[i - 2] = a;
            } else break;
        }
    }

    pub fn peekBest(self: PriceTimeBuffer) ?Order {
        if (self.len_ == 0) return null;
        return self.items[0];
    }

    /// Allocate and return the buffer contents sorted best-first.
    /// Caller owns the returned slice.
    pub fn drain(self: PriceTimeBuffer, allocator: std.mem.Allocator) Error![]Order {
        const out = allocator.alloc(Order, self.len_) catch return Error.OutOfMemory;
        @memcpy(out, self.items[0..self.len_]);
        return out;
    }
};

// --- Tests -----------------------------------------------------------------

const testing = std.testing;

test "init refuses capacity 0" {
    try testing.expectError(Error.InvalidCapacity, PriceTimeBuffer.init(testing.allocator, 0));
}

test "offer maintains price-then-time ordering" {
    var buf = try PriceTimeBuffer.init(testing.allocator, 5);
    defer buf.deinit();
    buf.offer(.{ .id = 1, .price_x10000 = 100, .ts_ns = 10, .qty = 1 });
    buf.offer(.{ .id = 2, .price_x10000 = 90, .ts_ns = 20, .qty = 2 });
    buf.offer(.{ .id = 3, .price_x10000 = 100, .ts_ns = 5, .qty = 3 });
    try testing.expectEqual(@as(usize, 3), buf.len());
    const out = try buf.drain(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqual(@as(u64, 2), out[0].id);
    try testing.expectEqual(@as(u64, 3), out[1].id);
    try testing.expectEqual(@as(u64, 1), out[2].id);
}

test "offer at capacity drops worst" {
    var buf = try PriceTimeBuffer.init(testing.allocator, 2);
    defer buf.deinit();
    buf.offer(.{ .id = 1, .price_x10000 = 100, .ts_ns = 10, .qty = 1 });
    buf.offer(.{ .id = 2, .price_x10000 = 110, .ts_ns = 10, .qty = 1 });
    buf.offer(.{ .id = 3, .price_x10000 = 80, .ts_ns = 10, .qty = 1 });
    try testing.expectEqual(@as(usize, 2), buf.len());
    const out = try buf.drain(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqual(@as(u64, 3), out[0].id);
    try testing.expectEqual(@as(u64, 1), out[1].id);
}

test "offer at capacity refuses worse-than-worst" {
    var buf = try PriceTimeBuffer.init(testing.allocator, 2);
    defer buf.deinit();
    buf.offer(.{ .id = 1, .price_x10000 = 100, .ts_ns = 10, .qty = 1 });
    buf.offer(.{ .id = 2, .price_x10000 = 110, .ts_ns = 10, .qty = 1 });
    buf.offer(.{ .id = 3, .price_x10000 = 200, .ts_ns = 10, .qty = 1 });
    try testing.expectEqual(@as(usize, 2), buf.len());
    const out = try buf.drain(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqual(@as(u64, 1), out[0].id);
    try testing.expectEqual(@as(u64, 2), out[1].id);
}

test "peekBest returns best order" {
    var buf = try PriceTimeBuffer.init(testing.allocator, 5);
    defer buf.deinit();
    try testing.expectEqual(@as(?Order, null), buf.peekBest());
    buf.offer(.{ .id = 1, .price_x10000 = 100, .ts_ns = 10, .qty = 1 });
    buf.offer(.{ .id = 2, .price_x10000 = 90, .ts_ns = 20, .qty = 2 });
    try testing.expectEqual(@as(u64, 2), buf.peekBest().?.id);
}

test "tied price falls back to older ts_ns" {
    var buf = try PriceTimeBuffer.init(testing.allocator, 3);
    defer buf.deinit();
    buf.offer(.{ .id = 1, .price_x10000 = 100, .ts_ns = 200, .qty = 1 });
    buf.offer(.{ .id = 2, .price_x10000 = 100, .ts_ns = 100, .qty = 1 });
    buf.offer(.{ .id = 3, .price_x10000 = 100, .ts_ns = 300, .qty = 1 });
    const out = try buf.drain(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqual(@as(u64, 2), out[0].id);
    try testing.expectEqual(@as(u64, 1), out[1].id);
    try testing.expectEqual(@as(u64, 3), out[2].id);
}

test "isFull transitions at capacity" {
    var buf = try PriceTimeBuffer.init(testing.allocator, 2);
    defer buf.deinit();
    try testing.expect(!buf.isFull());
    buf.offer(.{ .id = 1, .price_x10000 = 100, .ts_ns = 10, .qty = 1 });
    try testing.expect(!buf.isFull());
    buf.offer(.{ .id = 2, .price_x10000 = 100, .ts_ns = 20, .qty = 1 });
    try testing.expect(buf.isFull());
}
