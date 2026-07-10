const std = @import("std");
const posix = std.posix;
const Io = std.Io;

fn monoNs() i64 {
    var ts: posix.timespec = .{ .sec = 0, .nsec = 0 };
    _ = std.c.clock_gettime(posix.CLOCK.MONOTONIC, &ts);
    return ts.sec * 1_000_000_000 + ts.nsec;
}

// ─── terminal primitives ──────────────────────────────────────────────────────

pub fn enableRawMode(fd: posix.fd_t) !posix.termios {
    const orig = try posix.tcgetattr(fd);
    var raw = orig;
    raw.iflag.BRKINT = false;
    raw.iflag.ICRNL = false;
    raw.iflag.INPCK = false;
    raw.iflag.ISTRIP = false;
    raw.iflag.IXON = false;
    raw.oflag.OPOST = false;
    raw.cflag.CSIZE = .CS8;
    raw.lflag.ECHO = false;
    raw.lflag.ICANON = false;
    raw.lflag.IEXTEN = false;
    raw.lflag.ISIG = false;
    raw.cc[@intFromEnum(posix.V.MIN)] = 1;
    raw.cc[@intFromEnum(posix.V.TIME)] = 0;
    try posix.tcsetattr(fd, .FLUSH, raw);
    return orig;
}

pub fn disableRawMode(fd: posix.fd_t, orig: posix.termios) void {
    posix.tcsetattr(fd, .FLUSH, orig) catch {};
}

pub fn getTermSize(fd: posix.fd_t) struct { rows: u16, cols: u16 } {
    var ws: posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
    _ = std.c.ioctl(@intCast(fd), std.c.T.IOCGWINSZ, &ws);
    return .{
        .rows = if (ws.row > 0) ws.row else 24,
        .cols = if (ws.col > 0) ws.col else 80,
    };
}

// ─── shared channel (agent → render thread) ───────────────────────────────────

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

// ─── custom Io.Writer that feeds the channel ──────────────────────────────────

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

        // Wake the render loop immediately
        _ = std.c.write(self.wakeup_fd, &[_]u8{1}, 1);

        return total;
    }
};

// ─── TUI state ────────────────────────────────────────────────────────────────

/// Layout:
///   rows 1..(rows-2)  →  scroll region (messages)
///   row  (rows-1)     →  status line ("thinking...")
///   row  rows         →  input line  ("> ...")
pub const Tui = struct {
    gpa: std.mem.Allocator,
    rows: u16,
    cols: u16,
    stdout_fd: posix.fd_t,

    pending: std.ArrayList(u8),
    input: std.ArrayList(u8),

    dot_phase: u8 = 0,
    last_dot_ns: i64 = 0,

    pub fn init(gpa: std.mem.Allocator, stdout_fd: posix.fd_t) !Tui {
        const size = getTermSize(stdout_fd);
        return .{
            .gpa = gpa,
            .rows = size.rows,
            .cols = size.cols,
            .stdout_fd = stdout_fd,
            .pending = .empty,
            .input = .empty,
        };
    }

    pub fn deinit(self: *Tui) void {
        self.pending.deinit(self.gpa);
        self.input.deinit(self.gpa);
    }

    fn rawWrite(self: *Tui, bytes: []const u8) void {
        var written: usize = 0;
        while (written < bytes.len) {
            const n = std.c.write(self.stdout_fd, bytes.ptr + written, bytes.len - written);
            if (n <= 0) break;
            written += @intCast(n);
        }
    }

    fn writeFmt(self: *Tui, comptime fmt: []const u8, args: anytype) void {
        var buf: [256]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
        self.rawWrite(s);
    }

    pub fn enter(self: *Tui) void {
        self.rawWrite("\x1b[?1049h"); // alternate screen
        self.rawWrite("\x1b[2J"); // clear
        self.rawWrite("\x1b[1;1H"); // cursor to top-left
        self.setScrollRegion();
        self.rawWrite("\x1b7"); // DECSC: save initial msg cursor (top of scroll region)
        self.drawStatusLine(false);
        self.drawInputLine();
    }

    pub fn leave(self: *Tui) void {
        self.rawWrite("\x1b[r"); // reset scroll region
        self.rawWrite("\x1b[?1049l"); // exit alternate screen
    }

    fn msgBottom(self: *Tui) u16 {
        return if (self.rows > 2) self.rows - 2 else 1;
    }

    fn setScrollRegion(self: *Tui) void {
        self.writeFmt("\x1b[1;{d}r", .{self.msgBottom()});
    }

    fn drawStatusLine(self: *Tui, thinking: bool) void {
        self.writeFmt("\x1b[{d};1H", .{self.rows - 1});
        self.rawWrite("\x1b[2K");
        if (thinking) {
            const dots: []const u8 = switch (self.dot_phase) {
                0 => ".",
                1 => "..",
                else => "...",
            };
            self.rawWrite("\x1b[2mthinking");
            self.rawWrite(dots);
            self.rawWrite("\x1b[0m");
        }
    }

    fn drawInputLine(self: *Tui) void {
        self.writeFmt("\x1b[{d};1H", .{self.rows});
        self.rawWrite("\x1b[2K");
        self.rawWrite("> ");
        self.rawWrite(self.input.items);
    }

    pub fn tickDots(self: *Tui, thinking: bool) bool {
        const now = monoNs();
        const elapsed_ms: i64 = @divTrunc(now - self.last_dot_ns, 1_000_000);
        if (elapsed_ms < 400) return false;
        self.last_dot_ns = now;
        self.dot_phase = (self.dot_phase + 1) % 3;
        self.drawStatusLine(thinking);
        self.drawInputLine();
        return true;
    }

    pub fn appendOutput(self: *Tui, bytes: []const u8) void {
        if (bytes.len == 0) return;
        // DECRC: restore cursor to where we left off in the scroll region.
        // This lets successive chunks continue on the same line without
        // repositioning to msgBottom on every call (which would overwrite text).
        self.rawWrite("\x1b8");
        // In raw mode OPOST is off: bare \n only moves down, no CR.
        // Translate \n → \r\n so each new line starts at column 1.
        var start: usize = 0;
        for (bytes, 0..) |b, i| {
            if (b == '\n') {
                if (i > start) self.rawWrite(bytes[start..i]);
                self.rawWrite("\r\n");
                start = i + 1;
            }
        }
        if (start < bytes.len) self.rawWrite(bytes[start..]);
        self.rawWrite("\x1b7"); // DECSC: save cursor position in scroll region
        self.drawInputLine();
    }

    pub fn onAgentStart(self: *Tui, thinking: bool) void {
        self.last_dot_ns = monoNs();
        self.drawStatusLine(thinking);
        self.drawInputLine();
    }

    pub fn onAgentDone(self: *Tui) void {
        self.rawWrite("\x1b8"); // restore msg cursor
        self.rawWrite("\r\n");  // blank separator after response
        self.rawWrite("\x1b7"); // save cursor
        self.drawStatusLine(false);
        self.drawInputLine();
    }

    /// Returns true if user pressed Enter with non-empty input.
    pub fn handleKey(self: *Tui, key: u8) bool {
        switch (key) {
            '\r', '\n' => {
                if (self.input.items.len == 0) return false;
                // Echo "You: ..." in the scroll region, restore msg cursor first
                self.rawWrite("\x1b8"); // restore msg cursor
                self.rawWrite("\r\n");  // new line (scrolls if at bottom of region)
                self.rawWrite("\x1b[1mYou:\x1b[0m ");
                self.rawWrite(self.input.items);
                self.rawWrite("\r\n"); // advance past user line so agent output starts fresh
                self.rawWrite("\x1b7"); // save cursor at start of agent output line
                return true;
            },
            127, 8 => {
                if (self.input.items.len > 0) {
                    _ = self.input.pop();
                    self.drawInputLine();
                }
                return false;
            },
            else => {
                if (key >= 32 and key < 127) {
                    self.input.append(self.gpa, key) catch {};
                    self.drawInputLine();
                }
                return false;
            },
        }
    }

    /// Returns owned copy of current input and resets the buffer.
    pub fn takeInput(self: *Tui) []const u8 {
        const text: []const u8 = self.gpa.dupe(u8, self.input.items) catch "";
        self.input.clearRetainingCapacity();
        self.drawInputLine();
        return text;
    }
};

// ─── shared agent state ───────────────────────────────────────────────────────

pub const AgentState = struct {
    mutex: Io.Mutex = .init,
    cond: Io.Condition = .init,

    pending_text: ?[]const u8 = null,
    should_exit: bool = false,

    thinking: std.atomic.Value(bool) = .init(false),
    agent_finished: std.atomic.Value(bool) = .init(false),
};
