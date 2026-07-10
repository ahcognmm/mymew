const std = @import("std");

const FILE = anyopaque;
extern "c" fn popen(command: [*:0]const u8, mode: [*:0]const u8) ?*FILE;
extern "c" fn pclose(stream: *FILE) c_int;
extern "c" fn fread(ptr: *anyopaque, size: usize, nmemb: usize, stream: *FILE) usize;

pub const Args = struct {
    path: []const u8,
};

pub fn name() []const u8 {
    return "list_files";
}

pub fn description() []const u8 {
    return "List files and directories at the given path. Returns names, sizes, and types.";
}

pub fn execute(alloc: std.mem.Allocator, args: Args) anyerror![]const u8 {
    const cmd_str = try std.fmt.allocPrint(alloc, "ls -la -- {s} 2>&1", .{args.path});
    defer alloc.free(cmd_str);
    const cmd_z = try alloc.dupeZ(u8, cmd_str);
    defer alloc.free(cmd_z);

    const file = popen(cmd_z, "r") orelse
        return alloc.dupe(u8, "error: popen failed");
    defer _ = pclose(file);

    var output: std.ArrayList(u8) = .empty;
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = fread(&chunk, 1, chunk.len, file);
        if (n == 0) break;
        try output.appendSlice(alloc, chunk[0..n]);
        if (output.items.len > 256 * 1024) {
            try output.appendSlice(alloc, "\n[truncated]");
            break;
        }
    }
    if (output.items.len == 0) return alloc.dupe(u8, "(no output)");
    return output.toOwnedSlice(alloc);
}
