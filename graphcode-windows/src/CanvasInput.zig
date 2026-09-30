const std = @import("std");
const c = @import("Win32.zig").c;

pub const WheelMessage = struct {
    point: c.POINT,
    delta: i16,
};

pub const MouseMessage = struct {
    x: i32,
    y: i32,
};

pub fn decodeMouseMessage(lparam: c.LPARAM) MouseMessage {
    const value: usize = @bitCast(lparam);
    return .{ .x = signedWord(value), .y = signedWord(value >> 16) };
}

pub fn decodeWheelMessage(lparam: c.LPARAM, wparam: c.WPARAM) WheelMessage {
    return .{
        .point = .{
            .x = signedWord(@as(usize, @bitCast(lparam))),
            .y = signedWord(@as(usize, @bitCast(lparam)) >> 16),
        },
        .delta = @as(i16, @bitCast(@as(u16, @truncate(@as(usize, @bitCast(wparam)) >> 16)))),
    };
}

pub fn screenToClient(hwnd: c.HWND, point: c.POINT) ?c.POINT {
    return screenToClientWith(hwnd, point, c.ScreenToClient);
}

fn screenToClientWith(hwnd: c.HWND, point: c.POINT, mapper: anytype) ?c.POINT {
    var mapped = point;
    if (mapper(hwnd, &mapped) == 0) return null;
    return mapped;
}

fn signedWord(value: usize) i32 {
    return @as(i32, @as(i16, @bitCast(@as(u16, @truncate(value)))));
}

/// WM_GESTURE dwID values (winuser.h). Mirrored here (rather than pulled from
/// `c`) so this pure decision table can be unit tested without depending on
/// whichever gesture headers happen to be exposed through Win32.zig.
pub const GID_BEGIN: u32 = 1;
pub const GID_END: u32 = 2;
pub const GID_ZOOM: u32 = 3;
pub const GID_PAN: u32 = 4;

/// GESTUREINFO.dwFlags bits relevant to native pan and zoom gesture sequences.
pub const GF_BEGIN: u32 = 0x00000001;
pub const GF_INERTIA: u32 = 0x00000002;
pub const GF_END: u32 = 0x00000004;

pub const GestureDecision = enum {
    /// Not a zoom gesture (GID_BEGIN/GID_END bracket messages, or a gesture
    /// class GESTURECONFIG blocks but the OS still forwards): must be
    /// forwarded so `DefWindowProc`/legacy handling still sees it.
    forward_unhandled,
    /// A GID_PAN or GID_ZOOM message whose location falls outside the canvas:
    /// forwarded rather than acted on, and any in-progress native gesture
    /// state must be reset since the gesture is no longer ours to continue.
    forward_out_of_region,
    /// First GID_ZOOM message inside the canvas: captures the baseline only.
    begin_zoom,
    /// A later GID_ZOOM message inside the canvas: applies the pinch update.
    continue_zoom,
    /// The GID_ZOOM message carrying GF_END (but not GF_BEGIN) inside the
    /// canvas: applies the final update against the already-captured
    /// baseline, then ends the gesture, clearing pinch state for the next
    /// one.
    end_zoom,
    /// A GID_ZOOM message carrying *both* GF_BEGIN and GF_END inside the
    /// canvas (a gesture short enough to be delivered as a single message).
    /// Per the documented contract the first GID_ZOOM message never causes
    /// zooming by itself, so this must establish a fresh baseline and then
    /// immediately clear it -- never apply a continuation against whatever
    /// baseline a *previous*, unrelated gesture happened to leave behind.
    begin_and_end_zoom,
    /// First GID_PAN message inside the canvas: captures the screen-point and
    /// canvas-pan baseline without moving the canvas.
    begin_pan,
    /// A later GID_PAN message inside the canvas, including GF_INERTIA:
    /// applies the message's screen delta from the captured baseline.
    continue_pan,
    /// The GID_PAN message carrying GF_END: applies its final delta and ends
    /// the gesture.
    end_pan,
    /// A GID_PAN message carrying both GF_BEGIN and GF_END establishes and
    /// immediately clears a baseline without applying a stale delta.
    begin_and_end_pan,
};

/// Pure classification of a single WM_GESTURE message. `dw_id` and `flags`
/// come directly from the message's GESTUREINFO; `in_canvas` is the result of
/// mapping GESTUREINFO.ptsLocation to client space (via `screenToClient`) and
/// checking it against the same region bounds `WM_MOUSEWHEEL` already uses.
/// Kept dependency-free so every branch is directly testable without a real
/// HWND or gesture handle.
pub fn classifyGesture(dw_id: u32, flags: u32, in_canvas: bool) GestureDecision {
    const is_zoom = dw_id == GID_ZOOM;
    const is_pan = dw_id == GID_PAN;
    if (!is_zoom and !is_pan) return .forward_unhandled;
    if (!in_canvas) return .forward_out_of_region;
    const is_begin = flags & GF_BEGIN != 0;
    const is_end = flags & GF_END != 0;
    if (is_begin and is_end) return if (is_pan) .begin_and_end_pan else .begin_and_end_zoom;
    if (is_end) return if (is_pan) .end_pan else .end_zoom;
    if (is_begin) return if (is_pan) .begin_pan else .begin_zoom;
    return if (is_pan) .continue_pan else .continue_zoom;
}

test "wheel message decodes negative and positive signed deltas" {
    try std.testing.expectEqual(@as(i16, -120), decodeWheelMessage(0, @as(c.WPARAM, 0xFF880000)).delta);
    try std.testing.expectEqual(@as(i16, 120), decodeWheelMessage(0, @as(c.WPARAM, 0x00780000)).delta);
}

test "screen wheel point preserves non-origin client mapping contract" {
    const screen = c.POINT{ .x = 1320, .y = 760 };
    const mapped = screenToClientWith(null, screen, fakeScreenToClient);
    try std.testing.expect(mapped != null);
    try std.testing.expectEqual(@as(i32, 120), mapped.?.x);
    try std.testing.expectEqual(@as(i32, 120), mapped.?.y);
}

test "mouse message decodes signed client coordinates" {
    const decoded = decodeMouseMessage(@as(c.LPARAM, 0xFFF00020));
    try std.testing.expectEqual(@as(i32, 32), decoded.x);
    try std.testing.expectEqual(@as(i32, -16), decoded.y);
}

fn fakeScreenToClient(hwnd: c.HWND, point: *c.POINT) c.BOOL {
    _ = hwnd;
    point.x -= 1200;
    point.y -= 640;
    return 1;
}

test "classifyGesture forwards generic and unsupported gesture IDs" {
    try std.testing.expectEqual(GestureDecision.forward_unhandled, classifyGesture(GID_BEGIN, GF_BEGIN, true));
    try std.testing.expectEqual(GestureDecision.forward_unhandled, classifyGesture(GID_END, GF_END, true));
    try std.testing.expectEqual(GestureDecision.forward_unhandled, classifyGesture(9, GF_BEGIN, true));
}

test "classifyGesture routes pan begin, updates, and end to pan handling" {
    try std.testing.expectEqual(GestureDecision.begin_pan, classifyGesture(GID_PAN, GF_BEGIN, true));
    try std.testing.expectEqual(GestureDecision.continue_pan, classifyGesture(GID_PAN, 0, true));
    try std.testing.expectEqual(GestureDecision.continue_pan, classifyGesture(GID_PAN, GF_INERTIA, true));
    try std.testing.expectEqual(GestureDecision.end_pan, classifyGesture(GID_PAN, GF_END, true));
    try std.testing.expectEqual(GestureDecision.begin_and_end_pan, classifyGesture(GID_PAN, GF_BEGIN | GF_END, true));
    try std.testing.expectEqual(GestureDecision.forward_out_of_region, classifyGesture(GID_PAN, 0, false));
}

test "classifyGesture treats a generic gesture end as unhandled" {
    try std.testing.expectEqual(GestureDecision.forward_unhandled, classifyGesture(GID_END, GF_END, true));
}

test "classifyGesture forwards zoom messages located outside the canvas" {
    try std.testing.expectEqual(GestureDecision.forward_out_of_region, classifyGesture(GID_ZOOM, GF_BEGIN, false));
    try std.testing.expectEqual(GestureDecision.forward_out_of_region, classifyGesture(GID_ZOOM, 0, false));
}

test "classifyGesture distinguishes begin, continue, and end within the canvas" {
    try std.testing.expectEqual(GestureDecision.begin_zoom, classifyGesture(GID_ZOOM, GF_BEGIN, true));
    try std.testing.expectEqual(GestureDecision.continue_zoom, classifyGesture(GID_ZOOM, 0, true));
    try std.testing.expectEqual(GestureDecision.end_zoom, classifyGesture(GID_ZOOM, GF_END, true));
}

test "classifyGesture gives a combined begin+end single-message gesture its own outcome" {
    // Documented as possible for a very brief gesture. This must NOT map to
    // plain end_zoom: end_zoom's contract is "continue against the already-
    // captured baseline, then clear it", but a message that begins and ends
    // in one shot has no prior baseline of its own to continue -- treating
    // it as end_zoom would let it apply a *different*, stale gesture's
    // leftover baseline. It gets a distinct outcome so the caller establishes
    // a fresh baseline first and applies no zoom delta, exactly matching a
    // real begin-then-end sequence.
    try std.testing.expectEqual(GestureDecision.begin_and_end_zoom, classifyGesture(GID_ZOOM, GF_BEGIN | GF_END, true));
}
