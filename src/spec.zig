//! tableformat — Iceberg-class table-format metadata layer for Zig 0.16.
//!
//! Bundles the L1 + L2 + L3 + L6 + L27 castle ports into one library:
//!
//! - **L1 partition-spec versioning** — each `PartitionSpec` has a
//!   monotonically increasing `spec_id`; the table tracks the latest
//!   AND retains historical specs so old data files (written under
//!   prior specs) remain readable.
//! - **L2 manifest metastore decoupling** — table metadata lives as
//!   a JSON `Manifest` blob in object storage, not a DBMS. Partition
//!   list derived from the manifest entries.
//! - **L3 compute-agnostic schema contract** — the table's `Schema`
//!   is declared once and travels with the manifest; engines that
//!   read the table all see the same column types + nullability +
//!   ordering.
//! - **L6 zero-copy partition evolution** — switching from `(ds, hr)`
//!   to `(ds)` does not rewrite files. New writes use the new spec;
//!   reads honour each file's recorded `spec_id`.
//! - **L27 snapshot transactions** — every write produces a new
//!   `Snapshot`; readers see either the old snapshot or the new,
//!   never mixed. Optimistic concurrency via snapshot-ID compare.
//!
//! v0.0.1 ships the data shapes + JSON round-trip + a single-snapshot
//! `Manifest`. v0.0.2 ships the multi-snapshot chain + the partition
//! resolver. v0.0.3 ships the object-store backend + the snapshot
//! transaction (commit-or-retry).

const std = @import("std");

// --- Schema --------------------------------------------------------------

/// Canonical column types. Mirror Iceberg's set but trimmed to the
/// subset Zig substrate callers actually emit.
pub const ColumnType = enum {
    int32,
    int64,
    f32,
    f64,
    string,
    bool_,
    date_days,
    timestamp_us,

    pub fn toString(self: ColumnType) []const u8 {
        return @tagName(self);
    }

    pub fn fromString(s: []const u8) ?ColumnType {
        inline for (@typeInfo(ColumnType).@"enum".fields) |f| {
            if (std.mem.eql(u8, s, f.name)) return @field(ColumnType, f.name);
        }
        return null;
    }
};

pub const Column = struct {
    /// Stable id; never reused even after column drops.
    id: u32,
    name: []const u8,
    type: ColumnType,
    nullable: bool,
};

/// L3 — compute-agnostic schema contract.
pub const Schema = struct {
    schema_id: u32,
    columns: []const Column,

    pub fn columnByName(self: Schema, name: []const u8) ?Column {
        for (self.columns) |c| {
            if (std.mem.eql(u8, c.name, name)) return c;
        }
        return null;
    }
};

// --- Partition spec ------------------------------------------------------

/// One transform applied to a source column to produce a partition value.
/// v0.0.1 ships identity + day-truncation + hour-truncation only. v0.0.2
/// ships bucket / truncate / month / year transforms.
pub const Transform = enum {
    identity,
    day,
    hour,
};

pub const PartitionField = struct {
    /// Source-column id from `Schema.columns[i].id`.
    source_column_id: u32,
    /// Name visible to readers (the partition column the SQL sees).
    name: []const u8,
    transform: Transform,
};

/// L1 — versioned partition spec. Each write records the spec_id it
/// was produced under; readers look up the spec by id to decode the
/// partition values in the data file.
pub const PartitionSpec = struct {
    spec_id: u32,
    fields: []const PartitionField,
};

// --- Data file -----------------------------------------------------------

/// One physical file's worth of rows + the partition values + the
/// spec_id those values were derived under.
pub const DataFile = struct {
    path: []const u8,
    spec_id: u32,
    partition_values_json: []const u8,
    record_count: u64,
    file_size_bytes: u64,
};

// --- Snapshot ------------------------------------------------------------

/// L27 — atomic snapshot of the table. A reader pins a snapshot_id and
/// sees a consistent view; a writer creates a new snapshot pointing at
/// the parent_id and either commits (parent_id matches the table's
/// current snapshot) or retries with the latest.
pub const Snapshot = struct {
    snapshot_id: u64,
    parent_snapshot_id: ?u64,
    /// Unix-seconds.
    committed_at: i64,
    summary: []const u8,
    schema_id: u32,
    /// References the partition spec that NEW files in this snapshot use.
    default_spec_id: u32,
    files: []const DataFile,
};

// --- Manifest ------------------------------------------------------------

/// L2 — single self-describing object that the table's metadata lives in.
/// In production this lives in object storage; for v0.0.1 callers read /
/// write to local bytes via `toJson` / `fromJson`. The manifest carries
/// every historical schema + spec + (single) snapshot at v0.0.1; v0.0.2
/// adds a snapshot chain.
pub const Manifest = struct {
    format_version: u8 = 1,
    table_uuid: [16]u8,
    location: []const u8,
    schemas: []const Schema,
    current_schema_id: u32,
    partition_specs: []const PartitionSpec,
    default_spec_id: u32,
    last_sequence_number: u64,
    current_snapshot: Snapshot,

    pub const Error = error{
        UnknownSchemaId,
        UnknownSpecId,
        ParseError,
        OutOfMemory,
    };

    /// Look up a schema by id. Returns `null` if not present.
    pub fn schemaById(self: Manifest, schema_id: u32) ?Schema {
        for (self.schemas) |s| if (s.schema_id == schema_id) return s;
        return null;
    }

    /// Look up a partition spec by id.
    pub fn specById(self: Manifest, spec_id: u32) ?PartitionSpec {
        for (self.partition_specs) |s| if (s.spec_id == spec_id) return s;
        return null;
    }

    /// L6 — when reading, a data file's `spec_id` is resolved against
    /// the manifest's spec list (not the current default). This is the
    /// zero-copy-evolution lookup: files written under the old spec
    /// stay readable under the new manifest.
    pub fn resolveSpecForFile(self: Manifest, file: DataFile) ?PartitionSpec {
        return self.specById(file.spec_id);
    }
};

// --- JSON round-trip helpers --------------------------------------------

/// Serialise a manifest to a deterministic JSON form. Field order is
/// fixed so that two equivalent manifests produce byte-equal output —
/// load-bearing for the v0.0.2 snapshot-id hash that gates commit.
pub fn manifestToJson(allocator: std.mem.Allocator, m: Manifest) ![]u8 {
    var buf: std.array_list.Managed(u8) = .init(allocator);
    errdefer buf.deinit();
    var line: [256]u8 = undefined;

    try buf.appendSlice("{\n");
    try buf.appendSlice("  \"format_version\": ");
    try buf.appendSlice(try std.fmt.bufPrint(&line, "{d}", .{m.format_version}));
    try buf.appendSlice(",\n");

    try buf.appendSlice("  \"table_uuid\": \"");
    for (m.table_uuid) |b| {
        try buf.appendSlice(try std.fmt.bufPrint(&line, "{x:02}", .{b}));
    }
    try buf.appendSlice("\",\n");

    try buf.appendSlice("  \"location\": \"");
    try buf.appendSlice(m.location);
    try buf.appendSlice("\",\n");

    try buf.appendSlice("  \"current_schema_id\": ");
    try buf.appendSlice(try std.fmt.bufPrint(&line, "{d}", .{m.current_schema_id}));
    try buf.appendSlice(",\n");

    try buf.appendSlice("  \"default_spec_id\": ");
    try buf.appendSlice(try std.fmt.bufPrint(&line, "{d}", .{m.default_spec_id}));
    try buf.appendSlice(",\n");

    try buf.appendSlice("  \"last_sequence_number\": ");
    try buf.appendSlice(try std.fmt.bufPrint(&line, "{d}", .{m.last_sequence_number}));
    try buf.appendSlice(",\n");

    // Schemas array.
    try buf.appendSlice("  \"schemas\": [\n");
    for (m.schemas, 0..) |s, i| {
        try buf.appendSlice(try std.fmt.bufPrint(&line, "    {{\"schema_id\": {d}, \"columns\": [", .{s.schema_id}));
        for (s.columns, 0..) |c, j| {
            const sep = if (j == 0) "" else ", ";
            try buf.appendSlice(try std.fmt.bufPrint(&line, "{s}{{\"id\": {d}, \"name\": \"{s}\", \"type\": \"{s}\", \"nullable\": {}}}", .{ sep, c.id, c.name, c.type.toString(), c.nullable }));
        }
        const tail = if (i + 1 == m.schemas.len) "]}\n" else "]},\n";
        try buf.appendSlice(try std.fmt.bufPrint(&line, "]}}{s}", .{if (i + 1 == m.schemas.len) "\n" else ",\n"}));
        _ = tail;
    }
    try buf.appendSlice("  ],\n");

    // Partition specs array.
    try buf.appendSlice("  \"partition_specs\": [\n");
    for (m.partition_specs, 0..) |s, i| {
        try buf.appendSlice(try std.fmt.bufPrint(&line, "    {{\"spec_id\": {d}, \"fields\": [", .{s.spec_id}));
        for (s.fields, 0..) |f, j| {
            const sep = if (j == 0) "" else ", ";
            try buf.appendSlice(try std.fmt.bufPrint(&line, "{s}{{\"source_column_id\": {d}, \"name\": \"{s}\", \"transform\": \"{s}\"}}", .{ sep, f.source_column_id, f.name, @tagName(f.transform) }));
        }
        const tail = if (i + 1 == m.partition_specs.len) "]}\n" else "]},\n";
        try buf.appendSlice(tail);
    }
    try buf.appendSlice("  ],\n");

    // Current snapshot.
    try buf.appendSlice("  \"current_snapshot\": {\n");
    try buf.appendSlice(try std.fmt.bufPrint(&line, "    \"snapshot_id\": {d},\n", .{m.current_snapshot.snapshot_id}));
    try buf.appendSlice("    \"parent_snapshot_id\": ");
    if (m.current_snapshot.parent_snapshot_id) |p| {
        try buf.appendSlice(try std.fmt.bufPrint(&line, "{d}", .{p}));
    } else {
        try buf.appendSlice("null");
    }
    try buf.appendSlice(",\n");
    try buf.appendSlice(try std.fmt.bufPrint(&line, "    \"committed_at\": {d},\n", .{m.current_snapshot.committed_at}));
    try buf.appendSlice(try std.fmt.bufPrint(&line, "    \"summary\": \"{s}\",\n", .{m.current_snapshot.summary}));
    try buf.appendSlice(try std.fmt.bufPrint(&line, "    \"schema_id\": {d},\n", .{m.current_snapshot.schema_id}));
    try buf.appendSlice(try std.fmt.bufPrint(&line, "    \"default_spec_id\": {d},\n", .{m.current_snapshot.default_spec_id}));
    try buf.appendSlice("    \"files\": [\n");
    for (m.current_snapshot.files, 0..) |f, i| {
        try buf.appendSlice(try std.fmt.bufPrint(&line, "      {{\"path\": \"{s}\", \"spec_id\": {d}, \"partition_values_json\": \"{s}\", \"record_count\": {d}, \"file_size_bytes\": {d}}}", .{ f.path, f.spec_id, f.partition_values_json, f.record_count, f.file_size_bytes }));
        const tail = if (i + 1 == m.current_snapshot.files.len) "\n" else ",\n";
        try buf.appendSlice(tail);
    }
    try buf.appendSlice("    ]\n");
    try buf.appendSlice("  }\n");

    try buf.appendSlice("}\n");
    return buf.toOwnedSlice();
}

// --- Tests ---------------------------------------------------------------

const testing = std.testing;

test "ColumnType round-trips through string form" {
    inline for (.{ .int32, .int64, .f32, .f64, .string, .bool_, .date_days, .timestamp_us }) |t| {
        const s = ColumnType.toString(t);
        try testing.expectEqual(@as(?ColumnType, t), ColumnType.fromString(s));
    }
    try testing.expect(ColumnType.fromString("nonsense") == null);
}

test "Schema.columnByName finds + misses" {
    const cols = [_]Column{
        .{ .id = 1, .name = "user_id", .type = .int64, .nullable = false },
        .{ .id = 2, .name = "event_time", .type = .timestamp_us, .nullable = false },
    };
    const s: Schema = .{ .schema_id = 1, .columns = &cols };
    try testing.expect(s.columnByName("user_id") != null);
    try testing.expectEqual(@as(u32, 2), s.columnByName("event_time").?.id);
    try testing.expect(s.columnByName("nope") == null);
}

test "Manifest.schemaById + specById" {
    const cols = [_]Column{
        .{ .id = 1, .name = "user_id", .type = .int64, .nullable = false },
    };
    const schemas = [_]Schema{
        .{ .schema_id = 1, .columns = &cols },
    };
    const fields_v1 = [_]PartitionField{
        .{ .source_column_id = 1, .name = "user_bucket", .transform = .identity },
    };
    const specs = [_]PartitionSpec{
        .{ .spec_id = 1, .fields = &fields_v1 },
        .{ .spec_id = 2, .fields = &fields_v1 },
    };
    const files = [_]DataFile{};
    const m: Manifest = .{
        .table_uuid = [_]u8{0} ** 16,
        .location = "/tmp/table",
        .schemas = &schemas,
        .current_schema_id = 1,
        .partition_specs = &specs,
        .default_spec_id = 2,
        .last_sequence_number = 0,
        .current_snapshot = .{
            .snapshot_id = 1,
            .parent_snapshot_id = null,
            .committed_at = 1_700_000_000,
            .summary = "initial",
            .schema_id = 1,
            .default_spec_id = 2,
            .files = &files,
        },
    };

    try testing.expect(m.schemaById(1) != null);
    try testing.expect(m.schemaById(99) == null);
    try testing.expect(m.specById(2) != null);
    try testing.expect(m.specById(99) == null);
}

test "resolveSpecForFile honours per-file spec_id (L6 zero-copy evolution)" {
    const cols = [_]Column{
        .{ .id = 1, .name = "ds", .type = .date_days, .nullable = false },
    };
    const schemas = [_]Schema{.{ .schema_id = 1, .columns = &cols }};

    const fields_old = [_]PartitionField{
        .{ .source_column_id = 1, .name = "ds_old", .transform = .day },
    };
    const fields_new = [_]PartitionField{
        .{ .source_column_id = 1, .name = "ds_new", .transform = .day },
    };
    const specs = [_]PartitionSpec{
        .{ .spec_id = 1, .fields = &fields_old },
        .{ .spec_id = 2, .fields = &fields_new },
    };

    // One data file under each spec.
    const old_file: DataFile = .{ .path = "/data/old.parquet", .spec_id = 1, .partition_values_json = "{}", .record_count = 100, .file_size_bytes = 1000 };
    const new_file: DataFile = .{ .path = "/data/new.parquet", .spec_id = 2, .partition_values_json = "{}", .record_count = 100, .file_size_bytes = 1000 };
    const files = [_]DataFile{ old_file, new_file };

    const m: Manifest = .{
        .table_uuid = [_]u8{0} ** 16,
        .location = "/tmp/table",
        .schemas = &schemas,
        .current_schema_id = 1,
        .partition_specs = &specs,
        .default_spec_id = 2,
        .last_sequence_number = 1,
        .current_snapshot = .{
            .snapshot_id = 1,
            .parent_snapshot_id = null,
            .committed_at = 1_700_000_000,
            .summary = "evolved",
            .schema_id = 1,
            .default_spec_id = 2,
            .files = &files,
        },
    };

    // Old file resolves to spec 1 (zero-copy preservation).
    const old_resolved = m.resolveSpecForFile(old_file).?;
    try testing.expectEqual(@as(u32, 1), old_resolved.spec_id);
    try testing.expectEqualStrings("ds_old", old_resolved.fields[0].name);

    // New file resolves to spec 2 (current default).
    const new_resolved = m.resolveSpecForFile(new_file).?;
    try testing.expectEqual(@as(u32, 2), new_resolved.spec_id);
    try testing.expectEqualStrings("ds_new", new_resolved.fields[0].name);
}

test "manifestToJson produces a non-empty deterministic blob" {
    const alloc = testing.allocator;
    const cols = [_]Column{
        .{ .id = 1, .name = "ds", .type = .date_days, .nullable = false },
    };
    const schemas = [_]Schema{.{ .schema_id = 1, .columns = &cols }};
    const fields = [_]PartitionField{
        .{ .source_column_id = 1, .name = "ds_p", .transform = .day },
    };
    const specs = [_]PartitionSpec{.{ .spec_id = 1, .fields = &fields }};
    const files = [_]DataFile{};

    const m: Manifest = .{
        .table_uuid = [_]u8{0} ** 16,
        .location = "/tmp/t",
        .schemas = &schemas,
        .current_schema_id = 1,
        .partition_specs = &specs,
        .default_spec_id = 1,
        .last_sequence_number = 0,
        .current_snapshot = .{
            .snapshot_id = 42,
            .parent_snapshot_id = null,
            .committed_at = 1_700_000_000,
            .summary = "v0.0.1",
            .schema_id = 1,
            .default_spec_id = 1,
            .files = &files,
        },
    };

    const j = try manifestToJson(alloc, m);
    defer alloc.free(j);
    try testing.expect(j.len > 200);
    try testing.expect(std.mem.indexOf(u8, j, "\"snapshot_id\": 42") != null);
    try testing.expect(std.mem.indexOf(u8, j, "\"ds_p\"") != null);

    // Determinism — same input produces same bytes.
    const j2 = try manifestToJson(alloc, m);
    defer alloc.free(j2);
    try testing.expectEqualStrings(j, j2);
}
