const std = @import("std");

pub const base_dpi: u32 = 96;

pub fn normalize(dpi: u32) u32 {
    return if (dpi == 0) base_dpi else dpi;
}

pub fn scale(value: i32, dpi: u32) i32 {
    const normalized = normalize(dpi);
    const scaled = @divTrunc(
        @as(i64, value) * @as(i64, normalized) + @as(i64, base_dpi / 2),
        @as(i64, base_dpi),
    );
    return @intCast(scaled);
}

pub fn unscale(value: i32, dpi: u32) i32 {
    const normalized = normalize(dpi);
    const scaled = @divTrunc(
        @as(i64, value) * @as(i64, base_dpi) + @as(i64, normalized / 2),
        @as(i64, normalized),
    );
    return @intCast(scaled);
}

test "DPI scaling rounds at the native boundary" {
    try std.testing.expectEqual(@as(i32, 100), scale(100, 96));
    try std.testing.expectEqual(@as(i32, 125), scale(100, 120));
    try std.testing.expectEqual(@as(i32, 150), scale(100, 144));
    try std.testing.expectEqual(@as(i32, 100), unscale(125, 120));
}

test "zero DPI falls back to the Windows base DPI" {
    try std.testing.expectEqual(base_dpi, normalize(0));
    try std.testing.expectEqual(@as(i32, 42), scale(42, 0));
}
