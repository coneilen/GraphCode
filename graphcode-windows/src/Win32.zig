pub const c = @cImport({
    @cDefine("_WIN32_WINNT", "0x0601");
    @cInclude("windows.h");
    @cInclude("shellapi.h");
    @cInclude("winhttp.h");
    @cInclude("sddl.h");
    @cInclude("winghostty/win32_host.h");
});

/// Win32 uses pointer-shaped types for opaque handles, integer resource IDs,
/// and addresses carried through message integers. Those values do not carry
/// Zig pointer-alignment guarantees.
pub fn opaquePointerFromInt(comptime Pointer: type, value: usize) Pointer {
    @setRuntimeSafety(false);
    return @ptrFromInt(value);
}

pub fn messagePointer(comptime Pointer: type, value: c.LPARAM) Pointer {
    return opaquePointerFromInt(Pointer, @as(usize, @bitCast(value)));
}

pub fn resourceIdentifier(value: usize) [*:0]const u16 {
    return opaquePointerFromInt([*:0]const u16, value);
}

test "Win32 pointer-shaped integers tolerate unaligned values" {
    const std = @import("std");
    const unaligned: usize = 0x0002_0311;
    const odd: usize = 0x000b_0b0b;

    try std.testing.expectEqual(unaligned, @intFromPtr(opaquePointerFromInt(c.HANDLE, unaligned)));
    try std.testing.expectEqual(odd, @intFromPtr(opaquePointerFromInt(c.HMENU, odd)));
    try std.testing.expectEqual(
        unaligned,
        @intFromPtr(messagePointer(*const c.RECT, @as(c.LPARAM, @bitCast(unaligned)))),
    );
    try std.testing.expectEqual(
        odd,
        @intFromPtr(messagePointer(*const c.CREATESTRUCTW, @as(c.LPARAM, @bitCast(odd)))),
    );
    try std.testing.expectEqual(odd, @intFromPtr(resourceIdentifier(odd)));
}
