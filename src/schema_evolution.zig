//! schema_evolution — v0.0.2 Iceberg V2-class schema evolution rules.
//!
//! v0.0.1 ships Schema as static (constructed once at manifest time).
//! v0.0.2 ships:
//!
//! - `addColumn`: append a new nullable column at next stable id;
//!   existing data files are still readable (the new column reads
//!   NULL for old rows per Iceberg V2 promote-by-id rules).
//! - `dropColumn`: remove a column by id; existing data files retain
//!   the bytes but readers project around the dropped column.
//! - `widenType`: i32 → i64, f32 → f64, date → timestamp_us (Iceberg
//!   V2 allowed widenings). Caller-supplied compatibility check.
//!
//! Each evolution produces a NEW Schema with a bumped `schema_id`.
//! The OLD schema is retained by the manifest history (callers track
//! the chain). Reading historical data files routes through the
//! schema with matching `schema_id`.
//!
//! Composition: the evolution chain composes with cow-branch-zig
//! v0.0.2 snapshot/restore so a branch can hold its own schema
//! evolution lineage independent of `main`.

const std = @import("std");
const spec = @import("spec.zig");

pub const Column = spec.Column;
pub const ColumnType = spec.ColumnType;
pub const Schema = spec.Schema;

pub const Error = error{
    OutOfMemory,
    ColumnNotFound,
    NameAlreadyExists,
    IncompatibleWidening,
};

/// Append a nullable column at next stable id. Caller supplies the
/// allocator; returned schema's `columns` is heap-owned by the
/// caller (freed via the same allocator).
pub fn addColumn(
    allocator: std.mem.Allocator,
    base: Schema,
    new_name: []const u8,
    new_type: ColumnType,
) Error!Schema {
    // Reject duplicate names.
    for (base.columns) |c| {
        if (std.mem.eql(u8, c.name, new_name)) return Error.NameAlreadyExists;
    }
    // Next stable id: max(existing) + 1.
    var max_id: u32 = 0;
    for (base.columns) |c| {
        if (c.id > max_id) max_id = c.id;
    }

    const new_cols = allocator.alloc(Column, base.columns.len + 1) catch return Error.OutOfMemory;
    for (base.columns, 0..) |c, i| new_cols[i] = c;
    new_cols[base.columns.len] = .{
        .id = max_id + 1,
        .name = new_name,
        .type = new_type,
        .nullable = true,
    };
    return .{ .schema_id = base.schema_id + 1, .columns = new_cols };
}

/// Remove a column by its stable id. Returns the new schema.
pub fn dropColumn(
    allocator: std.mem.Allocator,
    base: Schema,
    drop_id: u32,
) Error!Schema {
    var found = false;
    for (base.columns) |c| if (c.id == drop_id) {
        found = true;
        break;
    };
    if (!found) return Error.ColumnNotFound;

    var keep_count: usize = 0;
    for (base.columns) |c| if (c.id != drop_id) {
        keep_count += 1;
    };
    const new_cols = allocator.alloc(Column, keep_count) catch return Error.OutOfMemory;
    var i: usize = 0;
    for (base.columns) |c| if (c.id != drop_id) {
        new_cols[i] = c;
        i += 1;
    };
    return .{ .schema_id = base.schema_id + 1, .columns = new_cols };
}

/// Iceberg V2 widening rules.
pub fn canWiden(from: ColumnType, to: ColumnType) bool {
    if (from == to) return true;
    return switch (from) {
        .int32 => to == .int64,
        .f32 => to == .f64,
        .date_days => to == .timestamp_us,
        else => false,
    };
}

/// Widen a column's type. Returns a new schema with the widened
/// type. Fails if the widening is not allowed per Iceberg V2.
pub fn widenType(
    allocator: std.mem.Allocator,
    base: Schema,
    column_id: u32,
    new_type: ColumnType,
) Error!Schema {
    var col_idx: ?usize = null;
    for (base.columns, 0..) |c, i| if (c.id == column_id) {
        col_idx = i;
        break;
    };
    const idx = col_idx orelse return Error.ColumnNotFound;
    const existing = base.columns[idx];
    if (!canWiden(existing.type, new_type)) return Error.IncompatibleWidening;

    const new_cols = allocator.alloc(Column, base.columns.len) catch return Error.OutOfMemory;
    for (base.columns, 0..) |c, i| new_cols[i] = c;
    new_cols[idx] = .{
        .id = existing.id,
        .name = existing.name,
        .type = new_type,
        .nullable = existing.nullable,
    };
    return .{ .schema_id = base.schema_id + 1, .columns = new_cols };
}

// --- Tests ----------------------------------------------------------------

const testing = std.testing;

test "addColumn appends with next stable id and bumps schema_id" {
    const alloc = testing.allocator;
    const base_cols = [_]Column{
        .{ .id = 1, .name = "a", .type = .int32, .nullable = false },
        .{ .id = 2, .name = "b", .type = .string, .nullable = false },
    };
    const base: Schema = .{ .schema_id = 10, .columns = &base_cols };
    const evolved = try addColumn(alloc, base, "c", .int64);
    defer alloc.free(evolved.columns);
    try testing.expectEqual(@as(u32, 11), evolved.schema_id);
    try testing.expectEqual(@as(usize, 3), evolved.columns.len);
    try testing.expectEqual(@as(u32, 3), evolved.columns[2].id);
    try testing.expectEqualStrings("c", evolved.columns[2].name);
    try testing.expectEqual(ColumnType.int64, evolved.columns[2].type);
    try testing.expect(evolved.columns[2].nullable);
}

test "addColumn rejects duplicate name" {
    const alloc = testing.allocator;
    const base_cols = [_]Column{
        .{ .id = 1, .name = "a", .type = .int32, .nullable = false },
    };
    const base: Schema = .{ .schema_id = 1, .columns = &base_cols };
    try testing.expectError(Error.NameAlreadyExists, addColumn(alloc, base, "a", .int64));
}

test "dropColumn removes by stable id" {
    const alloc = testing.allocator;
    const base_cols = [_]Column{
        .{ .id = 1, .name = "a", .type = .int32, .nullable = false },
        .{ .id = 2, .name = "b", .type = .string, .nullable = false },
        .{ .id = 3, .name = "c", .type = .int64, .nullable = false },
    };
    const base: Schema = .{ .schema_id = 1, .columns = &base_cols };
    const evolved = try dropColumn(alloc, base, 2);
    defer alloc.free(evolved.columns);
    try testing.expectEqual(@as(u32, 2), evolved.schema_id);
    try testing.expectEqual(@as(usize, 2), evolved.columns.len);
    try testing.expectEqual(@as(u32, 1), evolved.columns[0].id);
    try testing.expectEqual(@as(u32, 3), evolved.columns[1].id);
}

test "dropColumn rejects unknown id" {
    const alloc = testing.allocator;
    const base_cols = [_]Column{.{ .id = 1, .name = "a", .type = .int32, .nullable = false }};
    const base: Schema = .{ .schema_id = 1, .columns = &base_cols };
    try testing.expectError(Error.ColumnNotFound, dropColumn(alloc, base, 99));
}

test "canWiden allows i32 → i64, f32 → f64, date → timestamp" {
    try testing.expect(canWiden(.int32, .int64));
    try testing.expect(canWiden(.f32, .f64));
    try testing.expect(canWiden(.date_days, .timestamp_us));
    try testing.expect(canWiden(.int64, .int64)); // identity
}

test "canWiden rejects narrowing or incompatible" {
    try testing.expect(!canWiden(.int64, .int32));
    try testing.expect(!canWiden(.f64, .f32));
    try testing.expect(!canWiden(.string, .int64));
    try testing.expect(!canWiden(.int32, .f32));
}

test "widenType promotes i32 → i64 in place by id" {
    const alloc = testing.allocator;
    const base_cols = [_]Column{
        .{ .id = 1, .name = "a", .type = .int32, .nullable = false },
        .{ .id = 2, .name = "b", .type = .string, .nullable = false },
    };
    const base: Schema = .{ .schema_id = 1, .columns = &base_cols };
    const evolved = try widenType(alloc, base, 1, .int64);
    defer alloc.free(evolved.columns);
    try testing.expectEqual(@as(u32, 2), evolved.schema_id);
    try testing.expectEqual(ColumnType.int64, evolved.columns[0].type);
    try testing.expectEqual(@as(u32, 1), evolved.columns[0].id); // id stable
}

test "widenType rejects incompatible widening" {
    const alloc = testing.allocator;
    const base_cols = [_]Column{.{ .id = 1, .name = "a", .type = .string, .nullable = false }};
    const base: Schema = .{ .schema_id = 1, .columns = &base_cols };
    try testing.expectError(Error.IncompatibleWidening, widenType(alloc, base, 1, .int64));
}
