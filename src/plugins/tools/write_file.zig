const std = @import("std");
const posix = std.posix;

extern "c" fn open(path: [*:0]const u8, oflag: c_int, ...) c_int;

// macOS open(2) flags
const O_WRONLY: c_int = 0x0001;
const O_CREAT: c_int = 0x0200;
const O_TRUNC: c_int = 0x0400;
const O_APPEND: c_int = 0x0008;

pub const Args = struct {
    path: []const u8,
    content: []const u8,
    append: ?bool = null,
};

pub fn name() []const u8 {
    return "write_file";
}

pub fn description() []const u8 {
    return "Write text content to a file. Creates the file if it doesn't exist. Set append=true to append instead of overwrite.";
}

pub fn describe(alloc: std.mem.Allocator, args: Args) anyerror![]const u8 {
    const verb = if (args.append orelse false) "Appending to" else "Writing to";
    return std.fmt.allocPrint(alloc, "{s} {s}", .{ verb, args.path });
}

pub fn execute(alloc: std.mem.Allocator, args: Args) anyerror![]const u8 {
    const path_z = try alloc.dupeZ(u8, args.path);
    defer alloc.free(path_z);

    const flags: c_int = if (args.append orelse false)
        O_WRONLY | O_CREAT | O_APPEND
    else
        O_WRONLY | O_CREAT | O_TRUNC;

    const raw_fd = open(path_z, flags, @as(c_int, 0o644));
    if (raw_fd < 0)
        return std.fmt.allocPrint(alloc, "error: cannot open '{s}' for writing", .{args.path});
    const fd: posix.fd_t = raw_fd;
    defer _ = std.c.close(fd);

    var written: usize = 0;
    while (written < args.content.len) {
        const n = std.c.write(fd, args.content.ptr + written, args.content.len - written);
        if (n <= 0)
            return std.fmt.allocPrint(alloc, "error: write failed after {d} bytes", .{written});
        written += @intCast(n);
    }
    return std.fmt.allocPrint(alloc, "ok: wrote {d} bytes to '{s}'", .{ written, args.path });
}
