// A tiny wrapper around Win32's classic `GradientFill` (msimg32.dll) used to
// approximate macOS's `LinearGradient` chrome (tab strip gloss, loop bar, loop
// cards, control gloss) without a GDI+ or Direct2D dependency. `GradientFill`
// has shipped since Windows 98/2000 and is exposed directly through
// `windows.h`/`wingdi.h`, so no manual extern bindings are needed -- it comes
// through the existing `Win32.zig` `c` import once `msimg32` is linked.
//
// Every call gracefully falls back to a flat fill (using the top-stop color)
// if `GradientFill` fails for any reason, so this can never regress or
// destabilize existing rendering -- mirroring `GdiplusAA.zig`'s fallback
// pattern for the same reason.
const std = @import("std");
const c = @import("Win32.zig").c;

/// Win32's `TRIVERTEX`/`GRADIENT_RECT` color channels are `COLOR16` (top byte
/// used, bottom byte zero) rather than plain `u8`, so a COLORREF-style byte
/// must be widened into that 16-bit form.
pub fn channelToColor16(component: u8) u16 {
    return @as(u16, component) << 8;
}

fn vertex(x: i32, y: i32, colorref: u32) c.TRIVERTEX {
    return .{
        .x = x,
        .y = y,
        .Red = channelToColor16(@intCast(colorref & 0xFF)),
        .Green = channelToColor16(@intCast((colorref >> 8) & 0xFF)),
        .Blue = channelToColor16(@intCast((colorref >> 16) & 0xFF)),
        .Alpha = 0,
    };
}

/// Paints `bounds` with a vertical two-stop linear gradient (top -> bottom),
/// approximating a macOS `LinearGradient(startPoint: .top, endPoint: .bottom)`.
/// Falls back to a flat fill of `top_colorref` if `GradientFill` is
/// unavailable or fails (e.g. under a stripped-down remote session).
pub fn fillVertical(hdc: c.HDC, bounds: c.RECT, top_colorref: u32, bottom_colorref: u32) void {
    if (bounds.right <= bounds.left or bounds.bottom <= bounds.top) return;
    var vertices = [2]c.TRIVERTEX{
        vertex(bounds.left, bounds.top, top_colorref),
        vertex(bounds.right, bounds.bottom, bottom_colorref),
    };
    var rect = c.GRADIENT_RECT{ .UpperLeft = 0, .LowerRight = 1 };
    const ok = c.GradientFill(hdc, &vertices, 2, @ptrCast(&rect), 1, c.GRADIENT_FILL_RECT_V) != 0;
    if (ok) return;

    const brush = c.CreateSolidBrush(top_colorref);
    if (brush == null) return;
    defer _ = c.DeleteObject(brush);
    var mutable_bounds = bounds;
    _ = c.FillRect(hdc, &mutable_bounds, brush);
}

test "channelToColor16 widens the top byte and zeroes the bottom" {
    try std.testing.expectEqual(@as(u16, 0xFF00), channelToColor16(0xFF));
    try std.testing.expectEqual(@as(u16, 0x7A00), channelToColor16(0x7A));
    try std.testing.expectEqual(@as(u16, 0x0000), channelToColor16(0x00));
}

test "vertex splits a COLORREF into COLOR16 channels in COLORREF order" {
    // 0x007AB8FF is B=0x7A, G=0xB8, R=0xFF (see GdiplusAA's colorrefToArgb test).
    const v = vertex(10, 20, 0x007AB8FF);
    try std.testing.expectEqual(@as(i32, 10), v.x);
    try std.testing.expectEqual(@as(i32, 20), v.y);
    try std.testing.expectEqual(@as(u16, 0xFF00), v.Red);
    try std.testing.expectEqual(@as(u16, 0xB800), v.Green);
    try std.testing.expectEqual(@as(u16, 0x7A00), v.Blue);
    try std.testing.expectEqual(@as(u16, 0), v.Alpha);
}
