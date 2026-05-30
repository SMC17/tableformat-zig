//! glyph_ramp: v0.0.10 substrate from L115 Aletheia zviz.
//!
//! zviz ships terminal-renderable visualization for Aletheia
//! field data. The reusable shape underneath every renderer is
//! a value-to-glyph-index mapping over an ordered ramp:
//!
//!   index = floor((value - lo) / (hi - lo) * steps)
//!
//! with non-finite clamping and bounds-snapping. The canonical
//! default ramp is the 14-codepoint UTF-8 block ramp
//! ` .,-+*▁▂▃▄▅▆▇█`; the ASCII fallback ramp is the 7-character
//! ` .,-+*#`. The ramps are separate so the caller picks based
//! on terminal capability.
//!
//! Port as a tableformat substrate primitive. Pairs with the
//! existing column-store layout: a renderer composes through
//! glyphIndex + the caller-chosen ramp without rediscovering
//! the formula or the non-finite handling.
//!
//! Scope of this revision:
//!   Ramp = []const []const u8 (slice of caller-owned glyph
//!     strings; each may be multi-byte UTF-8).
//!   DEFAULT_UTF8_RAMP: 14-codepoint UTF-8 block ramp.
//!   DEFAULT_ASCII_RAMP: 7-character ASCII fallback ramp.
//!   glyphIndex(value, lo, hi, ramp_len) returns the index into
//!     a ramp of length ramp_len. Caller composes with the ramp
//!     of choice.
//!   glyphFor(value, lo, hi, ramp) returns the chosen glyph
//!     string slice.
//!   isNonFinite(value) returns true for inf, -inf, or nan.
//!
//! Out of scope: terminal-writing (caller composes
//! std.Io.Writer at the boundary), color/ANSI escape codes,
//! axis-label formatting (the zviz `y00`/`y01` convention is
//! out of scope and would go in a separate primitive).

const std = @import("std");

pub const Ramp = []const []const u8;

pub const DEFAULT_UTF8_RAMP: Ramp = &[_][]const u8{
    " ",
    ".",
    ",",
    "-",
    "+",
    "*",
    "\u{2581}", // lower one eighth block
    "\u{2582}", // lower one quarter block
    "\u{2583}", // lower three eighths block
    "\u{2584}", // lower half block
    "\u{2585}", // lower five eighths block
    "\u{2586}", // lower three quarters block
    "\u{2587}", // lower seven eighths block
    "\u{2588}", // full block
};

pub const DEFAULT_ASCII_RAMP: Ramp = &[_][]const u8{
    " ", ".", ",", "-", "+", "*", "#",
};

pub fn isNonFinite(value: f64) bool {
    return std.math.isNan(value) or std.math.isInf(value);
}

/// Map value in [lo, hi] to an index into a ramp of length
/// ramp_len. Clamps: non-finite -> 0, value < lo -> 0, value >
/// hi -> ramp_len - 1, lo >= hi -> 0 (degenerate range).
pub fn glyphIndex(value: f64, lo: f64, hi: f64, ramp_len: usize) usize {
    if (ramp_len == 0) return 0;
    if (isNonFinite(value) or isNonFinite(lo) or isNonFinite(hi)) return 0;
    if (lo >= hi) return 0;
    if (value <= lo) return 0;
    if (value >= hi) return ramp_len - 1;
    const t: f64 = (value - lo) / (hi - lo);
    const idx_f: f64 = t * @as(f64, @floatFromInt(ramp_len));
    var idx: usize = @intFromFloat(idx_f);
    if (idx >= ramp_len) idx = ramp_len - 1;
    return idx;
}

/// Convenience: glyphIndex + ramp lookup. Returns "" for an
/// empty ramp.
pub fn glyphFor(value: f64, lo: f64, hi: f64, ramp: Ramp) []const u8 {
    if (ramp.len == 0) return "";
    return ramp[glyphIndex(value, lo, hi, ramp.len)];
}

// --- Tests -----------------------------------------------------------------

const testing = std.testing;

test "DEFAULT_UTF8_RAMP has 14 glyphs" {
    try testing.expectEqual(@as(usize, 14), DEFAULT_UTF8_RAMP.len);
}

test "DEFAULT_ASCII_RAMP has 7 glyphs" {
    try testing.expectEqual(@as(usize, 7), DEFAULT_ASCII_RAMP.len);
}

test "isNonFinite catches inf, -inf, nan" {
    try testing.expect(isNonFinite(std.math.inf(f64)));
    try testing.expect(isNonFinite(-std.math.inf(f64)));
    try testing.expect(isNonFinite(std.math.nan(f64)));
    try testing.expect(!isNonFinite(0.0));
    try testing.expect(!isNonFinite(1e300));
}

test "glyphIndex at lo is 0" {
    try testing.expectEqual(@as(usize, 0), glyphIndex(0.0, 0.0, 10.0, 10));
}

test "glyphIndex at hi is ramp_len - 1" {
    try testing.expectEqual(@as(usize, 9), glyphIndex(10.0, 0.0, 10.0, 10));
}

test "glyphIndex midpoint is around half" {
    const idx = glyphIndex(5.0, 0.0, 10.0, 10);
    try testing.expect(idx >= 4 and idx <= 5);
}

test "glyphIndex below lo clamps to 0" {
    try testing.expectEqual(@as(usize, 0), glyphIndex(-1.0, 0.0, 10.0, 10));
}

test "glyphIndex above hi clamps to ramp_len - 1" {
    try testing.expectEqual(@as(usize, 9), glyphIndex(99.0, 0.0, 10.0, 10));
}

test "glyphIndex of non-finite value returns 0" {
    try testing.expectEqual(@as(usize, 0), glyphIndex(std.math.nan(f64), 0.0, 10.0, 10));
    try testing.expectEqual(@as(usize, 0), glyphIndex(std.math.inf(f64), 0.0, 10.0, 10));
}

test "glyphIndex with degenerate lo >= hi returns 0" {
    try testing.expectEqual(@as(usize, 0), glyphIndex(5.0, 10.0, 10.0, 10));
    try testing.expectEqual(@as(usize, 0), glyphIndex(5.0, 10.0, 5.0, 10));
}

test "glyphIndex with ramp_len 0 returns 0" {
    try testing.expectEqual(@as(usize, 0), glyphIndex(5.0, 0.0, 10.0, 0));
}

test "glyphFor returns the empty string for an empty ramp" {
    try testing.expectEqualStrings("", glyphFor(5.0, 0.0, 10.0, &.{}));
}

test "glyphFor maps a ramp lookup correctly" {
    try testing.expectEqualStrings(" ", glyphFor(0.0, 0.0, 10.0, DEFAULT_ASCII_RAMP));
    try testing.expectEqualStrings("#", glyphFor(10.0, 0.0, 10.0, DEFAULT_ASCII_RAMP));
}

test "L115 zviz-style: render a five-value scalar field to ASCII glyphs" {
    const values = [_]f64{ 0.0, 2.5, 5.0, 7.5, 10.0 };
    var i: usize = 0;
    while (i < values.len) : (i += 1) {
        const g = glyphFor(values[i], 0.0, 10.0, DEFAULT_ASCII_RAMP);
        try testing.expect(g.len >= 1);
    }
    try testing.expectEqualStrings(" ", glyphFor(values[0], 0.0, 10.0, DEFAULT_ASCII_RAMP));
    try testing.expectEqualStrings("#", glyphFor(values[4], 0.0, 10.0, DEFAULT_ASCII_RAMP));
}
