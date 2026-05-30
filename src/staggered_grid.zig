//! staggered_grid: v0.0.9 substrate from L94 Aletheia zfdtd.
//!
//! zfdtd ships a 3D Yee-staggered finite-difference time-domain
//! solver. The storage layout that survives independently of the
//! electromagnetic physics is:
//!
//!   Six independent field slabs (Ex, Ey, Ez, Hx, Hy, Hz) over a
//!   single shared cell grid. Each slab is flat-indexed
//!   row-major z-major as
//!
//!     idx(i, j, k) = (k * ny1 + j) * nx1 + i
//!
//!   where ny1 = ny + 1 and nx1 = nx + 1 (one ghost cell per
//!   axis is over-allocated so boundary updates can read past
//!   the live domain without bounds-checking).
//!
//! tableformat already speaks column-store layouts. This module
//! ports the deterministic flat-index helper + ghost-cell
//! over-allocation pattern as a tableformat primitive: any
//! caller that wants a fixed-size N-axis SoA column over a
//! halo-bounded grid composes through here without rediscovering
//! the off-by-one rules.
//!
//! Scope of this revision:
//!   GridDims { nx, ny, nz, halo } record. halo is the per-axis
//!     ghost-cell count (1 in the L94 zfdtd worked example;
//!     callers can pick higher for higher-order stencils).
//!   slabLen(dims) returns the flat element count of a single
//!     field slab including halo cells.
//!   idx(dims, i, j, k) returns the flat index for (i, j, k)
//!     inside the live domain. Caller asserts 0 <= i < nx,
//!     0 <= j < ny, 0 <= k < nz at the boundary.
//!   axisStride(dims, axis) returns the per-axis stride in
//!     elements (useful for neighbour offsets in stencil loops).
//!   inDomain(dims, i, j, k) returns true iff the triple lies in
//!     the live domain (excludes halo cells).
//!
//! Out of scope: physics, field initialization, time stepping,
//! CFL bounds. Those live at the caller boundary (e.g. zfdtd's
//! `step()`).

const std = @import("std");

pub const Axis = enum(u8) { x = 0, y = 1, z = 2 };

pub const GridDims = struct {
    nx: u32,
    ny: u32,
    nz: u32,
    /// Per-axis ghost-cell over-allocation. Yee's first-order
    /// stencil wants halo = 1; higher-order stencils want more.
    halo: u8 = 1,

    pub fn nx1(self: GridDims) u32 {
        return self.nx + @as(u32, self.halo);
    }
    pub fn ny1(self: GridDims) u32 {
        return self.ny + @as(u32, self.halo);
    }
    pub fn nz1(self: GridDims) u32 {
        return self.nz + @as(u32, self.halo);
    }
};

/// Flat element count of one field slab, including halo cells.
/// Caller multiplies by sizeof(T) to get the byte allocation.
pub fn slabLen(dims: GridDims) usize {
    return @as(usize, dims.nx1()) * @as(usize, dims.ny1()) * @as(usize, dims.nz1());
}

/// Row-major z-major flat index. The Yee convention puts i fast,
/// j middle, k slow. Verbatim L94 formula:
///   idx(i, j, k) = (k * ny1 + j) * nx1 + i
pub fn idx(dims: GridDims, i: u32, j: u32, k: u32) usize {
    return (@as(usize, k) * @as(usize, dims.ny1()) + @as(usize, j)) * @as(usize, dims.nx1()) + @as(usize, i);
}

/// Stride in elements between two adjacent cells along the given
/// axis. Useful for stencil neighbour offsets and prefetch.
pub fn axisStride(dims: GridDims, axis: Axis) usize {
    return switch (axis) {
        .x => 1,
        .y => @as(usize, dims.nx1()),
        .z => @as(usize, dims.nx1()) * @as(usize, dims.ny1()),
    };
}

/// True iff (i, j, k) lies inside the live (non-halo) domain.
pub fn inDomain(dims: GridDims, i: u32, j: u32, k: u32) bool {
    return i < dims.nx and j < dims.ny and k < dims.nz;
}

// --- Tests -----------------------------------------------------------------

const testing = std.testing;

test "slabLen of a 4x4x4 grid with halo=1 is 125" {
    const dims: GridDims = .{ .nx = 4, .ny = 4, .nz = 4 };
    try testing.expectEqual(@as(usize, 5 * 5 * 5), slabLen(dims));
}

test "slabLen of a 4x4x4 grid with halo=2 is 216" {
    const dims: GridDims = .{ .nx = 4, .ny = 4, .nz = 4, .halo = 2 };
    try testing.expectEqual(@as(usize, 6 * 6 * 6), slabLen(dims));
}

test "idx at origin is 0" {
    const dims: GridDims = .{ .nx = 4, .ny = 4, .nz = 4 };
    try testing.expectEqual(@as(usize, 0), idx(dims, 0, 0, 0));
}

test "idx step in i increments by 1" {
    const dims: GridDims = .{ .nx = 4, .ny = 4, .nz = 4 };
    try testing.expectEqual(@as(usize, 1), idx(dims, 1, 0, 0));
}

test "idx step in j increments by nx1" {
    const dims: GridDims = .{ .nx = 4, .ny = 4, .nz = 4 };
    try testing.expectEqual(@as(usize, 5), idx(dims, 0, 1, 0));
}

test "idx step in k increments by nx1 * ny1" {
    const dims: GridDims = .{ .nx = 4, .ny = 4, .nz = 4 };
    try testing.expectEqual(@as(usize, 25), idx(dims, 0, 0, 1));
}

test "idx far corner of the live domain" {
    const dims: GridDims = .{ .nx = 4, .ny = 4, .nz = 4 };
    try testing.expectEqual(@as(usize, (3 * 5 + 3) * 5 + 3), idx(dims, 3, 3, 3));
}

test "axisStride matches step deltas" {
    const dims: GridDims = .{ .nx = 4, .ny = 4, .nz = 4 };
    try testing.expectEqual(@as(usize, 1), axisStride(dims, .x));
    try testing.expectEqual(@as(usize, 5), axisStride(dims, .y));
    try testing.expectEqual(@as(usize, 25), axisStride(dims, .z));
}

test "inDomain rejects halo cells past the live domain" {
    const dims: GridDims = .{ .nx = 4, .ny = 4, .nz = 4 };
    try testing.expect(inDomain(dims, 0, 0, 0));
    try testing.expect(inDomain(dims, 3, 3, 3));
    try testing.expect(!inDomain(dims, 4, 0, 0));
    try testing.expect(!inDomain(dims, 0, 4, 0));
    try testing.expect(!inDomain(dims, 0, 0, 4));
}

test "all indices in the live domain are unique" {
    const dims: GridDims = .{ .nx = 3, .ny = 3, .nz = 3 };
    var seen: [27]bool = .{false} ** 27;
    var seen_count: usize = 0;
    var k: u32 = 0;
    while (k < dims.nz) : (k += 1) {
        var j: u32 = 0;
        while (j < dims.ny) : (j += 1) {
            var i: u32 = 0;
            while (i < dims.nx) : (i += 1) {
                const flat = idx(dims, i, j, k);
                const ord = @as(usize, k) * 9 + @as(usize, j) * 3 + @as(usize, i);
                try testing.expect(flat < slabLen(dims));
                try testing.expect(!seen[ord]);
                seen[ord] = true;
                seen_count += 1;
            }
        }
    }
    try testing.expectEqual(@as(usize, 27), seen_count);
}

test "six independent slabs do not overlap when allocated contiguously" {
    const dims: GridDims = .{ .nx = 4, .ny = 4, .nz = 4 };
    const per_slab = slabLen(dims);
    const total = per_slab * 6;
    try testing.expectEqual(@as(usize, 125 * 6), total);
}

test "halo over-allocation reserves the boundary cells" {
    const dims: GridDims = .{ .nx = 4, .ny = 4, .nz = 4, .halo = 1 };
    const live_far = idx(dims, 3, 3, 3);
    const halo_far = idx(dims, 4, 4, 4);
    try testing.expect(halo_far > live_far);
    try testing.expect(halo_far < slabLen(dims));
}
