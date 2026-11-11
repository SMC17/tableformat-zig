//! Synthetic metadata task: old files retain their own partition specification.
const std = @import("std");
const lib = @import("lib");
pub fn main() !void {
    const specs = [_]lib.PartitionSpec{
        .{ .spec_id = 1, .fields = &.{} },
        .{ .spec_id = 2, .fields = &.{} },
    };
    const files = [_]lib.DataFile{
        .{ .path = "fixture/old", .spec_id = 1, .partition_values_json = "{}", .record_count = 1, .file_size_bytes = 1 },
        .{ .path = "fixture/new", .spec_id = 2, .partition_values_json = "{}", .record_count = 1, .file_size_bytes = 1 },
    };
    const manifest = lib.Manifest{
        .table_uuid = [_]u8{0} ** 16,
        .location = "fixture",
        .schemas = &.{},
        .current_schema_id = 1,
        .partition_specs = &specs,
        .default_spec_id = 2,
        .last_sequence_number = 1,
        .current_snapshot = .{ .snapshot_id = 1, .parent_snapshot_id = null, .committed_at = 0, .summary = "synthetic", .schema_id = 1, .default_spec_id = 2, .files = &files },
    };
    const old = manifest.resolveSpecForFile(files[0]) orelse return error.MissingOldSpec;
    const new = manifest.resolveSpecForFile(files[1]) orelse return error.MissingNewSpec;
    if (old.spec_id != 1 or new.spec_id != 2) return error.SpecMismatch;
    std.debug.print("fixture: old_file_spec=1 new_file_spec=2 no_data_rewrite=true\n", .{});
}
