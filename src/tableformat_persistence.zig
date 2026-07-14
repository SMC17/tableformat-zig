//! tableformat_persistence — workflow event-log → tableformat manifest.
//!
//! v0.0.3 ships `persistence.snapshotToBytes` which produces a
//! self-describing WFL0 binary blob. v0.0.6 adds an alternate
//! persistence lane: serialise the audit history into a
//! `tableformat-zig` manifest so the workflow log lives inside the
//! same metadata substrate the rest of the castle uses.
//!
//! Shape (v0.0.6):
//!   Schema for the workflow-events table:
//!     col 1: workflow_id (i64)
//!     col 2: seq         (i64)
//!     col 3: timestamp   (timestamp_us i64)
//!     col 4: kind        (i32)
//!     col 5: bytes       (string)
//!
//!   Partition spec: by workflow_id (one DataFile per workflow).
//!
//!   Each `DataFile` describes one workflow stream by carrying the
//!   workflow_id as its partition value + the path encoding the
//!   workflow_id. v0.0.6 does NOT yet write actual Parquet bytes to
//!   the path; the manifest is the durability artifact, and the
//!   round-trip currently works through the WFL0 path (which the
//!   manifest's `summary` field references). v0.0.7 wires real
//!   per-workflow row-group writes.

const std = @import("std");
const tableformat = @import("tableformat");
const workflow_log = @import("workflow_log.zig");

pub const WorkflowLog = workflow_log.WorkflowLog;
pub const WorkflowId = workflow_log.WorkflowId;

pub const Error = error{
    OutOfMemory,
    WorkflowNotFound,
};

/// Build the canonical workflow-events schema. Caller owns the
/// returned columns slice.
pub fn buildEventSchemaColumns(allocator: std.mem.Allocator) ![]tableformat.Column {
    var cols = try allocator.alloc(tableformat.Column, 5);
    cols[0] = .{ .id = 1, .name = "workflow_id", .type = .int64, .nullable = false };
    cols[1] = .{ .id = 2, .name = "seq", .type = .int64, .nullable = false };
    cols[2] = .{ .id = 3, .name = "timestamp", .type = .timestamp_us, .nullable = false };
    cols[3] = .{ .id = 4, .name = "kind", .type = .int32, .nullable = false };
    cols[4] = .{ .id = 5, .name = "bytes", .type = .string, .nullable = false };
    return cols;
}

pub fn buildPartitionFields(allocator: std.mem.Allocator) ![]tableformat.PartitionField {
    var fields = try allocator.alloc(tableformat.PartitionField, 1);
    fields[0] = .{ .source_column_id = 1, .name = "workflow_id", .transform = .identity };
    return fields;
}

/// Build the tableformat manifest. Caller owns the returned manifest's
/// schemas + partition_specs + the file list inside the snapshot.
/// Free with `freeManifest`.
pub fn snapshotToManifest(
    allocator: std.mem.Allocator,
    log: *WorkflowLog,
    table_uuid: [16]u8,
    location: []const u8,
    snapshot_id: u64,
    committed_at: i64,
) !tableformat.Manifest {
    // Build schema(s).
    var schemas = try allocator.alloc(tableformat.Schema, 1);
    schemas[0] = .{ .schema_id = 1, .columns = try buildEventSchemaColumns(allocator) };

    // Build partition spec.
    var specs = try allocator.alloc(tableformat.PartitionSpec, 1);
    specs[0] = .{ .spec_id = 1, .fields = try buildPartitionFields(allocator) };

    // One DataFile per workflow stream.
    var files = try allocator.alloc(tableformat.DataFile, log.streams.count());
    var idx: usize = 0;
    var it = log.streams.iterator();
    while (it.next()) |kv| : (idx += 1) {
        const wfid = kv.key_ptr.*;
        const stream = kv.value_ptr.*;
        const path = try std.fmt.allocPrint(
            allocator,
            "workflow_events/workflow_id={d}/0.parquet",
            .{wfid},
        );
        const part_json = try std.fmt.allocPrint(
            allocator,
            "{{\"workflow_id\":{d}}}",
            .{wfid},
        );
        files[idx] = .{
            .path = path,
            .spec_id = 1,
            .partition_values_json = part_json,
            .record_count = stream.events.items.len,
            .file_size_bytes = 0,
        };
    }

    return .{
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
            .summary = "workflow-event-log",
            .schema_id = 1,
            .default_spec_id = 1,
            .files = files,
        },
    };
}

/// Free a manifest produced by `snapshotToManifest`.
pub fn freeManifest(allocator: std.mem.Allocator, m: tableformat.Manifest) void {
    for (m.schemas) |s| allocator.free(s.columns);
    allocator.free(m.schemas);
    for (m.partition_specs) |s| allocator.free(s.fields);
    allocator.free(m.partition_specs);
    for (m.current_snapshot.files) |f| {
        allocator.free(f.path);
        allocator.free(f.partition_values_json);
    }
    allocator.free(m.current_snapshot.files);
}

// --- Tests ----------------------------------------------------------------

const testing = std.testing;

test "buildEventSchemaColumns returns five canonical columns" {
    const alloc = testing.allocator;
    const cols = try buildEventSchemaColumns(alloc);
    defer alloc.free(cols);
    try testing.expectEqual(@as(usize, 5), cols.len);
    try testing.expectEqualStrings("workflow_id", cols[0].name);
    try testing.expectEqualStrings("seq", cols[1].name);
    try testing.expectEqualStrings("timestamp", cols[2].name);
    try testing.expectEqualStrings("kind", cols[3].name);
    try testing.expectEqualStrings("bytes", cols[4].name);
}

test "buildPartitionFields partitions by workflow_id identity" {
    const alloc = testing.allocator;
    const fields = try buildPartitionFields(alloc);
    defer alloc.free(fields);
    try testing.expectEqual(@as(usize, 1), fields.len);
    try testing.expectEqualStrings("workflow_id", fields[0].name);
    try testing.expectEqual(tableformat.Transform.identity, fields[0].transform);
}

test "snapshotToManifest produces one DataFile per workflow stream" {
    const alloc = testing.allocator;
    var log: WorkflowLog = .init(alloc);
    defer log.deinit();
    try log.append(7, 1, 100, .workflow_started, "a");
    try log.append(7, 2, 200, .activity_scheduled, "b");
    try log.append(11, 1, 300, .workflow_started, "c");

    const manifest = try snapshotToManifest(alloc, &log, [_]u8{0} ** 16, "/wflog", 42, 1_700_000_000);
    defer freeManifest(alloc, manifest);

    try testing.expectEqual(@as(usize, 2), manifest.current_snapshot.files.len);

    // Each DataFile's record_count matches its stream length.
    var found_7: ?usize = null;
    var found_11: ?usize = null;
    for (manifest.current_snapshot.files) |f| {
        if (std.mem.indexOf(u8, f.path, "workflow_id=7") != null) found_7 = f.record_count;
        if (std.mem.indexOf(u8, f.path, "workflow_id=11") != null) found_11 = f.record_count;
    }
    try testing.expectEqual(@as(usize, 2), found_7.?);
    try testing.expectEqual(@as(usize, 1), found_11.?);
}

test "snapshotToManifest empty log → empty file list" {
    const alloc = testing.allocator;
    var log: WorkflowLog = .init(alloc);
    defer log.deinit();
    const manifest = try snapshotToManifest(alloc, &log, [_]u8{0} ** 16, "/wflog", 1, 0);
    defer freeManifest(alloc, manifest);
    try testing.expectEqual(@as(usize, 0), manifest.current_snapshot.files.len);
}

test "snapshotToManifest current_schema_id + default_spec_id resolve" {
    const alloc = testing.allocator;
    var log: WorkflowLog = .init(alloc);
    defer log.deinit();
    try log.append(1, 1, 100, .workflow_started, "x");

    var manifest = try snapshotToManifest(alloc, &log, [_]u8{0} ** 16, "/wflog", 42, 1_700_000_000);
    defer freeManifest(alloc, manifest);

    const schema = manifest.schemaById(1).?;
    try testing.expectEqual(@as(usize, 5), schema.columns.len);

    const spec = manifest.specById(1).?;
    try testing.expectEqual(@as(usize, 1), spec.fields.len);
    try testing.expectEqual(@as(u32, 1), manifest.default_spec_id);
}

test "L6 zero-copy: every file resolves to its own spec via Manifest.resolveSpecForFile" {
    const alloc = testing.allocator;
    var log: WorkflowLog = .init(alloc);
    defer log.deinit();
    try log.append(42, 1, 100, .workflow_started, "");

    var manifest = try snapshotToManifest(alloc, &log, [_]u8{0} ** 16, "/wflog", 1, 0);
    defer freeManifest(alloc, manifest);

    for (manifest.current_snapshot.files) |f| {
        const resolved = manifest.resolveSpecForFile(f).?;
        try testing.expectEqual(@as(u32, 1), resolved.spec_id);
    }
}
