const std = @import("std");

const FILE = anyopaque;
extern "c" fn popen(command: [*:0]const u8, mode: [*:0]const u8) ?*FILE;
extern "c" fn pclose(stream: *FILE) c_int;
extern "c" fn fread(ptr: *anyopaque, size: usize, nmemb: usize, stream: *FILE) usize;

pub const Args = struct {
    command: []const u8,
    timeout_seconds: ?i64 = null,
};

pub fn name() []const u8 {
    return "execute_command";
}

pub fn description() []const u8 {
    return "Execute a shell command and return its combined stdout and stderr output. Use for running scripts, build commands, or any shell operation.";
}

pub fn execute(alloc: std.mem.Allocator, args: Args) anyerror![]const u8 {
    _ = args.timeout_seconds;

    const cmd_str = try std.fmt.allocPrint(alloc, "{s} 2>&1", .{args.command});
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
        if (output.items.len > 512 * 1024) {
            try output.appendSlice(alloc, "\n[output truncated at 512KB]");
            break;
        }
    }
    if (output.items.len == 0) return alloc.dupe(u8, "(no output)");
    return output.toOwnedSlice(alloc);
}
