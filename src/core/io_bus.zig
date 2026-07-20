const std = @import("std");
const posix = std.posix;
const Io = std.Io;

/// The generic contract between the background `Agent` (core/agent.zig) and
/// whatever frontend is driving it — a TUI, a headless one-shot CLI run,
/// anything else. Frontend-agnostic on purpose: core code must not depend on
/// any particular UI.

/// Thread-safe byte queue: the agent thread pushes streamed tokens, the
/// frontend drains them on its own schedule (a render loop, a synchronous
/// print, whatever).
pub const Channel = struct {
    gpa: std.mem.Allocator,
    mutex: Io.Mutex = .init,
    buf: std.ArrayList(u8),

    pub fn init(gpa: std.mem.Allocator) Channel {
        return .{ .gpa = gpa, .buf = .empty };
    }

    pub fn deinit(self: *Channel) void {
        self.buf.deinit(self.gpa);
    }

    pub fn push(self: *Channel, io: Io, bytes: []const u8) !void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        try self.buf.appendSlice(self.gpa, bytes);
    }

    /// Move all pending bytes into `out`; returns true if anything was moved.
    pub fn drain(self: *Channel, io: Io, out: *std.ArrayList(u8), gpa: std.mem.Allocator) !bool {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.buf.items.len == 0) return false;
        try out.appendSlice(gpa, self.buf.items);
        self.buf.clearRetainingCapacity();
        return true;
    }
};

/// Custom `Io.Writer` that feeds a `Channel` and pings a wakeup fd whenever
/// bytes land, so a frontend blocked in `poll()` notices immediately.
pub const ChannelWriter = struct {
    io: Io,
    channel: *Channel,
    wakeup_fd: posix.fd_t,
    writer: Io.Writer,

    const vtable: Io.Writer.VTable = .{ .drain = ChannelWriter.drain };

    pub fn init(io: Io, channel: *Channel, wakeup_fd: posix.fd_t, buffer: []u8) ChannelWriter {
        return .{
            .io = io,
            .channel = channel,
            .wakeup_fd = wakeup_fd,
            .writer = .{
                .vtable = &vtable,
                .buffer = buffer,
                .end = 0,
            },
        };
    }

    fn drain(w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
        const self: *ChannelWriter = @alignCast(@fieldParentPtr("writer", w));
        const io = self.io;

        // Consume buffered bytes first
        if (w.end > 0) {
            self.channel.push(io, w.buffer[0..w.end]) catch return error.WriteFailed;
            w.end = 0;
        }
        if (data.len == 0) return 0;

        var total: usize = 0;
        for (data[0 .. data.len - 1]) |bytes| {
            self.channel.push(io, bytes) catch return error.WriteFailed;
            total += bytes.len;
        }
        const pattern = data[data.len - 1];
        var i: usize = 0;
        while (i < splat) : (i += 1) {
            self.channel.push(io, pattern) catch return error.WriteFailed;
        }
        total += pattern.len * splat;

        // Wake whatever's blocked waiting for tokens
        _ = std.c.write(self.wakeup_fd, &[_]u8{1}, 1);

        return total;
    }
};

/// Shared handoff state between a frontend and the background agent thread:
/// a mailbox for the next prompt plus flags the frontend polls to know
/// whether the agent is thinking or just finished a turn.
pub const AgentState = struct {
    mutex: Io.Mutex = .init,
    cond: Io.Condition = .init,

    pending_text: ?[]const u8 = null,
    should_exit: bool = false,

    thinking: std.atomic.Value(bool) = .init(false),
    agent_finished: std.atomic.Value(bool) = .init(false),

    /// Human-in-the-loop approval handoff (design doc §3.9). The agent
    /// thread parks a question here and blocks on `cond` until the frontend
    /// answers; the question slice is borrowed from the blocked caller, so
    /// it stays valid exactly while `approval_question != null`. Guarded by
    /// `mutex`; `approval_pending` is the lock-free "is there something to
    /// show?" flag the frontend polls each frame.
    approval_question: ?[]const u8 = null,
    approval_answer: ?bool = null,
    approval_pending: std.atomic.Value(bool) = .init(false),
};
