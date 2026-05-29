//! puffin — v0.0.6 port of P2526 (Iceberg V3 Puffin blob format).
//!
//! Ports the Iceberg V3 Puffin byte format (from L70-table-format-
//! deep-MINED.md). Puffin is a Iceberg-managed binary container for
//! auxiliary metadata: deletion vectors, statistics blobs, ML
//! features, etc.
//!
//! Wire layout per Iceberg spec:
//!   [magic 4 bytes: 0x50 0x46 0x41 0x31 = "PFA1"]
//!   For each blob:
//!     [blob_type 4-byte LE u32]
//!     [field_ids count u32]
//!     [field_id u32] * count
//!     [snapshot_id u64]
//!     [sequence_number u64]
//!     [blob_length u32]
//!     [blob bytes]
//!     [crc32 u32]
//!   [footer]:
//!     [blob_count u32]
//!     [magic 4 bytes: 0x50 0x46 0x41 0x31]
//!
//! v0.0.6 ships the writer + reader for this on-disk shape. The
//! Roaring deletion-vector blob type (P820 in L73) is the highest-
//! value Puffin blob — readers union it with the snapshot to filter
//! deletes.

const std = @import("std");

pub const Error = error{
    OutOfMemory,
    Truncated,
    BadMagic,
    BadCrc,
    BlobIndexOutOfRange,
};

pub const magic: [4]u8 = .{ 0x50, 0x46, 0x41, 0x31 };

pub const BlobType = enum(u32) {
    deletion_vector_v1 = 1,
    apache_datasketches_theta_v1 = 2,
    ndv_sketch_v1 = 3,
    /// Caller-defined blob types.
    custom = 0xFFFF_FFFF,
};

pub const Blob = struct {
    blob_type: BlobType,
    field_ids: []const u32,
    snapshot_id: u64,
    sequence_number: u64,
    bytes: []const u8,
};

pub fn write(allocator: std.mem.Allocator, blobs: []const Blob) Error![]u8 {
    var out: std.array_list.Managed(u8) = .init(allocator);
    errdefer out.deinit();
    out.appendSlice(&magic) catch return Error.OutOfMemory;
    for (blobs) |b| {
        appendU32(&out, @intFromEnum(b.blob_type)) catch return Error.OutOfMemory;
        appendU32(&out, @intCast(b.field_ids.len)) catch return Error.OutOfMemory;
        for (b.field_ids) |fid| appendU32(&out, fid) catch return Error.OutOfMemory;
        appendU64(&out, b.snapshot_id) catch return Error.OutOfMemory;
        appendU64(&out, b.sequence_number) catch return Error.OutOfMemory;
        appendU32(&out, @intCast(b.bytes.len)) catch return Error.OutOfMemory;
        out.appendSlice(b.bytes) catch return Error.OutOfMemory;
        const crc = std.hash.Crc32.hash(b.bytes);
        appendU32(&out, crc) catch return Error.OutOfMemory;
    }
    appendU32(&out, @intCast(blobs.len)) catch return Error.OutOfMemory;
    out.appendSlice(&magic) catch return Error.OutOfMemory;
    return out.toOwnedSlice() catch return Error.OutOfMemory;
}

pub const ReadResult = struct {
    blobs: []Blob,
    /// Allocator-owned arrays for each blob's field_ids + bytes slices.
    field_id_arrays: std.array_list.Managed([]u32),

    pub fn deinit(self: *ReadResult, allocator: std.mem.Allocator) void {
        for (self.field_id_arrays.items) |a| allocator.free(a);
        self.field_id_arrays.deinit();
        allocator.free(self.blobs);
    }
};

pub fn read(bytes: []const u8, allocator: std.mem.Allocator) Error!ReadResult {
    if (bytes.len < 8) return Error.Truncated;
    if (!std.mem.eql(u8, bytes[0..4], &magic)) return Error.BadMagic;
    if (!std.mem.eql(u8, bytes[bytes.len - 4 ..], &magic)) return Error.BadMagic;

    const footer_count = std.mem.readInt(u32, bytes[bytes.len - 8 ..][0..4], .little);
    var blobs = std.array_list.Managed(Blob).init(allocator);
    var fid_arrays = std.array_list.Managed([]u32).init(allocator);
    errdefer {
        blobs.deinit();
        for (fid_arrays.items) |a| allocator.free(a);
        fid_arrays.deinit();
    }
    var p: usize = 4;
    var read_count: u32 = 0;
    while (read_count < footer_count) : (read_count += 1) {
        if (bytes.len < p + 4 + 4) return Error.Truncated;
        const bt_raw = std.mem.readInt(u32, bytes[p..][0..4], .little);
        p += 4;
        const fid_count = std.mem.readInt(u32, bytes[p..][0..4], .little);
        p += 4;
        if (bytes.len < p + fid_count * 4 + 8 + 8 + 4) return Error.Truncated;
        const fids = allocator.alloc(u32, fid_count) catch return Error.OutOfMemory;
        errdefer allocator.free(fids);
        for (fids) |*f| {
            f.* = std.mem.readInt(u32, bytes[p..][0..4], .little);
            p += 4;
        }
        const snap_id = std.mem.readInt(u64, bytes[p..][0..8], .little);
        p += 8;
        const seq = std.mem.readInt(u64, bytes[p..][0..8], .little);
        p += 8;
        const blob_len = std.mem.readInt(u32, bytes[p..][0..4], .little);
        p += 4;
        if (bytes.len < p + blob_len + 4) return Error.Truncated;
        const blob_bytes = bytes[p .. p + blob_len];
        p += blob_len;
        const crc_stored = std.mem.readInt(u32, bytes[p..][0..4], .little);
        p += 4;
        const crc_actual = std.hash.Crc32.hash(blob_bytes);
        if (crc_stored != crc_actual) return Error.BadCrc;

        fid_arrays.append(fids) catch return Error.OutOfMemory;
        blobs.append(.{
            .blob_type = @enumFromInt(bt_raw),
            .field_ids = fids,
            .snapshot_id = snap_id,
            .sequence_number = seq,
            .bytes = blob_bytes,
        }) catch return Error.OutOfMemory;
    }
    return .{
        .blobs = blobs.toOwnedSlice() catch return Error.OutOfMemory,
        .field_id_arrays = fid_arrays,
    };
}

// --- helpers --------------------------------------------------------------

fn appendU32(out: *std.array_list.Managed(u8), v: u32) !void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, v, .little);
    try out.appendSlice(&b);
}

fn appendU64(out: *std.array_list.Managed(u8), v: u64) !void {
    var b: [8]u8 = undefined;
    std.mem.writeInt(u64, &b, v, .little);
    try out.appendSlice(&b);
}

// --- Tests ----------------------------------------------------------------

const testing = std.testing;

test "write starts with PFA1 magic + ends with PFA1 magic" {
    const alloc = testing.allocator;
    const blobs = [_]Blob{};
    const bytes = try write(alloc, &blobs);
    defer alloc.free(bytes);
    try testing.expectEqualSlices(u8, &magic, bytes[0..4]);
    try testing.expectEqualSlices(u8, &magic, bytes[bytes.len - 4 ..]);
}

test "write + read round-trip of a single dv blob" {
    const alloc = testing.allocator;
    const fids = [_]u32{ 7, 8, 9 };
    const blob_bytes = [_]u8{ 0xD1, 0xD3, 0x39, 0x64, 0x01, 0x02, 0x03 };
    const blobs = [_]Blob{
        .{
            .blob_type = .deletion_vector_v1,
            .field_ids = &fids,
            .snapshot_id = 100,
            .sequence_number = 5,
            .bytes = &blob_bytes,
        },
    };
    const written = try write(alloc, &blobs);
    defer alloc.free(written);
    var result = try read(written, alloc);
    defer result.deinit(alloc);

    try testing.expectEqual(@as(usize, 1), result.blobs.len);
    try testing.expectEqual(BlobType.deletion_vector_v1, result.blobs[0].blob_type);
    try testing.expectEqual(@as(u64, 100), result.blobs[0].snapshot_id);
    try testing.expectEqual(@as(u64, 5), result.blobs[0].sequence_number);
    try testing.expectEqualSlices(u8, &blob_bytes, result.blobs[0].bytes);
    try testing.expectEqualSlices(u32, &fids, result.blobs[0].field_ids);
}

test "read rejects bad leading magic" {
    const alloc = testing.allocator;
    const bad = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0 };
    try testing.expectError(Error.BadMagic, read(&bad, alloc));
}

test "read rejects truncated bytes" {
    const alloc = testing.allocator;
    const short = [_]u8{ 1, 2, 3 };
    try testing.expectError(Error.Truncated, read(&short, alloc));
}

test "read detects CRC mismatch" {
    const alloc = testing.allocator;
    const blob_bytes = [_]u8{ 0x01, 0x02, 0x03, 0x04 };
    const fids = [_]u32{1};
    const blobs = [_]Blob{
        .{
            .blob_type = .deletion_vector_v1,
            .field_ids = &fids,
            .snapshot_id = 1,
            .sequence_number = 1,
            .bytes = &blob_bytes,
        },
    };
    var written = try write(alloc, &blobs);
    defer alloc.free(written);
    // Corrupt one byte in the blob payload to break the CRC.
    written[written.len - 12] ^= 0x01;
    try testing.expectError(Error.BadCrc, read(written, alloc));
}

test "write multiple blobs round-trips them all" {
    const alloc = testing.allocator;
    const fids = [_]u32{1};
    const b1 = [_]u8{ 0xAA, 0xBB };
    const b2 = [_]u8{ 0xCC, 0xDD, 0xEE };
    const blobs = [_]Blob{
        .{ .blob_type = .deletion_vector_v1, .field_ids = &fids, .snapshot_id = 1, .sequence_number = 1, .bytes = &b1 },
        .{ .blob_type = .ndv_sketch_v1, .field_ids = &fids, .snapshot_id = 2, .sequence_number = 2, .bytes = &b2 },
    };
    const written = try write(alloc, &blobs);
    defer alloc.free(written);
    var result = try read(written, alloc);
    defer result.deinit(alloc);
    try testing.expectEqual(@as(usize, 2), result.blobs.len);
    try testing.expectEqualSlices(u8, &b1, result.blobs[0].bytes);
    try testing.expectEqualSlices(u8, &b2, result.blobs[1].bytes);
}
