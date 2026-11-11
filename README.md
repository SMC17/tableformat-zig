# tableformat-zig

Try the [self-contained task](docs/SELF_SERVE.md): `zig build demo`.

[![License: AGPL-3.0-or-later](https://img.shields.io/badge/License-AGPL--3.0--or--later-blue.svg)](LICENSE)
[![Zig](https://img.shields.io/badge/Zig-0.16-orange.svg)](https://ziglang.org/)

Iceberg-class table-format metadata layer in Zig 0.16. Bundles five castle ports into one library:

- **L1 partition-spec versioning** — versioned `PartitionSpec` per write.
- **L2 manifest metastore decoupling** — table metadata as a JSON blob in object storage, no DBMS.
- **L3 compute-agnostic schema contract** — single canonical `Schema` traveling with the manifest.
- **L6 zero-copy partition evolution** — spec migration without data rewrite.
- **L27 snapshot transactions** — atomic snapshot per write; readers see one snapshot or the other.

## Status

**v0.0.1 — 6/6 tests pass on Zig 0.16.** Data shapes (`Schema`, `PartitionSpec`, `DataFile`, `Snapshot`, `Manifest`) + deterministic JSON serialisation + zero-copy partition resolution per file. v0.0.2 ships multi-snapshot chain + the object-store backend + snapshot-id-based commit-or-retry transaction.

## What ships

- `ColumnType` enum (`int32 / int64 / f32 / f64 / string / bool_ / date_days / timestamp_us`) with string round-trip.
- `Column { id, name, type, nullable }` + `Schema { schema_id, columns }` with `columnByName` lookup.
- `Transform { identity, day, hour }` enum + `PartitionField { source_column_id, name, transform }` + `PartitionSpec { spec_id, fields }`.
- `DataFile { path, spec_id, partition_values_json, record_count, file_size_bytes }`.
- `Snapshot { snapshot_id, parent_snapshot_id, committed_at, summary, schema_id, default_spec_id, files }`.
- `Manifest` — single self-describing object with `schemas`, `partition_specs`, `current_snapshot`, lookup helpers (`schemaById`, `specById`, `resolveSpecForFile`).
- `manifestToJson(allocator, manifest)` — deterministic byte-stable JSON serialisation. Two equivalent manifests produce byte-equal output; this is the load-bearing property for v0.0.2's snapshot-id hashing.

## The L6 zero-copy property, tested

The fourth test demonstrates the load-bearing claim. Two `PartitionSpec`s coexist in one manifest (spec_id 1 = `ds_old`, spec_id 2 = `ds_new`). Two data files exist — one from each spec. `Manifest.resolveSpecForFile(old_file)` returns spec 1; `resolveSpecForFile(new_file)` returns spec 2. No data rewrite needed; readers honour the spec each file was written under.

## Build

```sh
zig build test                  # 6 unit tests
```

## What ships does NOT do (yet)

- **No snapshot chain at v0.0.1.** `Manifest.current_snapshot` is the only snapshot. v0.0.2 adds `snapshots: []const Snapshot` + parent-pointer traversal.
- **No object-store backend.** Callers serialise to bytes via `manifestToJson` and write to wherever they want. v0.0.2 ships a path-based store; v0.0.3 ships S3 / R2 / local-FS adapters.
- **No commit-or-retry transaction.** v0.0.2 wires the snapshot-id compare-and-swap on top of the deterministic JSON hash.
- **Only three transforms** (`identity`, `day`, `hour`). v0.0.2 adds `bucket / truncate / month / year`.
- **No JSON `fromJson` parser.** v0.0.1 ships emit-only. v0.0.2 ships the round-trip parser + a property test that round-trips every shape.

## Castle port coverage

This library is the v0.0.1 implementation of P14 (L1 partition-spec versioning) + P15 (L2 manifest metastore decoupling) + P16 (L3 format-schema enforcement) + P17 (L6 zero-copy partition evolution) + P27 (L35 Iceberg snapshot tx). Bundled into one repo per the castle calendar Tier-4 bundle plan.

## Credit

Concepts adapted from Airbnb (Iceberg adoption) + Netflix (Iceberg origin) engineering. Frontier port by Sean Collins (`sean@sunlitmoon.online`).

## License

AGPL-3.0-or-later. See `LICENSE`.
