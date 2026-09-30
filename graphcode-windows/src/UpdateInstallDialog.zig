const std = @import("std");
const Win32 = @import("Win32.zig");
const c = Win32.c;
const ModalTeardown = @import("ModalTeardown.zig");
const AppFont = @import("AppFont.zig");
const WindowsUpdateInstall = @import("WindowsUpdateInstall.zig");

/// The in-window install-progress indicator and the post-install relaunch
/// prompt, combined into one native window: the same window that showed
/// "Downloading update… 42%" a moment ago becomes "Update installed" with
/// Relaunch Now / Later once `GraphCode-Setup.ps1 -Command Upgrade` returns.
/// One window rather than two separate dialogs because there is exactly one
/// install in flight at a time and the transition between them is the whole
/// point of the row this satisfies (macOS shows the same two moments as
/// separate alerts; this is one window that changes what it says).
pub const RelaunchAction = enum { relaunch_now, later };
pub const Outcome = union(enum) {
    relaunch: RelaunchAction,
    /// The user cancelled before the install finished.
    cancelled,
    /// Installation failed; carries a human-readable reason by value, so the
    /// caller never owns, frees, or borrows memory from the dialog.
    failed: FailureMessage,
};

/// A fixed-capacity copy of a failure reason. Capturing one cannot fail, so
/// every failure path surfaces its reason without an allocation to lose.
pub const FailureMessage = struct {
    pub const capacity = 256;

    bytes: [capacity]u8 = undefined,
    len: usize = 0,

    pub fn init(value: []const u8) FailureMessage {
        var len = @min(value.len, capacity);
        // Never cut a UTF-8 sequence in half when truncating.
        if (len < value.len) {
            while (len > 0 and (value[len] & 0xC0) == 0x80) len -= 1;
        }
        var message = FailureMessage{ .len = len };
        @memcpy(message.bytes[0..len], value[0..len]);
        return message;
    }

    pub fn text(self: *const FailureMessage) []const u8 {
        return self.bytes[0..self.len];
    }
};

// ---------------------------------------------------------------------------
// Pure presentation logic — unit tested without any window.
// ---------------------------------------------------------------------------

/// Formats the progress line shown while downloading/verifying/extracting/
/// installing. Percent is only meaningful during `.downloading` (the only
/// phase with a known denominator); the other phases are indeterminate, so
/// they say what's happening without implying a fake percentage.
pub fn formatProgressText(buffer: []u8, phase: WindowsUpdateInstall.Phase, fraction: f64) ![]u8 {
    return switch (phase) {
        .downloading => std.fmt.bufPrint(buffer, "Downloading update… {d}%", .{@as(u32, @intFromFloat(@min(@max(fraction, 0), 1) * 100))}),
        .verifying => std.fmt.bufPrint(buffer, "Verifying download…", .{}),
        .extracting => std.fmt.bufPrint(buffer, "Extracting update…", .{}),
        .installing => std.fmt.bufPrint(buffer, "Installing…", .{}),
    };
}

/// The exact wording an install failure surfaces, kept as a pure mapping so
/// it can be asserted without ever triggering a real failure.
pub fn failureMessage(err: WindowsUpdateInstall.InstallError) []const u8 {
    return switch (err) {
        error.Cancelled => "The update was cancelled.",
        error.ChecksumUnavailable => "GraphCode couldn't confirm the download's checksum.",
        error.ChecksumMismatch => "The downloaded file didn't match its published checksum.",
        error.DownloadFailed => "The download failed.",
        error.ExtractionFailed => "The downloaded package couldn't be extracted.",
        error.ExtractionTimedOut => "Extracting the update took too long and was stopped.",
        error.SetupScriptMissing => "The downloaded package is missing its setup script.",
        error.UpgradeFailed => "Installing the update failed. The previous installation was kept.",
        error.UpgradeTimedOut => "Installing the update took too long and was stopped.",
        error.OutOfMemory => "GraphCode ran out of memory while installing the update.",
    };
}

/// Session-continuity copy for the relaunch prompt, matching the macOS
/// wording's substance: the daemon and zmx-backed terminal sessions are
/// independent of the GUI process and survive a relaunch.
pub const relaunch_message =
    "GraphCode is installed and takes over on the next launch. Sessions keep " ++
    "running through a relaunch — the background daemon holds them, not this window.";

// ---------------------------------------------------------------------------
// Native window — the message pump is covered by a headless test, but a real
// download/extract/install cycle still needs live exercise.
// ---------------------------------------------------------------------------

const class_name = std.unicode.utf8ToUtf16LeStringLiteral("GraphCodeUpdateInstall");
const cancel_id: u16 = 9711;
const relaunch_id: u16 = 9712;
const later_id: u16 = 9713;
const close_id: u16 = 9714;
const tick_message: c.UINT = c.WM_APP + 1;

const Stage = enum { progress, relaunch, failed };

const State = struct {
    allocator: std.mem.Allocator,
    stage: Stage = .progress,
    outcome: ?Outcome = null,
    closed: bool = false,
    cancel_requested: bool = false,
    status_hwnd: c.HWND = null,
    button_hwnd: [2]c.HWND = .{ null, null },
};

var active = false;
var active_state: State = undefined;
var active_hwnd: c.HWND = null;

var shared_phase = std.atomic.Value(u8).init(0);
var shared_fraction_bits = std.atomic.Value(u64).init(0);
var shared_done = std.atomic.Value(bool).init(false);
var shared_failed = std.atomic.Value(bool).init(false);
var shared_failure_buffer: [256]u8 = undefined;
var shared_failure_len = std.atomic.Value(usize).init(0);
var shared_cancelled = std.atomic.Value(bool).init(false);

fn reportProgress(phase: WindowsUpdateInstall.Phase, fraction: f64) void {
    shared_phase.store(@intFromEnum(phase), .release);
    shared_fraction_bits.store(@bitCast(fraction), .release);
    if (active_hwnd) |hwnd| _ = c.PostMessageW(hwnd, tick_message, 0, 0);
}

fn worker(options: WindowsUpdateInstall.InstallOptions) void {
    WindowsUpdateInstall.install(options) catch |err| {
        const message = failureMessage(err);
        const len = @min(message.len, shared_failure_buffer.len);
        @memcpy(shared_failure_buffer[0..len], message[0..len]);
        shared_failure_len.store(len, .release);
        shared_failed.store(true, .release);
        shared_done.store(true, .release);
        if (active_hwnd) |hwnd| _ = c.PostMessageW(hwnd, tick_message, 0, 0);
        return;
    };
    shared_done.store(true, .release);
    if (active_hwnd) |hwnd| _ = c.PostMessageW(hwnd, tick_message, 0, 0);
}

/// Runs the progress window, blocking until the install finishes (or is
/// cancelled), then presents Relaunch Now/Later on success or an error state
/// on failure, and blocks again until the user picks a next step. Returns
/// once the window has been dismissed.
pub fn run(
    parent: c.HWND,
    allocator: std.mem.Allocator,
    asset_url: []const u8,
    expected_sha256: ?[]const u8,
    checksum_url: ?[]const u8,
) !Outcome {
    registerClass() catch return error.DialogClassRegistrationFailed;
    active_state = .{ .allocator = allocator };
    active = true;
    errdefer active = false;
    shared_phase.store(0, .release);
    shared_fraction_bits.store(@bitCast(@as(f64, 0)), .release);
    shared_done.store(false, .release);
    shared_failed.store(false, .release);
    shared_cancelled.store(false, .release);

    const title = try wideZ(allocator, "GraphCode Update");
    defer allocator.free(title);
    const hwnd = c.CreateWindowExW(
        c.WS_EX_DLGMODALFRAME | c.WS_EX_CONTROLPARENT,
        class_name.ptr,
        title.ptr,
        c.WS_OVERLAPPED | c.WS_CAPTION | c.WS_SYSMENU,
        c.CW_USEDEFAULT,
        c.CW_USEDEFAULT,
        460,
        180,
        parent,
        null,
        c.GetModuleHandleW(null),
        null,
    ) orelse {
        active = false;
        return error.DialogCreationFailed;
    };
    const options = WindowsUpdateInstall.InstallOptions{
        .allocator = allocator,
        .asset_url = asset_url,
        .expected_sha256 = expected_sha256,
        .checksum_url = checksum_url,
        .cancelled = &shared_cancelled,
        .progress = &reportProgress,
    };
    const thread = try startInstall(StartupApi, hwnd, parent, options);

    return finishInstall(StartupApi, hwnd, parent, thread);
}

fn finishInstall(comptime Api: type, hwnd: c.HWND, parent: c.HWND, thread: std.Thread) Outcome {
    var message: c.MSG = undefined;
    var quit_code: ?c.WPARAM = null;
    while (!active_state.closed) {
        const code = c.GetMessageW(&message, null, 0, 0);
        if (code <= 0) {
            active_state.closed = true;
            if (code == 0) quit_code = message.wParam;
            break;
        }
        if (c.IsDialogMessageW(hwnd, &message) != 0) continue;
        _ = c.TranslateMessage(&message);
        _ = c.DispatchMessageW(&message);
    }
    Api.join(thread);
    ModalTeardown.dismissWith(Api, hwnd, parent);
    active_hwnd = null;
    active = false;
    if (quit_code) |value| c.PostQuitMessage(@intCast(value));
    return closedOutcome(active_state.outcome);
}

const window_closed_message = "The update window closed unexpectedly.";

fn closedOutcome(outcome: ?Outcome) Outcome {
    return outcome orelse .{ .failed = FailureMessage.init(window_closed_message) };
}

/// The Win32 and thread surface used to present the window and start the
/// worker, injected so the startup failure path can be asserted without real
/// windows or threads.
const StartupApi = struct {
    pub fn enableWindow(window: c.HWND, enabled: c_int) void {
        _ = c.EnableWindow(window, enabled);
    }

    pub fn showWindow(window: c.HWND) void {
        _ = c.ShowWindow(window, c.SW_SHOW);
        _ = c.SetForegroundWindow(window);
    }

    pub fn destroyWindow(window: c.HWND) void {
        _ = c.DestroyWindow(window);
    }

    pub fn setActiveWindow(window: c.HWND) void {
        _ = c.SetActiveWindow(window);
    }

    pub fn spawn(options: WindowsUpdateInstall.InstallOptions) !std.Thread {
        return std.Thread.spawn(.{}, worker, .{options});
    }

    pub fn join(thread: std.Thread) void {
        thread.join();
    }
};

fn startInstall(comptime Api: type, hwnd: c.HWND, parent: c.HWND, options: WindowsUpdateInstall.InstallOptions) !std.Thread {
    active_hwnd = hwnd;
    Api.enableWindow(parent, 0);
    Api.showWindow(hwnd);
    errdefer {
        ModalTeardown.dismissWith(Api, hwnd, parent);
        active_hwnd = null;
        active = false;
    }
    return try Api.spawn(options);
}

fn registerClass() !void {
    var klass: c.WNDCLASSW = std.mem.zeroes(c.WNDCLASSW);
    klass.lpfnWndProc = @ptrCast(&windowProc);
    klass.hInstance = c.GetModuleHandleW(null);
    klass.lpszClassName = class_name.ptr;
    klass.hCursor = c.LoadCursorW(null, Win32.resourceIdentifier(32512));
    if (c.RegisterClassW(&klass) == 0 and c.GetLastError() != c.ERROR_CLASS_ALREADY_EXISTS)
        return error.DialogClassRegistrationFailed;
}

fn windowProc(hwnd: c.HWND, message: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM) callconv(.winapi) c.LRESULT {
    if (!active) return c.DefWindowProcW(hwnd, message, wparam, lparam);
    switch (message) {
        c.WM_CREATE => {
            active_state.status_hwnd = createStatic(hwnd, active_state.allocator, "Preparing…", 18, 20, 420, 24);
            active_state.button_hwnd[0] = createButton(hwnd, "Cancel", cancel_id, 320, 90);
            return 0;
        },
        tick_message => {
            onTick(hwnd);
            return 0;
        },
        c.WM_COMMAND => {
            const command: u16 = @truncate(wparam);
            switch (command) {
                cancel_id => {
                    active_state.cancel_requested = true;
                    shared_cancelled.store(true, .release);
                    setStatusText(active_state.status_hwnd, active_state.allocator, "Cancelling…");
                    if (active_state.button_hwnd[0]) |button| _ = c.EnableWindow(button, 0);
                },
                relaunch_id => {
                    active_state.outcome = .{ .relaunch = .relaunch_now };
                    requestClose(hwnd);
                },
                later_id => {
                    active_state.outcome = .{ .relaunch = .later };
                    requestClose(hwnd);
                },
                close_id => {
                    requestClose(hwnd);
                },
                else => {},
            }
            return 0;
        },
        c.WM_CLOSE => {
            if (active_state.stage == .progress) {
                active_state.cancel_requested = true;
                shared_cancelled.store(true, .release);
                return 0; // Wait for the worker to actually stop before closing.
            }
            requestClose(hwnd);
            return 0;
        },
        else => {},
    }
    return c.DefWindowProcW(hwnd, message, wparam, lparam);
}

/// Decides the outcome of a worker that reported failure. `source` is the
/// worker's shared, reused buffer; the returned outcome holds its own copy.
fn failedCompletion(cancel_requested: bool, source: []const u8) Outcome {
    if (cancel_requested) return .cancelled;
    return .{ .failed = FailureMessage.init(source) };
}

fn failureTextOf(outcome: *const Outcome) ?[]const u8 {
    return switch (outcome.*) {
        .failed => |*message| message.text(),
        else => null,
    };
}

fn onTick(hwnd: c.HWND) void {
    if (active_state.stage != .progress) return;
    if (shared_done.load(.acquire)) {
        if (shared_failed.load(.acquire)) {
            const len = shared_failure_len.load(.acquire);
            active_state.stage = .failed;
            active_state.outcome = failedCompletion(active_state.cancel_requested, shared_failure_buffer[0..len]);
            if (failureTextOf(&active_state.outcome.?)) |message| {
                transitionToFailed(hwnd, message);
            } else {
                requestClose(hwnd);
            }
        } else {
            active_state.stage = .relaunch;
            transitionToRelaunch(hwnd);
        }
        return;
    }
    const phase: WindowsUpdateInstall.Phase = @enumFromInt(shared_phase.load(.acquire));
    const fraction: f64 = @bitCast(shared_fraction_bits.load(.acquire));
    var buffer: [64]u8 = undefined;
    const text = formatProgressText(&buffer, phase, fraction) catch "Working…";
    setStatusText(active_state.status_hwnd, active_state.allocator, text);
}

fn transitionToRelaunch(hwnd: c.HWND) void {
    if (active_state.button_hwnd[0]) |button| _ = c.DestroyWindow(button);
    setStatusText(active_state.status_hwnd, active_state.allocator, "Update installed. " ++ relaunch_message);
    active_state.button_hwnd[0] = createButton(hwnd, "Relaunch Now", relaunch_id, 220, 90);
    active_state.button_hwnd[1] = createButton(hwnd, "Later", later_id, 350, 90);
}

fn transitionToFailed(hwnd: c.HWND, message: []const u8) void {
    if (active_state.button_hwnd[0]) |button| _ = c.DestroyWindow(button);
    setStatusText(active_state.status_hwnd, active_state.allocator, message);
    active_state.button_hwnd[0] = createButton(hwnd, "Close", close_id, 350, 90);
}

fn requestClose(hwnd: c.HWND) void {
    active_state.closed = true;
    _ = c.PostMessageW(hwnd, c.WM_NULL, 0, 0);
}

fn setStatusText(hwnd: c.HWND, allocator: std.mem.Allocator, text: []const u8) void {
    if (hwnd == null) return;
    const wide = wideZ(allocator, text) catch return;
    defer allocator.free(wide);
    _ = c.SetWindowTextW(hwnd, wide.ptr);
}

fn createStatic(hwnd: c.HWND, allocator: std.mem.Allocator, text: []const u8, x: i32, y: i32, width: i32, height: i32) c.HWND {
    const wide = wideZ(allocator, text) catch return null;
    defer allocator.free(wide);
    const control = c.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("STATIC").ptr,
        wide.ptr,
        c.WS_CHILD | c.WS_VISIBLE | c.SS_LEFT,
        x,
        y,
        width,
        height,
        hwnd,
        null,
        c.GetModuleHandleW(null),
        null,
    );
    AppFont.apply(control, AppFont.control_size, false);
    return control;
}

fn createButton(hwnd: c.HWND, label: []const u8, id: u16, x: i32, y: i32) c.HWND {
    const wide = wideZ(std.heap.c_allocator, label) catch return null;
    defer std.heap.c_allocator.free(wide);
    const button = c.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("BUTTON").ptr,
        wide.ptr,
        c.WS_CHILD | c.WS_VISIBLE | c.WS_TABSTOP | c.BS_PUSHBUTTON,
        x,
        y,
        110,
        30,
        hwnd,
        controlId(id),
        c.GetModuleHandleW(null),
        null,
    ) orelse return null;
    AppFont.apply(button, AppFont.control_size, false);
    return button;
}

fn controlId(value: u16) c.HMENU {
    @setRuntimeSafety(false);
    return @ptrFromInt(@as(usize, value));
}

fn wideZ(allocator: std.mem.Allocator, value: []const u8) ![]u16 {
    const raw = try std.unicode.utf8ToUtf16LeAlloc(allocator, value);
    defer allocator.free(raw);
    const result = try allocator.alloc(u16, raw.len + 1);
    @memcpy(result[0..raw.len], raw);
    result[raw.len] = 0;
    return result;
}

// ---------------------------------------------------------------------------
// Tests — presentation logic and headless window lifecycle.
// ---------------------------------------------------------------------------

test "download progress text reports a real percentage" {
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("Downloading update… 0%", try formatProgressText(&buffer, .downloading, 0));
    try std.testing.expectEqualStrings("Downloading update… 42%", try formatProgressText(&buffer, .downloading, 0.42));
    try std.testing.expectEqualStrings("Downloading update… 100%", try formatProgressText(&buffer, .downloading, 1));
}

test "download progress text clamps out-of-range fractions rather than showing garbage" {
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("Downloading update… 0%", try formatProgressText(&buffer, .downloading, -0.5));
    try std.testing.expectEqualStrings("Downloading update… 100%", try formatProgressText(&buffer, .downloading, 1.5));
}

test "non-downloading phases are indeterminate rather than showing a fake percentage" {
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("Verifying download…", try formatProgressText(&buffer, .verifying, 0.7));
    try std.testing.expectEqualStrings("Extracting update…", try formatProgressText(&buffer, .extracting, 0.7));
    try std.testing.expectEqualStrings("Installing…", try formatProgressText(&buffer, .installing, 0.7));
}

test "every InstallError maps to a distinct, human-readable failure message" {
    const errors = [_]WindowsUpdateInstall.InstallError{
        error.Cancelled,
        error.ChecksumUnavailable,
        error.ChecksumMismatch,
        error.DownloadFailed,
        error.ExtractionFailed,
        error.ExtractionTimedOut,
        error.SetupScriptMissing,
        error.UpgradeFailed,
        error.UpgradeTimedOut,
        error.OutOfMemory,
    };
    for (errors, 0..) |err, i| {
        const message = failureMessage(err);
        try std.testing.expect(message.len > 0);
        for (errors[i + 1 ..]) |other| {
            try std.testing.expect(!std.mem.eql(u8, message, failureMessage(other)));
        }
    }
}

test "the relaunch message explains session continuity, not just that install succeeded" {
    try std.testing.expect(std.mem.indexOf(u8, relaunch_message, "Sessions") != null);
    try std.testing.expect(std.mem.indexOf(u8, relaunch_message, "daemon") != null);
}

test "a worker failure outcome does not borrow the shared failure buffer and needs no allocation" {
    var source: [128]u8 = undefined;
    const reason = failureMessage(error.DownloadFailed);
    @memcpy(source[0..reason.len], reason);
    // Capturing takes no allocator, so there is no out-of-memory fallback
    // that could hand back a borrowed or static reason.
    const outcome = failedCompletion(false, source[0..reason.len]);
    // The worker reuses this buffer; the outcome must survive it being rewritten.
    @memset(&source, 'x');
    try std.testing.expectEqualStrings(reason, failureTextOf(&outcome).?);
}

test "a worker failure outcome survives being copied after its source is gone" {
    const outcome = blk: {
        var source: [128]u8 = undefined;
        const reason = failureMessage(error.UpgradeFailed);
        @memcpy(source[0..reason.len], reason);
        const captured = failedCompletion(false, source[0..reason.len]);
        @memset(&source, 0);
        break :blk captured;
    };
    try std.testing.expectEqualStrings(failureMessage(error.UpgradeFailed), failureTextOf(&outcome).?);
}

test "a failure reported after the user cancelled is surfaced as cancelled without leaking" {
    const outcome = failedCompletion(true, failureMessage(error.Cancelled));
    try std.testing.expect(outcome == .cancelled);
}

test "the window-closed fallback is a surfaced failure the caller never frees" {
    const outcome = closedOutcome(null);
    try std.testing.expectEqualStrings(window_closed_message, failureTextOf(&outcome).?);
    // The failure payload is a value, not a slice a caller could free.
    try std.testing.expect(std.meta.TagPayload(Outcome, .failed) == FailureMessage);
}

test "the window-closed fallback never replaces a decided outcome" {
    try std.testing.expect(closedOutcome(.cancelled) == .cancelled);
    try std.testing.expectEqual(RelaunchAction.later, closedOutcome(.{ .relaunch = .later }).relaunch);
}

test "a failure reason longer than the capacity is truncated on a UTF-8 boundary" {
    var long: [FailureMessage.capacity + 8]u8 = undefined;
    @memset(&long, 'a');
    // A three-byte character straddling the capacity must be dropped whole.
    const ellipsis = "…";
    @memcpy(long[FailureMessage.capacity - 1 ..][0..ellipsis.len], ellipsis);
    const message = FailureMessage.init(&long);
    try std.testing.expectEqual(FailureMessage.capacity - 1, message.text().len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(message.text()));
}

var startup_calls: [8]StartupCall = undefined;
var startup_calls_len: usize = 0;
var startup_owner_enabled: bool = true;
var startup_dialog_alive: bool = false;

const StartupCall = enum { disable_owner, enable_owner, show_dialog, destroy_dialog, activate_owner, spawn, join_worker };

fn recordStartup(call: StartupCall) void {
    startup_calls[startup_calls_len] = call;
    startup_calls_len += 1;
}

const FailingSpawnApi = struct {
    pub fn enableWindow(window: c.HWND, enabled: c_int) void {
        _ = window;
        startup_owner_enabled = enabled != 0;
        recordStartup(if (enabled != 0) .enable_owner else .disable_owner);
    }

    pub fn showWindow(window: c.HWND) void {
        _ = window;
        recordStartup(.show_dialog);
    }

    pub fn destroyWindow(window: c.HWND) void {
        _ = window;
        startup_dialog_alive = false;
        recordStartup(.destroy_dialog);
    }

    pub fn setActiveWindow(window: c.HWND) void {
        _ = window;
        recordStartup(.activate_owner);
    }

    pub fn spawn(options: WindowsUpdateInstall.InstallOptions) !std.Thread {
        _ = options;
        recordStartup(.spawn);
        return error.SystemResources;
    }
};

fn fakeWindow(value: usize) c.HWND {
    @setRuntimeSafety(false);
    return @ptrFromInt(value);
}

test "a worker thread that cannot start restores the owner and tears the window down" {
    startup_calls_len = 0;
    startup_owner_enabled = true;
    startup_dialog_alive = true;
    active = true;
    defer active = false;
    defer active_hwnd = null;

    const options = WindowsUpdateInstall.InstallOptions{
        .allocator = std.testing.allocator,
        .asset_url = "https://example.invalid/GraphCode.zip",
        .cancelled = &shared_cancelled,
        .progress = &reportProgress,
    };
    try std.testing.expectError(error.SystemResources, startInstall(FailingSpawnApi, fakeWindow(0x2000), fakeWindow(0x1000), options));

    try std.testing.expect(startup_owner_enabled);
    try std.testing.expect(!startup_dialog_alive);
    try std.testing.expect(!active);
    try std.testing.expect(active_hwnd == null);
    try std.testing.expectEqualSlices(
        StartupCall,
        &.{ .disable_owner, .show_dialog, .spawn, .enable_owner, .destroy_dialog, .activate_owner },
        startup_calls[0..startup_calls_len],
    );
}

const QuitTestApi = struct {
    pub fn join(thread: std.Thread) void {
        _ = thread;
        recordStartup(.join_worker);
    }

    pub fn enableWindow(window: c.HWND, enabled: c_int) void {
        _ = window;
        std.debug.assert(enabled != 0);
        recordStartup(.enable_owner);
    }

    pub fn destroyWindow(window: c.HWND) void {
        _ = window;
        recordStartup(.destroy_dialog);
    }

    pub fn setActiveWindow(window: c.HWND) void {
        _ = window;
        recordStartup(.activate_owner);
    }
};

test "update install dialog preserves WM_QUIT exit code after teardown" {
    var pending: c.MSG = undefined;
    defer _ = c.PeekMessageW(&pending, null, c.WM_QUIT, c.WM_QUIT, c.PM_REMOVE);
    startup_calls_len = 0;
    active_state = .{ .allocator = std.testing.allocator };
    active_hwnd = fakeWindow(0x2000);
    active = true;
    c.PostQuitMessage(73);

    const outcome = finishInstall(QuitTestApi, fakeWindow(0x2000), fakeWindow(0x1000), undefined);
    try std.testing.expectEqualSlices(
        StartupCall,
        &.{ .join_worker, .enable_owner, .destroy_dialog, .activate_owner },
        startup_calls[0..startup_calls_len],
    );
    try std.testing.expect(outcome == .failed);
    try std.testing.expect(!active);
    try std.testing.expect(active_hwnd == null);
    try std.testing.expectEqual(@as(c.BOOL, 1), c.PeekMessageW(&pending, null, c.WM_QUIT, c.WM_QUIT, c.PM_REMOVE));
    try std.testing.expectEqual(@as(c.WPARAM, 73), pending.wParam);
}
