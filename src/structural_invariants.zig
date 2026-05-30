//! structural_invariants: v0.0.8 substrate move from L82 (Fathom drones mine).
//!
//! Carries one shape pulled from the Fathom drones repo on mac into
//! the castle as a working test combinator. The Fathom invariant:
//! the envelope schema has a small set of pinned top-level fields
//! (version, triple, derived) that are structurally fixed across
//! versions; everything customer-specific lives inside `derived`,
//! and `derived` is a typed union extended by impl, never by adding
//! a new top-level field. Adding a defense-customer field at the
//! top would fail Fathom's contract.judge.md review at merge time.
//!
//! Mapped into tableformat: this is a callable test combinator that
//! a caller opts into when they want their schema's first K columns
//! to be structurally pinned. Schema evolution above index K is
//! free; at or below K, the columns and their column ids must match
//! between any two versions.
//!
//! Composition with shipped tableformat:
//!   schema_evolution.addColumn appends a new column at the next
//!     stable id, which sits above any structural prefix.
//!   schema_evolution.dropColumn or widenType against an in-prefix
//!     column would be caught here.
//!   rbac.hasPrivilege(p, .alter, .table) gates the legal mutation
//!     surface; this combinator gates the structural surface.

const std = @import("std");
const spec = @import("spec.zig");

pub const Column = spec.Column;
pub const Schema = spec.Schema;

pub const PrefixViolation = enum(u8) {
    prefix_too_short = 0,
    column_id_changed = 1,
    column_name_changed = 2,
    column_type_changed = 3,
    column_nullable_changed = 4,
};

pub const Error = error{
    StructuralPrefixDrift,
};

pub const ViolationReport = struct {
    index: usize,
    kind: PrefixViolation,
};

/// Walk the first `prefix_len` columns of both schemas. Returns an
/// error if any of (id, name, type, nullable) differs at the same
/// index, or if either schema is shorter than `prefix_len`.
pub fn assertStructuralPrefixStable(
    old: Schema,
    new: Schema,
    prefix_len: usize,
) Error!void {
    _ = try checkStructuralPrefix(old, new, prefix_len);
}

/// Same as `assertStructuralPrefixStable` but returns a structured
/// report on the first violation instead of throwing. The intent is
/// to let callers (e.g. CI gates) print a useful diff.
pub fn checkStructuralPrefix(
    old: Schema,
    new: Schema,
    prefix_len: usize,
) Error!?ViolationReport {
    if (old.columns.len < prefix_len or new.columns.len < prefix_len) {
        return Error.StructuralPrefixDrift;
    }
    var i: usize = 0;
    while (i < prefix_len) : (i += 1) {
        const a = old.columns[i];
        const b = new.columns[i];
        if (a.id != b.id) return Error.StructuralPrefixDrift;
        if (!std.mem.eql(u8, a.name, b.name)) return Error.StructuralPrefixDrift;
        if (a.type != b.type) return Error.StructuralPrefixDrift;
        if (a.nullable != b.nullable) return Error.StructuralPrefixDrift;
    }
    return null;
}

/// Non-throwing inspection: returns the first violation if any,
/// without classifying it as an error. Useful inside higher-level
/// guards.
pub fn firstPrefixViolation(
    old: Schema,
    new: Schema,
    prefix_len: usize,
) ?ViolationReport {
    if (old.columns.len < prefix_len or new.columns.len < prefix_len) {
        return .{ .index = @min(old.columns.len, new.columns.len), .kind = .prefix_too_short };
    }
    var i: usize = 0;
    while (i < prefix_len) : (i += 1) {
        const a = old.columns[i];
        const b = new.columns[i];
        if (a.id != b.id) return .{ .index = i, .kind = .column_id_changed };
        if (!std.mem.eql(u8, a.name, b.name)) return .{ .index = i, .kind = .column_name_changed };
        if (a.type != b.type) return .{ .index = i, .kind = .column_type_changed };
        if (a.nullable != b.nullable) return .{ .index = i, .kind = .column_nullable_changed };
    }
    return null;
}

// --- Tests -----------------------------------------------------------------

const testing = std.testing;
const ColumnType = spec.ColumnType;

fn mkSchema(id: u32, cols: []const Column) Schema {
    return .{ .schema_id = id, .columns = cols };
}

test "stable prefix matches identical schemas" {
    const cols = [_]Column{
        .{ .id = 1, .name = "version", .type = .int32, .nullable = false },
        .{ .id = 2, .name = "triple", .type = .string, .nullable = false },
    };
    const s = mkSchema(1, &cols);
    try assertStructuralPrefixStable(s, s, 2);
}

test "stable prefix tolerates new columns appended above prefix_len" {
    const old_cols = [_]Column{
        .{ .id = 1, .name = "version", .type = .int32, .nullable = false },
        .{ .id = 2, .name = "triple", .type = .string, .nullable = false },
    };
    const new_cols = [_]Column{
        .{ .id = 1, .name = "version", .type = .int32, .nullable = false },
        .{ .id = 2, .name = "triple", .type = .string, .nullable = false },
        .{ .id = 3, .name = "derived_blob", .type = .string, .nullable = true },
    };
    try assertStructuralPrefixStable(mkSchema(1, &old_cols), mkSchema(2, &new_cols), 2);
}

test "stable prefix rejects column id change inside prefix" {
    const old_cols = [_]Column{
        .{ .id = 1, .name = "version", .type = .int32, .nullable = false },
    };
    const new_cols = [_]Column{
        .{ .id = 99, .name = "version", .type = .int32, .nullable = false },
    };
    try testing.expectError(
        Error.StructuralPrefixDrift,
        assertStructuralPrefixStable(mkSchema(1, &old_cols), mkSchema(2, &new_cols), 1),
    );
}

test "stable prefix rejects column rename inside prefix" {
    const old_cols = [_]Column{
        .{ .id = 1, .name = "version", .type = .int32, .nullable = false },
    };
    const new_cols = [_]Column{
        .{ .id = 1, .name = "ver", .type = .int32, .nullable = false },
    };
    try testing.expectError(
        Error.StructuralPrefixDrift,
        assertStructuralPrefixStable(mkSchema(1, &old_cols), mkSchema(2, &new_cols), 1),
    );
}

test "stable prefix rejects column type widen inside prefix" {
    const old_cols = [_]Column{
        .{ .id = 1, .name = "version", .type = .int32, .nullable = false },
    };
    const new_cols = [_]Column{
        .{ .id = 1, .name = "version", .type = .int64, .nullable = false },
    };
    try testing.expectError(
        Error.StructuralPrefixDrift,
        assertStructuralPrefixStable(mkSchema(1, &old_cols), mkSchema(2, &new_cols), 1),
    );
}

test "stable prefix rejects nullable flip inside prefix" {
    const old_cols = [_]Column{
        .{ .id = 1, .name = "version", .type = .int32, .nullable = false },
    };
    const new_cols = [_]Column{
        .{ .id = 1, .name = "version", .type = .int32, .nullable = true },
    };
    try testing.expectError(
        Error.StructuralPrefixDrift,
        assertStructuralPrefixStable(mkSchema(1, &old_cols), mkSchema(2, &new_cols), 1),
    );
}

test "short schema fails the prefix check" {
    const old_cols = [_]Column{
        .{ .id = 1, .name = "version", .type = .int32, .nullable = false },
    };
    const new_cols = [_]Column{};
    try testing.expectError(
        Error.StructuralPrefixDrift,
        assertStructuralPrefixStable(mkSchema(1, &old_cols), mkSchema(2, &new_cols), 1),
    );
}

test "firstPrefixViolation returns null on stable prefix" {
    const cols = [_]Column{
        .{ .id = 1, .name = "version", .type = .int32, .nullable = false },
    };
    try testing.expectEqual(@as(?ViolationReport, null), firstPrefixViolation(mkSchema(1, &cols), mkSchema(2, &cols), 1));
}

test "firstPrefixViolation classifies the kind" {
    const old_cols = [_]Column{
        .{ .id = 1, .name = "version", .type = .int32, .nullable = false },
        .{ .id = 2, .name = "triple", .type = .string, .nullable = false },
    };
    const new_cols = [_]Column{
        .{ .id = 1, .name = "version", .type = .int32, .nullable = false },
        .{ .id = 2, .name = "tuple", .type = .string, .nullable = false },
    };
    const v = firstPrefixViolation(mkSchema(1, &old_cols), mkSchema(2, &new_cols), 2).?;
    try testing.expectEqual(@as(usize, 1), v.index);
    try testing.expectEqual(PrefixViolation.column_name_changed, v.kind);
}

test "firstPrefixViolation flags prefix-too-short" {
    const old_cols = [_]Column{
        .{ .id = 1, .name = "version", .type = .int32, .nullable = false },
    };
    const new_cols = [_]Column{};
    const v = firstPrefixViolation(mkSchema(1, &old_cols), mkSchema(2, &new_cols), 1).?;
    try testing.expectEqual(PrefixViolation.prefix_too_short, v.kind);
}

test "prefix_len of zero is a free pass even on totally different schemas" {
    const a = [_]Column{.{ .id = 1, .name = "x", .type = .int32, .nullable = false }};
    const b = [_]Column{.{ .id = 99, .name = "y", .type = .string, .nullable = true }};
    try assertStructuralPrefixStable(mkSchema(1, &a), mkSchema(2, &b), 0);
}
