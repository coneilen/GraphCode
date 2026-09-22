const std = @import("std");

pub const directory_prefix = ".graphcode-";
pub const default_directory_name = ".graphcode";
pub const max_name_length: usize = 48;

pub const Workspace = struct {
    name: []const u8,
    path: []const u8,
    is_default: bool,

    pub fn deinit(self: *Workspace, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.path);
        self.* = undefined;
    }
};

pub const List = struct {
    items: []Workspace,

    pub fn deinit(self: *List, allocator: std.mem.Allocator) void {
        for (self.items) |*workspace| workspace.deinit(allocator);
        allocator.free(self.items);
        self.* = undefined;
    }
};

pub const NameError = error{
    EmptyName,
    InvalidName,
    NameTooLong,
    NameTaken,
};

pub fn defaultPath(allocator: std.mem.Allocator) ![]u8 {
    const home = std.process.getEnvVarOwned(allocator, "USERPROFILE") catch
        return error.UserProfileMissing;
    defer allocator.free(home);
    return std.fs.path.join(allocator, &.{ home, default_directory_name });
}

pub fn currentPath(allocator: std.mem.Allocator) ![]u8 {
    if (std.process.getEnvVarOwned(allocator, "GRAPHCODE_SUPPORT_DIR")) |value| {
        defer allocator.free(value);
        if (value.len != 0) return resolvePath(allocator, value);
    } else |_| {}
    return defaultPath(allocator);
}

pub fn normalizeName(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var result = std.array_list.Managed(u8).init(allocator);
    errdefer result.deinit();
    var previous_dash = false;
    for (input) |byte| {
        if (std.ascii.isAlphanumeric(byte)) {
            try result.append(std.ascii.toLower(byte));
            previous_dash = false;
        } else if (!previous_dash and result.items.len != 0) {
            try result.append('-');
            previous_dash = true;
        }
    }
    while (result.items.len != 0 and result.items[result.items.len - 1] == '-') {
        _ = result.pop();
    }
    if (result.items.len == 0) return NameError.EmptyName;
    if (result.items.len > max_name_length) return NameError.NameTooLong;
    return result.toOwnedSlice();
}

pub fn validateName(
    allocator: std.mem.Allocator,
    input: []const u8,
    home: []const u8,
) ![]u8 {
    const name = try normalizeName(allocator, input);
    errdefer allocator.free(name);
    const path = try workspacePath(allocator, name, home);
    defer allocator.free(path);
    if (directoryExists(path)) return NameError.NameTaken;
    return name;
}

pub fn workspacePath(
    allocator: std.mem.Allocator,
    name: []const u8,
    home: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}\\{s}{s}", .{ home, directory_prefix, name });
}

pub fn resolvePath(allocator: std.mem.Allocator, configured: []const u8) ![]u8 {
    if (isAbsoluteWindowsPath(configured)) return allocator.dupe(u8, configured);
    const home = std.process.getEnvVarOwned(allocator, "USERPROFILE") catch
        return allocator.dupe(u8, configured);
    defer allocator.free(home);
    return std.fs.path.join(allocator, &.{ home, configured });
}

pub fn list(allocator: std.mem.Allocator) !List {
    const home = std.process.getEnvVarOwned(allocator, "USERPROFILE") catch
        return error.UserProfileMissing;
    defer allocator.free(home);
    return listFromHome(allocator, home);
}

pub fn listFromHome(allocator: std.mem.Allocator, home: []const u8) !List {
    var values = std.array_list.Managed(Workspace).init(allocator);
    errdefer {
        for (values.items) |*workspace| workspace.deinit(allocator);
        values.deinit();
    }
    const default_path = try std.fmt.allocPrint(allocator, "{s}\\{s}", .{ home, default_directory_name });
    defer allocator.free(default_path);
    try values.append(.{
        .name = try allocator.dupe(u8, "Default"),
        .path = try allocator.dupe(u8, default_path),
        .is_default = true,
    });
    var directory = std.fs.openDirAbsolute(home, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.AccessDenied => return .{ .items = try values.toOwnedSlice() },
        else => return err,
    };
    defer directory.close();
    var iterator = directory.iterate();
    while (try iterator.next()) |entry| {
        if (entry.kind != .directory or !std.mem.startsWith(u8, entry.name, directory_prefix))
            continue;
        const suffix = entry.name[directory_prefix.len..];
        if (suffix.len == 0) continue;
        const path = try std.fmt.allocPrint(allocator, "{s}\\{s}", .{ home, entry.name });
        try values.append(.{
            .name = try allocator.dupe(u8, suffix),
            .path = path,
            .is_default = false,
        });
    }
    std.sort.block(Workspace, values.items, {}, lessThan);
    return .{ .items = try values.toOwnedSlice() };
}

pub fn directoryExists(path: []const u8) bool {
    var directory = std.fs.openDirAbsolute(path, .{}) catch return false;
    directory.close();
    return true;
}

pub fn isAbsoluteWindowsPath(path: []const u8) bool {
    return (path.len >= 2 and path[1] == ':') or
        (path.len >= 2 and path[0] == '\\' and path[1] == '\\') or
        (path.len >= 2 and path[0] == '/' and path[1] == '/');
}

pub fn isSamePath(left: []const u8, right: []const u8) bool {
    return std.ascii.eqlIgnoreCase(left, right);
}

fn lessThan(_: void, left: Workspace, right: Workspace) bool {
    return std.ascii.lessThanIgnoreCase(left.name, right.name);
}

test "workspace names normalize to safe stable directory suffixes" {
    const name = try normalizeName(std.testing.allocator, "Café / Zürich");
    defer std.testing.allocator.free(name);
    try std.testing.expectEqualStrings("caf-z-rich", name);
}

test "workspace validation rejects long names" {
    var long_name: [max_name_length + 2]u8 = undefined;
    @memset(&long_name, 'x');
    try std.testing.expectError(NameError.NameTooLong, normalizeName(std.testing.allocator, &long_name));
}

test "workspace paths use the Windows sibling convention" {
    const path = try workspacePath(std.testing.allocator, "alpha", "C:\\Users\\tester");
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("C:\\Users\\tester\\.graphcode-alpha", path);
}
