const std = @import("std");
const posix = std.posix;

extern "c" fn open(path: [*:0]const u8, oflag: c_int, ...) c_int;

pub const Args = struct {
    path: []const u8,
};

pub fn name() []const u8 {
    return "read_file";
}

pub fn description() []const u8 {
    return "Read and return the full text contents of a file at the given path.";
}

pub fn execute(alloc: std.mem.Allocator, args: Args) anyerror![]const u8 {
    const path_z = try alloc.dupeZ(u8, args.path);
    defer alloc.free(path_z);

    const raw_fd = open(path_z, 0); // O_RDONLY
    if (raw_fd < 0)
        return std.fmt.allocPrint(alloc, "error: cannot open '{s}'", .{args.path});
    const fd: posix.fd_t = raw_fd;
    defer _ = std.c.close(fd);

    var buf: std.ArrayList(u8) = .empty;
    var chunk: [8192]u8 = undefined;
    while (true) {
        const n = std.c.read(fd, &chunk, chunk.len);
        if (n <= 0) break;
        try buf.appendSlice(alloc, chunk[0..@intCast(n)]);
        if (buf.items.len > 1024 * 1024) {
            try buf.appendSlice(alloc, "\n[truncated at 1MB]");
            break;
        }
    }
    if (buf.items.len == 0) return alloc.dupe(u8, "(empty file)");
    return buf.toOwnedSlice(alloc);
}
