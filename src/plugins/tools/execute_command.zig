const std = @import("std");
const posix = std.posix;

extern "c" var environ: [*:null]const ?[*:0]const u8;

pub const Args = struct {
    command: []const u8,
    timeout_seconds: ?i64 = null,
};

/// Applied when the model omits `timeout_seconds`.
pub const default_timeout_seconds: i64 = 120;
const max_output_bytes: usize = 512 * 1024;

fn monoMs() i64 {
    var ts: posix.timespec = .{ .sec = 0, .nsec = 0 };
    _ = std.c.clock_gettime(posix.CLOCK.MONOTONIC, &ts);
    return ts.sec * 1000 + @divTrunc(ts.nsec, 1_000_000);
}

pub fn name() []const u8 {
    return "execute_command";
}

pub fn description() []const u8 {
    return "Execute a shell command and return its combined stdout and stderr output, always prefixed with the command's real exit status (exit code, signal, or timeout). The command is killed if it exceeds timeout_seconds (default 120).";
}

pub fn describe(alloc: std.mem.Allocator, args: Args) anyerror![]const u8 {
    return alloc.dupe(u8, args.command);
}

pub fn execute(alloc: std.mem.Allocator, args: Args) anyerror![]const u8 {
    const timeout_s: i64 = args.timeout_seconds orelse default_timeout_seconds;

    const cmd_z = try alloc.dupeZ(u8, args.command);
    defer alloc.free(cmd_z);

    var pipe_fds: [2]std.c.fd_t = undefined;
    if (std.c.pipe(&pipe_fds) != 0) return alloc.dupe(u8, "error: pipe failed");
    const read_fd = pipe_fds[0];
    const write_fd = pipe_fds[1];

    const pid = std.c.fork();
    if (pid < 0) {
        _ = std.c.close(read_fd);
        _ = std.c.close(write_fd);
        return alloc.dupe(u8, "error: fork failed");
    }
    if (pid == 0) {
        // Child: own process group, so a timeout kill below reaps pipeline
        // children too; stdout and stderr both land on the pipe.
        _ = std.c.setpgid(0, 0);
        if (std.c.dup2(write_fd, 1) < 0) std.c._exit(126);
        if (std.c.dup2(write_fd, 2) < 0) std.c._exit(126);
        _ = std.c.close(read_fd);
        _ = std.c.close(write_fd);
        const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", cmd_z.ptr };
        _ = std.c.execve("/bin/sh", &argv, environ);
        std.c._exit(127);
    }
    _ = std.c.close(write_fd);
    defer _ = std.c.close(read_fd);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(alloc);

    var timed_out = false;
    var truncated = false;
    const deadline_ms: i64 = monoMs() + timeout_s * 1000;
    while (true) {
        const remaining = deadline_ms - monoMs();
        if (remaining <= 0) {
            timed_out = true;
            break;
        }
        var pfd = [_]posix.pollfd{.{ .fd = read_fd, .events = posix.POLL.IN, .revents = 0 }};
        const ready = posix.poll(&pfd, @intCast(@min(remaining, 1000))) catch 0;
        if (ready == 0) continue;
        var chunk: [4096]u8 = undefined;
        const n = posix.read(read_fd, &chunk) catch 0;
        if (n == 0) break; // EOF: the command closed its end (exited)
        try output.appendSlice(alloc, chunk[0..n]);
        if (output.items.len > max_output_bytes) {
            truncated = true;
            break;
        }
    }

    if (timed_out or truncated) {
        // Without the kill, EOF may never come and waitpid would hang.
        posix.kill(-pid, .KILL) catch {};
    }
    var raw_status: c_int = 0;
    _ = std.c.waitpid(pid, &raw_status, 0);
    const status: u32 = @bitCast(raw_status);

    const header = if (timed_out)
        try std.fmt.allocPrint(alloc, "error: command timed out after {d} seconds and was killed\n", .{timeout_s})
    else if (truncated)
        try std.fmt.allocPrint(alloc, "error: output exceeded {d}KB and the command was killed\n", .{max_output_bytes / 1024})
    else if (posix.W.IFEXITED(status))
        try std.fmt.allocPrint(alloc, "exit code: {d}\n", .{posix.W.EXITSTATUS(status)})
    else if (posix.W.IFSIGNALED(status))
        try std.fmt.allocPrint(alloc, "killed by signal {d}\n", .{posix.W.TERMSIG(status)})
    else
        try alloc.dupe(u8, "exit status: unknown\n");
    defer alloc.free(header);

    const body: []const u8 = if (output.items.len == 0) "(no output)" else output.items;
    return std.mem.concat(alloc, u8, &.{ header, body });
}

const testing = std.testing;

test "execute_command reports the real exit code, not just output" {
    const r = try execute(testing.allocator, .{ .command = "exit 3" });
    defer testing.allocator.free(r);
    try testing.expect(std.mem.startsWith(u8, r, "exit code: 3\n"));
}

test "execute_command captures stdout and stderr with a zero exit code" {
    const r = try execute(testing.allocator, .{ .command = "echo out; echo err 1>&2" });
    defer testing.allocator.free(r);
    try testing.expect(std.mem.startsWith(u8, r, "exit code: 0\n"));
    try testing.expect(std.mem.indexOf(u8, r, "out\n") != null);
    try testing.expect(std.mem.indexOf(u8, r, "err\n") != null);
}

test "execute_command kills a command that exceeds its timeout" {
    const r = try execute(testing.allocator, .{ .command = "sleep 5", .timeout_seconds = 1 });
    defer testing.allocator.free(r);
    try testing.expect(std.mem.startsWith(u8, r, "error: command timed out after 1 seconds"));
}
