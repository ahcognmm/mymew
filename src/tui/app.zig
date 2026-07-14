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

// ─── TUI state ────────────────────────────────────────────────────────────────

/// A single wrapped physical row: a byte span into `Tui.transcript`. Stored as
/// offsets rather than slices because `transcript` is an ArrayList that can
/// reallocate on append — slices taken before a realloc would dangle.
const Row = struct { start: usize, len: usize };

/// Layout:
///   rows 1..(rows-2)  →  message viewport (owned transcript, own scrolling)
///   row  (rows-1)     →  status line ("thinking...")
///   row  rows         →  input line  ("> ...")
///
/// Runs in the alternate screen buffer: the TUI is the sole source of truth
/// for what's on screen, so the terminal's own scrollback/reflow is never
/// involved and can't leak stale content into view (the class of bug the
/// old primary-screen/scroll-region approach couldn't fully avoid).
pub const Tui = struct {
    gpa: std.mem.Allocator,
    rows: u16,
    cols: u16,
    stdout_fd: posix.fd_t,

    input: std.ArrayList(u8),

    transcript: std.ArrayList(u8),
    rows_cache: std.ArrayList(Row),
    last_line_start: usize = 0,
    /// null = pinned to live tail (auto-follow). Some(x) = fixed absolute
    /// row index of the viewport's top; set when the user scrolls up.
    view_start: ?usize = null,

    dot_phase: u8 = 0,
    last_dot_ns: i64 = 0,

    pub fn init(gpa: std.mem.Allocator, stdout_fd: posix.fd_t) !Tui {
        const size = getTermSize(stdout_fd);
        return .{
            .gpa = gpa,
            .rows = size.rows,
            .cols = size.cols,
            .stdout_fd = stdout_fd,
            .input = .empty,
            .transcript = .empty,
            .rows_cache = .empty,
        };
    }

    pub fn deinit(self: *Tui) void {
        self.input.deinit(self.gpa);
        self.transcript.deinit(self.gpa);
        self.rows_cache.deinit(self.gpa);
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
        self.rawWrite("\x1b[?1049h"); // switch to alternate screen buffer
        self.rawWrite("\x1b[2J"); // clear it
        self.drawStatusLine(false);
        self.drawInputLine();
        self.renderMessages();
    }

    pub fn leave(self: *Tui) void {
        self.rawWrite("\x1b[?1049l"); // restore primary screen exactly as it was
    }

    /// Recomputes terminal geometry after a SIGWINCH, rewraps the whole
    /// transcript at the new width, and redraws everything. Scroll position
    /// re-pins to the live tail rather than trying to preserve it across a
    /// rewrap (row indices from before a width change don't mean anything
    /// after it).
    pub fn handleResize(self: *Tui, thinking: bool) void {
        const size = getTermSize(self.stdout_fd);
        self.rows = size.rows;
        self.cols = size.cols;
        self.view_start = null;
        self.rebuildRowsCache();

        self.rawWrite("\x1b[2J");
        self.drawStatusLine(thinking);
        self.drawInputLine();
        self.renderMessages();
    }

    fn msgViewportRows(self: *Tui) u16 {
        return if (self.rows > 2) self.rows - 2 else 1;
    }

    fn rowText(self: *Tui, r: Row) []const u8 {
        return self.transcript.items[r.start .. r.start + r.len];
    }

    /// Splits `line` (no embedded '\n') into physical rows of at most
    /// `self.cols` visible columns, pushing a Row per wrapped segment.
    /// ANSI escape sequences (ESC '[' ... final-byte) count as zero width
    /// so color codes don't eat into the column budget. `abs_start` is
    /// `line`'s absolute offset within `self.transcript`.
    fn wrapLogicalLine(self: *Tui, abs_start: usize, line: []const u8) void {
        const width: usize = if (self.cols > 0) self.cols else 80;
        if (line.len == 0) {
            self.rows_cache.append(self.gpa, .{ .start = abs_start, .len = 0 }) catch {};
            return;
        }
        var seg_start: usize = 0;
        var col: usize = 0;
        var i: usize = 0;
        while (i < line.len) {
            if (line[i] == 0x1b) {
                const esc_start = i;
                i += 1;
                if (i < line.len and line[i] == '[') {
                    i += 1;
                    while (i < line.len and !(line[i] >= 0x40 and line[i] <= 0x7e)) : (i += 1) {}
                    if (i < line.len) i += 1; // consume final byte
                }
                _ = esc_start;
                continue; // zero width, doesn't count toward col
            }
            col += 1;
            i += 1;
            if (col == width) {
                self.rows_cache.append(self.gpa, .{ .start = abs_start + seg_start, .len = i - seg_start }) catch {};
                seg_start = i;
                col = 0;
            }
        }
        if (seg_start < line.len or seg_start == 0) {
            self.rows_cache.append(self.gpa, .{ .start = abs_start + seg_start, .len = line.len - seg_start }) catch {};
        }
    }

    /// Rewraps from `self.last_line_start` onward: drops cached rows
    /// belonging to the still-open last line, then re-walks just the new
    /// tail of the transcript. Cost is proportional to newly appended bytes,
    /// not total transcript size.
    fn rewrapTail(self: *Tui) void {
        while (self.rows_cache.items.len > 0 and
            self.rows_cache.items[self.rows_cache.items.len - 1].start >= self.last_line_start)
        {
            _ = self.rows_cache.pop();
        }

        var pos = self.last_line_start;
        const buf = self.transcript.items;
        while (std.mem.indexOfScalarPos(u8, buf, pos, '\n')) |nl| {
            self.wrapLogicalLine(pos, buf[pos..nl]);
            pos = nl + 1;
        }
        self.last_line_start = pos;
        self.wrapLogicalLine(pos, buf[pos..]);
    }

    /// Full rewrap of the entire transcript. Only needed on resize (cols
    /// changed, so every previously-cached wrap is invalid).
    fn rebuildRowsCache(self: *Tui) void {
        self.rows_cache.clearRetainingCapacity();
        self.last_line_start = 0;
        self.rewrapTail();
    }

    fn appendTranscript(self: *Tui, bytes: []const u8) void {
        if (bytes.len == 0) return;
        self.transcript.appendSlice(self.gpa, bytes) catch return;
        self.rewrapTail();
        self.renderMessages();
    }

    /// Redraws the message viewport (rows 1..msgViewportRows) from
    /// `rows_cache`, honoring `view_start`. Cost is O(viewport height),
    /// independent of transcript length.
    fn renderMessages(self: *Tui) void {
        const viewport_h = self.msgViewportRows();
        const total = self.rows_cache.items.len;
        const max_start: usize = if (total > viewport_h) total - viewport_h else 0;

        var start = self.view_start orelse max_start;
        if (start > max_start) start = max_start;

        var row: u16 = 0;
        while (row < viewport_h) : (row += 1) {
            self.writeFmt("\x1b[{d};1H", .{row + 1});
            self.rawWrite("\x1b[2K");
            const idx = start + row;
            if (idx < total) self.rawWrite(self.rowText(self.rows_cache.items[idx]));
        }
    }

    pub const ScrollDir = enum { up, down };

    fn scrollBy(self: *Tui, delta: isize) void {
        const viewport_h = self.msgViewportRows();
        const total = self.rows_cache.items.len;
        const max_start: usize = if (total > viewport_h) total - viewport_h else 0;

        const cur: isize = @intCast(self.view_start orelse max_start);
        var new_start = cur - delta; // positive delta scrolls up (toward older content)
        if (new_start < 0) new_start = 0;
        if (new_start > @as(isize, @intCast(max_start))) new_start = @intCast(max_start);

        const new_u: usize = @intCast(new_start);
        self.view_start = if (new_u >= max_start) null else new_u;
        self.renderMessages();
    }

    pub fn scrollLine(self: *Tui, dir: ScrollDir) void {
        self.scrollBy(if (dir == .up) 1 else -1);
    }

    pub fn scrollPage(self: *Tui, dir: ScrollDir) void {
        const page: isize = @max(1, @as(isize, @intCast(self.msgViewportRows())) - 1);
        self.scrollBy(if (dir == .up) page else -page);
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
        self.appendTranscript(bytes);
        self.drawInputLine();
    }

    pub fn onAgentStart(self: *Tui, thinking: bool) void {
        self.last_dot_ns = monoNs();
        self.drawStatusLine(thinking);
        self.drawInputLine();
    }

    pub fn onAgentDone(self: *Tui) void {
        self.appendTranscript("\n\n"); // close the last line + one blank separator
        self.drawStatusLine(false);
        self.drawInputLine();
    }

    /// Returns true if user pressed Enter with non-empty input.
    ///
    /// Callers must intercept a leading ESC (27) themselves via
    /// `readEscapeSequence` before reaching here — see that function's doc
    /// comment for why this can't be done statefully inside `handleKey`.
    pub fn handleKey(self: *Tui, key: u8) bool {
        switch (key) {
            27 => return false, // stray ESC that reached us anyway: no-op
            '\r', '\n' => {
                if (self.input.items.len == 0) return false;
                self.transcript.appendSlice(self.gpa, "\x1b[1mYou:\x1b[0m ") catch return false;
                self.transcript.appendSlice(self.gpa, self.input.items) catch {};
                self.transcript.append(self.gpa, '\n') catch {};
                self.rewrapTail();
                self.view_start = null; // snap to live tail
                self.renderMessages();
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

/// What an escape sequence following a bare ESC byte turned out to mean.
pub const EscapeResult = enum { none, up, down, page_up, page_down };

/// Reads and classifies a CSI/SS3 escape sequence (arrow keys, Home/End,
/// Page Up/Down, function keys, ...) that immediately follows an ESC byte
/// already read from `fd`, so none of its bytes leak into the input field
/// as literal characters. Uses a zero-timeout poll rather than a stateful
/// flag carried across event-loop iterations: a lone Escape keypress has no
/// follow-up bytes queued yet, so a blocking wait-for-next-byte approach
/// cannot tell "standalone Escape" apart from "sequence introducer" without
/// either misinterpreting a later, unrelated keystroke as part of the
/// sequence or adding an artificial delay. Peeking non-blockingly resolves
/// this immediately: if nothing is queued right after ESC, it's a standalone
/// Escape (no-op, nothing consumed).
pub fn readEscapeSequence(fd: posix.fd_t) EscapeResult {
    var pfd = [_]posix.pollfd{.{ .fd = fd, .events = posix.POLL.IN, .revents = 0 }};
    if ((posix.poll(&pfd, 0) catch 0) <= 0) return .none;

    var b: [1]u8 = undefined;
    if (std.c.read(fd, &b, 1) <= 0) return .none;
    if (b[0] != '[' and b[0] != 'O') return .none; // not a CSI/SS3 introducer

    if (b[0] == 'O') {
        // SS3: exactly one more byte (F1-F4 etc), not used here.
        if ((posix.poll(&pfd, 0) catch 0) > 0) _ = std.c.read(fd, &b, 1);
        return .none;
    }

    var param_buf: [8]u8 = undefined;
    var param_len: usize = 0;
    while ((posix.poll(&pfd, 0) catch 0) > 0) {
        if (std.c.read(fd, &b, 1) <= 0) return .none;
        if (b[0] >= 0x40 and b[0] <= 0x7e) {
            // Final byte: sequence done.
            return switch (b[0]) {
                'A' => .up,
                'B' => .down,
                '~' => if (std.mem.eql(u8, param_buf[0..param_len], "5"))
                    .page_up
                else if (std.mem.eql(u8, param_buf[0..param_len], "6"))
                    .page_down
                else
                    .none,
                else => .none,
            };
        }
        if (param_len < param_buf.len) {
            param_buf[param_len] = b[0];
            param_len += 1;
        }
    }
    return .none;
}

// ─── terminal resize (SIGWINCH) ────────────────────────────────────────────────

var resize_pending: std.atomic.Value(bool) = .init(false);
var resize_wakeup_fd: posix.fd_t = -1;

fn onSigwinch(_: posix.SIG) callconv(.c) void {
    resize_pending.store(true, .release);
    // Nudge the render loop's poll() awake immediately. Without this, a
    // dragged/held resize fires SIGWINCH repeatedly; Zig's posix.poll retries
    // its *entire original timeout* on EINTR (see std/posix.zig's `.INTR =>
    // continue`), so as long as signals keep arriving faster than the
    // timeout, poll() never actually returns — the redraw only happens once
    // resizing pauses. Writing to the same self-pipe used for agent-channel
    // wakeups guarantees the very next poll() call sees ready data and
    // returns right away. write() is async-signal-safe.
    if (resize_wakeup_fd >= 0) _ = std.c.write(resize_wakeup_fd, &[_]u8{1}, 1);
}

/// Installs a SIGWINCH handler that raises a flag and wakes `wakeup_fd`;
/// call `takeResized()` from the render loop to consume the flag.
pub fn installResizeHandler(wakeup_fd: posix.fd_t) void {
    resize_wakeup_fd = wakeup_fd;
    const act: posix.Sigaction = .{
        .handler = .{ .handler = &onSigwinch },
        .mask = std.mem.zeroes(posix.sigset_t),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.WINCH, &act, null);
}

/// Returns true (once) if a resize was signaled since the last call.
pub fn takeResized() bool {
    return resize_pending.swap(false, .acq_rel);
}
