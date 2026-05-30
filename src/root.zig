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

pub const manifest_entry = @import("manifest_entry.zig");
pub const ManifestEntry = manifest_entry.ManifestEntry;
pub const EntryStatus = manifest_entry.EntryStatus;
pub const ManifestEntryList = manifest_entry.ManifestEntryList;
pub const entriesFromDataFiles = manifest_entry.entriesFromDataFiles;
pub const markDeleted = manifest_entry.markDeleted;

pub const partition_stats = @import("partition_stats.zig");
pub const ColumnStats = partition_stats.ColumnStats;
pub const FileStats = partition_stats.FileStats;
pub const RangeOverlap = partition_stats.RangeOverlap;
pub const pruneFileByRange = partition_stats.pruneFileByRange;
pub const pruneFileByEquality = partition_stats.pruneFileByEquality;

pub const manifest_rewrite = @import("manifest_rewrite.zig");
pub const RewritePolicy = manifest_rewrite.RewritePolicy;
pub const RewriteResult = manifest_rewrite.RewriteResult;
pub const rewriteSmallLists = manifest_rewrite.rewriteSmallLists;
pub const filterActive = manifest_rewrite.filterActive;

pub const puffin = @import("puffin.zig");
pub const PuffinBlob = puffin.Blob;
pub const PuffinBlobType = puffin.BlobType;
pub const PuffinReadResult = puffin.ReadResult;
pub const writePuffin = puffin.write;
pub const readPuffin = puffin.read;
pub const puffin_magic = puffin.magic;

pub const rbac = @import("rbac.zig");
pub const Rbac = rbac.Rbac;
pub const Privilege = rbac.Privilege;
pub const Securable = rbac.Securable;
pub const Grant = rbac.Grant;
pub const PrincipalId = rbac.PrincipalId;
pub const PrincipalRoleId = rbac.PrincipalRoleId;
pub const CatalogRoleId = rbac.CatalogRoleId;

pub const structural_invariants = @import("structural_invariants.zig");
pub const assertStructuralPrefixStable = structural_invariants.assertStructuralPrefixStable;
pub const checkStructuralPrefix = structural_invariants.checkStructuralPrefix;
pub const firstPrefixViolation = structural_invariants.firstPrefixViolation;
pub const PrefixViolation = structural_invariants.PrefixViolation;
pub const ViolationReport = structural_invariants.ViolationReport;

pub const staggered_grid = @import("staggered_grid.zig");
pub const GridDims = staggered_grid.GridDims;
pub const GridAxis = staggered_grid.Axis;
pub const gridSlabLen = staggered_grid.slabLen;
pub const gridIdx = staggered_grid.idx;
pub const gridAxisStride = staggered_grid.axisStride;
pub const gridInDomain = staggered_grid.inDomain;

pub const glyph_ramp = @import("glyph_ramp.zig");
pub const GlyphRamp = glyph_ramp.Ramp;
pub const DEFAULT_UTF8_GLYPH_RAMP = glyph_ramp.DEFAULT_UTF8_RAMP;
pub const DEFAULT_ASCII_GLYPH_RAMP = glyph_ramp.DEFAULT_ASCII_RAMP;
pub const glyphIndex = glyph_ramp.glyphIndex;
pub const glyphFor = glyph_ramp.glyphFor;

pub const column_histogram = @import("column_histogram.zig");
pub const ColumnHistogram = column_histogram.ColumnHistogram;
pub const ColumnHistogramError = column_histogram.Error;

test {
    @import("std").testing.refAllDecls(@This());
}
