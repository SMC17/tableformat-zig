const spec = @import("spec.zig");

pub const ColumnType = spec.ColumnType;
pub const Column = spec.Column;
pub const Schema = spec.Schema;
pub const Transform = spec.Transform;
pub const PartitionField = spec.PartitionField;
pub const PartitionSpec = spec.PartitionSpec;
pub const DataFile = spec.DataFile;
pub const Snapshot = spec.Snapshot;
pub const Manifest = spec.Manifest;
pub const manifestToJson = spec.manifestToJson;

pub const schema_evolution = @import("schema_evolution.zig");
pub const addColumn = schema_evolution.addColumn;
pub const dropColumn = schema_evolution.dropColumn;
pub const widenType = schema_evolution.widenType;
pub const canWiden = schema_evolution.canWiden;
pub const SchemaEvolutionError = schema_evolution.Error;

test {
    @import("std").testing.refAllDecls(@This());
}
