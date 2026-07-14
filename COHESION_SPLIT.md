# Cohesion split — tableformat-zig

This library is a **table-format** implementation. Per the SMC17 architecture
audit (`cohesion_split_plan.csv`), the following modules were orphaned (zero
table-format-core importers) and have been **extracted into standalone,
dependency-free packages**:

| Removed from tableformat-zig | New repo |
|---|---|
| `rbac.zig` | SMC17/policy-auth-zig |
| `staggered_grid.zig` | SMC17/structured-grid-zig |
| `glyph_ramp.zig` | SMC17/terminal-ramp-zig |
| `row_iterator.zig` | SMC17/column-iter-zig |
| `price_time_buffer.zig` | SMC17/order-primitives-zig |
| `column_histogram.zig`, `histogram_quantile.zig` | SMC17/streaming-stats-zig |
| `tableformat_persistence.zig`, `tableformat_rowgroup.zig` (bridge) | moved in from workflow-event-log-zig (they import the `tableformat` module natively) |

Verification: after extraction `zig build test` passes (52/52). The data-quality
/ table-format API is now free of RBAC / grid / ramp / order / stats baggage.

Downstream consumers referencing `tableformat.rbac*` / `tableformat.GridDims` etc.
should repoint at the new packages.
