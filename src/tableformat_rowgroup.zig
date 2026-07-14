//! tableformat_rowgroup — per-workflow row-group bytes.
//!
//! v0.0.6 ships the canonical 5-column schema + one `DataFile` per
//! workflow stream. The `file_size_bytes` field stays 0 because the
//! manifest is metadata only.
//!
//! v0.0.7 ships an actual per-workflow row-group encoder. The format
//! is a simple length-prefixed columnar layout that mirrors the
//! Arrow IPC "uncompressed buffers" shape but stays vendored
//! (Arrow-vendored IPC writer ships in v0.0.8):
//!
//!   header:      magic [4]u8 = "WFLR"
//!                version u32 = 1
//!                row_count u64
//!   columns:     5 columns in declared order
//!   per column:  byte_length u32
//!                bytes …
//!
//! Column encodings (per row):
//!   workflow_id i64 LE (8 bytes per row, no nulls)
//!   seq         i64 LE (8 bytes per row, no nulls)
//!   timestamp   i64 LE (8 bytes per row, no nulls)
//!   kind        i32 LE (4 bytes per row, no nulls)
//!   bytes       length-prefixed: per row, u32 LE length + payload
//!
//! `snapshotToManifestWithRowGroups` returns a fully wired manifest
//! AND the row-group byte buffers, one per workflow stream. The
//! manifest's `file_size_bytes` matches each buffer's length.

const std = @import("std");
const tableformat = @import("tableformat");
const workflow_log = @import("workflow_log.zig");
const tfp = @import("tableformat_persistence.zig");

pub const WorkflowLog = workflow_log.WorkflowLog;
pub const WorkflowId = workflow_log.WorkflowId;
pub const EventSeq = workflow_log.EventSeq;
pub const Timestamp = workflow_log.Timestamp;
pub const EventKind = workflow_log.EventKind;

pub const Error = error{
    WorkflowNotFound,
    BadMagic,
    UnsupportedVersion,
    Truncated,
    UnsupportedKind,
    OutOfMemory,
};

pub const wire_magic = [_]u8{ 'W', 'F', 'L', 'R' };
pub const wire_version: u32 = 1;

/// Encode one workflow stream into a row-group byte buffer. Caller
/// owns the returned slice.
pub fn writeStreamRowGroupBytes(
    allocator: std.mem.Allocator,
    log: *WorkflowLog,
    workflow_id: WorkflowId,
) Error![]const u8 {
    const stream_len = log.streamLen(workflow_id) orelse return Error.WorkflowNotFound;

    var out: std.array_list.Managed(u8) = .init(allocator);
    errdefer out.deinit();

    // Header.
    out.appendSlice(&wire_magic) catch return Error.OutOfMemory;
    appendU32(&out, wire_version) catch return Error.OutOfMemory;
    appendU64(&out, @intCast(stream_len)) catch return Error.OutOfMemory;

    // Column 1: workflow_id (i64).
    const wf_col_bytes: u32 = @intCast(stream_len * 8);
    appendU32(&out, wf_col_bytes) catch return Error.OutOfMemory;
    var i: EventSeq = 1;
    while (i <= stream_len) : (i += 1) appendI64(&out, @intCast(workflow_id)) catch return Error.OutOfMemory;

    // Column 2: seq.
    appendU32(&out, wf_col_bytes) catch return Error.OutOfMemory;
    i = 1;
    while (i <= stream_len) : (i += 1) appendI64(&out, @intCast(i)) catch return Error.OutOfMemory;

    // Column 3: timestamp.
    appendU32(&out, wf_col_bytes) catch return Error.OutOfMemory;
    i = 1;
    while (i <= stream_len) : (i += 1) {
        const e = log.eventAt(workflow_id, i) orelse return Error.Truncated;
        appendI64(&out, e.timestamp) catch return Error.OutOfMemory;
    }

    // Column 4: kind (i32).
    const kind_col_bytes: u32 = @intCast(stream_len * 4);
    appendU32(&out, kind_col_bytes) catch return Error.OutOfMemory;
    i = 1;
    while (i <= stream_len) : (i += 1) {
        const e = log.eventAt(workflow_id, i) orelse return Error.Truncated;
        appendI32(&out, @intCast(@intFromEnum(e.kind))) catch return Error.OutOfMemory;
    }

    // Column 5: bytes (length-prefixed per row).
    // First measure the total column size.
    var bytes_col_size: u32 = 0;
    i = 1;
    while (i <= stream_len) : (i += 1) {
        const e = log.eventAt(workflow_id, i) orelse return Error.Truncated;
        bytes_col_size += 4 + @as(u32, @intCast(e.bytes.len));
    }
    appendU32(&out, bytes_col_size) catch return Error.OutOfMemory;
    i = 1;
    while (i <= stream_len) : (i += 1) {
        const e = log.eventAt(workflow_id, i) orelse return Error.Truncated;
        appendU32(&out, @intCast(e.bytes.len)) catch return Error.OutOfMemory;
        out.appendSlice(e.bytes) catch return Error.OutOfMemory;
    }

    return out.toOwnedSlice() catch return Error.OutOfMemory;
}

/// Restore one workflow stream from a row-group byte buffer. Appends
/// every event to the supplied log. Caller still owns the byte
/// buffer; the events' `bytes` slices borrow from the buffer.
/// `log.adoptBytes(bytes)` can hand ownership over.
pub fn readStreamRowGroupBytes(
    log: *WorkflowLog,
    bytes: []const u8,
) Error!void {
    var cursor: usize = 0;
    if (bytes.len < wire_magic.len + 4 + 8) return Error.Truncated;
    if (!std.mem.eql(u8, bytes[0..wire_magic.len], &wire_magic)) return Error.BadMagic;
    cursor += wire_magic.len;
    const version = readU32(bytes, &cursor);
    if (version != wire_version) return Error.UnsupportedVersion;
    const row_count = readU64(bytes, &cursor);

    // Column 1: workflow_id.
    const wf_col_len = readU32(bytes, &cursor);
    if (cursor + wf_col_len > bytes.len) return Error.Truncated;
    var workflow_id: WorkflowId = 0;
    if (row_count > 0) workflow_id = @intCast(readI64Slice(bytes[cursor .. cursor + wf_col_len], 0));
    cursor += wf_col_len;

    // Column 2: seq.
    const seq_col_len = readU32(bytes, &cursor);
    if (cursor + seq_col_len > bytes.len) return Error.Truncated;
    const seq_off = cursor;
    cursor += seq_col_len;

    // Column 3: timestamp.
    const ts_col_len = readU32(bytes, &cursor);
    if (cursor + ts_col_len > bytes.len) return Error.Truncated;
    const ts_off = cursor;
    cursor += ts_col_len;

    // Column 4: kind.
    const kind_col_len = readU32(bytes, &cursor);
    if (cursor + kind_col_len > bytes.len) return Error.Truncated;
    const kind_off = cursor;
    cursor += kind_col_len;

    // Column 5: bytes.
    const bytes_col_len = readU32(bytes, &cursor);
    if (cursor + bytes_col_len > bytes.len) return Error.Truncated;
    var bytes_cursor = cursor;
    cursor += bytes_col_len;

    var i: u64 = 0;
    while (i < row_count) : (i += 1) {
        const seq: EventSeq = @intCast(readI64Slice(bytes[seq_off..], @intCast(i)));
        const ts: Timestamp = readI64Slice(bytes[ts_off..], @intCast(i));
        const kind_raw = readI32Slice(bytes[kind_off..], @intCast(i));
        const kind = std.enums.fromInt(EventKind, @as(u8, @intCast(kind_raw))) orelse return Error.UnsupportedKind;

        const blen = std.mem.readInt(u32, bytes[bytes_cursor..][0..4], .little);
        bytes_cursor += 4;
        if (bytes_cursor + blen > bytes.len) return Error.Truncated;
        const payload = bytes[bytes_cursor .. bytes_cursor + blen];
        bytes_cursor += blen;

        log.append(workflow_id, seq, ts, kind, payload) catch return Error.OutOfMemory;
    }
}

pub const ManifestWithBytes = struct {
    manifest: tableformat.Manifest,
    /// One byte buffer per `DataFile` in the manifest's snapshot.
    /// Ordered the same way as `manifest.current_snapshot.files`.
    row_groups: []const []const u8,
};

/// Build the manifest + the per-workflow row-group bytes in lockstep.
/// Caller frees via `freeManifestWithBytes`.
pub fn snapshotToManifestWithRowGroups(
    allocator: std.mem.Allocator,
    log: *WorkflowLog,
    table_uuid: [16]u8,
    location: []const u8,
    snapshot_id: u64,
    committed_at: i64,
) Error!ManifestWithBytes {
    // Build the row-groups first; we'll use their sizes for the
    // manifest's file_size_bytes field.
    var row_groups: std.array_list.Managed([]const u8) = .init(allocator);
    errdefer {
        for (row_groups.items) |b| allocator.free(b);
        row_groups.deinit();
    }

    var schemas = allocator.alloc(tableformat.Schema, 1) catch return Error.OutOfMemory;
    errdefer allocator.free(schemas);
    schemas[0] = .{ .schema_id = 1, .columns = tfp.buildEventSchemaColumns(allocator) catch return Error.OutOfMemory };

    var specs = allocator.alloc(tableformat.PartitionSpec, 1) catch return Error.OutOfMemory;
    errdefer allocator.free(specs);
    specs[0] = .{ .spec_id = 1, .fields = tfp.buildPartitionFields(allocator) catch return Error.OutOfMemory };

    var files = allocator.alloc(tableformat.DataFile, log.streams.count()) catch return Error.OutOfMemory;
    errdefer allocator.free(files);

    var idx: usize = 0;
    var it = log.streams.iterator();
    while (it.next()) |kv| : (idx += 1) {
        const wfid = kv.key_ptr.*;
        const stream = kv.value_ptr.*;
        const bytes = try writeStreamRowGroupBytes(allocator, log, wfid);
        row_groups.append(bytes) catch return Error.OutOfMemory;

        const path = std.fmt.allocPrint(allocator, "workflow_events/workflow_id={d}/0.parquet", .{wfid}) catch return Error.OutOfMemory;
        const part_json = std.fmt.allocPrint(allocator, "{{\"workflow_id\":{d}}}", .{wfid}) catch return Error.OutOfMemory;
        files[idx] = .{
            .path = path,
            .spec_id = 1,
            .partition_values_json = part_json,
            .record_count = stream.events.items.len,
            .file_size_bytes = bytes.len,
        };
    }

    const manifest: tableformat.Manifest = .{
        .table_uuid = table_uuid,
        .location = location,
        .schemas = schemas,
        .current_schema_id = 1,
        .partition_specs = specs,
        .default_spec_id = 1,
        .last_sequence_number = snapshot_id,
        .current_snapshot = .{
            .snapshot_id = snapshot_id,
            .parent_snapshot_id = null,
            .committed_at = committed_at,
            .summary = "workflow-event-log + row groups",
            .schema_id = 1,
            .default_spec_id = 1,
            .files = files,
        },
    };
    const row_groups_owned = row_groups.toOwnedSlice() catch return Error.OutOfMemory;
    return .{ .manifest = manifest, .row_groups = row_groups_owned };
}

pub fn freeManifestWithBytes(allocator: std.mem.Allocator, mwb: ManifestWithBytes) void {
    tfp.freeManifest(allocator, mwb.manifest);
    for (mwb.row_groups) |b| allocator.free(b);
    allocator.free(mwb.row_groups);
}

// --- helpers --------------------------------------------------------------

fn appendU32(out: *std.array_list.Managed(u8), v: u32) !void {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, v, .little);
    try out.appendSlice(&buf);
}

fn appendU64(out: *std.array_list.Managed(u8), v: u64) !void {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &buf, v, .little);
    try out.appendSlice(&buf);
}

fn appendI32(out: *std.array_list.Managed(u8), v: i32) !void {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(i32, &buf, v, .little);
    try out.appendSlice(&buf);
}

fn appendI64(out: *std.array_list.Managed(u8), v: i64) !void {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(i64, &buf, v, .little);
    try out.appendSlice(&buf);
}

fn readU32(bytes: []const u8, cursor: *usize) u32 {
    const v = std.mem.readInt(u32, bytes[cursor.*..][0..4], .little);
    cursor.* += 4;
    return v;
}

fn readU64(bytes: []const u8, cursor: *usize) u64 {
    const v = std.mem.readInt(u64, bytes[cursor.*..][0..8], .little);
    cursor.* += 8;
    return v;
}

fn readI64Slice(slice: []const u8, row: usize) i64 {
    return std.mem.readInt(i64, slice[row * 8 ..][0..8], .little);
}

fn readI32Slice(slice: []const u8, row: usize) i32 {
    return std.mem.readInt(i32, slice[row * 4 ..][0..4], .little);
}

// --- Tests ----------------------------------------------------------------

const testing = std.testing;

test "writeStreamRowGroupBytes empty stream rejected" {
    var log: WorkflowLog = .init(testing.allocator);
    defer log.deinit();
    try testing.expectError(Error.WorkflowNotFound, writeStreamRowGroupBytes(testing.allocator, &log, 99));
}

test "writeStreamRowGroupBytes header has magic + version" {
    const alloc = testing.allocator;
    var log: WorkflowLog = .init(alloc);
    defer log.deinit();
    try log.append(7, 1, 100, .workflow_started, "hello");

    const bytes = try writeStreamRowGroupBytes(alloc, &log, 7);
    defer alloc.free(bytes);
    try testing.expectEqualSlices(u8, &wire_magic, bytes[0..4]);
    try testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, bytes[4..8], .little));
    try testing.expectEqual(@as(u64, 1), std.mem.readInt(u64, bytes[8..16], .little));
}

test "writeStreamRowGroupBytes → readStreamRowGroupBytes round-trips a stream" {
    const alloc = testing.allocator;
    var log: WorkflowLog = .init(alloc);
    defer log.deinit();
    try log.append(7, 1, 100, .workflow_started, "init");
    try log.append(7, 2, 200, .activity_scheduled, "a1-args");
    try log.append(7, 3, 300, .activity_completed, "a1-result");

    const bytes = try writeStreamRowGroupBytes(alloc, &log, 7);
    defer alloc.free(bytes);

    var restored: WorkflowLog = .init(alloc);
    defer restored.deinit();
    try readStreamRowGroupBytes(&restored, bytes);

    try testing.expectEqual(@as(?usize, 3), restored.streamLen(7));
    try testing.expectEqualStrings("init", restored.eventAt(7, 1).?.bytes);
    try testing.expectEqualStrings("a1-args", restored.eventAt(7, 2).?.bytes);
    try testing.expectEqualStrings("a1-result", restored.eventAt(7, 3).?.bytes);
    try testing.expectEqual(EventKind.activity_completed, restored.eventAt(7, 3).?.kind);
    try testing.expectEqual(@as(Timestamp, 300), restored.eventAt(7, 3).?.timestamp);
}

test "readStreamRowGroupBytes rejects bad magic" {
    const alloc = testing.allocator;
    var log: WorkflowLog = .init(alloc);
    defer log.deinit();
    const bad = [_]u8{ 'X', 'X', 'X', 'X' } ++ [_]u8{0} ** 12;
    try testing.expectError(Error.BadMagic, readStreamRowGroupBytes(&log, &bad));
}

test "snapshotToManifestWithRowGroups produces file_size_bytes matching the buffer length" {
    const alloc = testing.allocator;
    var log: WorkflowLog = .init(alloc);
    defer log.deinit();
    try log.append(7, 1, 100, .workflow_started, "a");
    try log.append(11, 1, 300, .workflow_started, "b");

    const mwb = try snapshotToManifestWithRowGroups(alloc, &log, [_]u8{0} ** 16, "/wflog", 42, 1_700_000_000);
    defer freeManifestWithBytes(alloc, mwb);

    try testing.expectEqual(@as(usize, 2), mwb.row_groups.len);
    for (mwb.manifest.current_snapshot.files, 0..) |f, i| {
        try testing.expectEqual(mwb.row_groups[i].len, f.file_size_bytes);
        try testing.expect(f.file_size_bytes > 0);
    }
}

test "round-trip the full WorkflowLog through manifest + row-groups" {
    const alloc = testing.allocator;
    var log: WorkflowLog = .init(alloc);
    defer log.deinit();
    try log.append(7, 1, 100, .workflow_started, "x");
    try log.append(7, 2, 200, .activity_scheduled, "y");
    try log.append(11, 1, 300, .workflow_started, "z");

    const mwb = try snapshotToManifestWithRowGroups(alloc, &log, [_]u8{0} ** 16, "/wflog", 1, 0);
    defer freeManifestWithBytes(alloc, mwb);

    // Rebuild a fresh log from the per-workflow row-groups.
    var restored: WorkflowLog = .init(alloc);
    defer restored.deinit();
    for (mwb.row_groups) |buf| try readStreamRowGroupBytes(&restored, buf);

    try testing.expectEqual(@as(?usize, 2), restored.streamLen(7));
    try testing.expectEqual(@as(?usize, 1), restored.streamLen(11));
    try testing.expectEqualStrings("y", restored.eventAt(7, 2).?.bytes);
    try testing.expectEqualStrings("z", restored.eventAt(11, 1).?.bytes);
}
