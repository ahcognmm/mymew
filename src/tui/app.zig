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
/// `is_thinking` marks rows that fall inside a provider-marked reasoning
/// span (see `wrapLogicalLine`), so `renderMessages` can draw the left-hand
/// gutter — that decoration is a TUI concern, not something the provider
/// should embed into the byte stream itself.
const Row = struct { start: usize, len: usize, is_thinking: bool = false };

/// SGR markers a provider uses to bracket a reasoning/thinking span in the
/// token stream (see `core/llm.zig`). The TUI watches for exactly these
/// sequences while wrapping lines to know where to draw the thinking gutter.
const thinking_start_sgr = "\x1b[2;3m";
const thinking_end_sgr = "\x1b[0m";

/// Left-hand gutter drawn on every physical row of a thinking span: a cyan
/// vertical bar plus a space, so the whole span reads as one continuous rule
/// from top to bottom. Occupies `thinking_gutter_cols` visible columns,
/// which `wrapLogicalLine` reserves when wrapping thinking rows.
const thinking_gutter = "\x1b[36m\u{2502}\x1b[39m ";
const thinking_gutter_cols: usize = 2;

/// Tool-call status dot markers (see `core/engine.zig` for the writer
/// side — kept byte-for-byte in sync there; this file has no import of it,
/// same convention as `thinking_start_sgr` above). `tool_pending_sgr` is
/// just the 5-byte color-set prefix `wrapLogicalLine`'s escape scanner
/// actually matches against (it only ever sees one CSI sequence at a time,
/// not the surrounding dot character) — which is also the first 5 bytes of
/// every `tool_dot_len`-byte dot unit below, so recording that escape's
/// start position gives the offset of the whole dot.
const tool_pending_sgr = "\x1b[33m";
const tool_dot_len: usize = 12; // "\x1b[NNm" (5) + "●" (3 UTF-8 bytes) + "\x1b[0m" (4)
const tool_dot_pending_bright = "\x1b[33m\u{25CF}\x1b[0m";
const tool_dot_pending_dim = "\x1b[90m\u{25CF}\x1b[0m";
const tool_dot_ok = "\x1b[32m\u{25CF}\x1b[0m";
const tool_dot_fail = "\x1b[31m\u{25CF}\x1b[0m";
/// Zero-width, no visible content of their own — instantaneous "patch the
/// pending dot now" signals, not a start/end pair bracketing a span.
/// Undefined SGR sub-codes real terminals silently ignore if any of this
/// ever leaks through unstripped.
const tool_done_ok_sgr = "\x1b[900m";
const tool_done_fail_sgr = "\x1b[901m";

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

    /// Whether the scan position is currently inside a provider-marked
    /// thinking span (see `thinking_start_sgr`/`thinking_end_sgr`). Persists
    /// across incremental `wrapLogicalLine` calls since a span can outlive
    /// any single call as tokens stream in.
    thinking_state: bool = false,

    /// Byte offset in `self.transcript` of the currently in-flight tool
    /// call's dot (see `tool_pending_sgr`), or null if no tool call is
    /// pending. There is at most one at a time — tool calls run
    /// sequentially, never concurrently, so no stack/map is needed. Set by
    /// `wrapLogicalLine` on seeing `tool_pending_sgr`; cleared by
    /// `patchToolDot` once the matching done-signal patches it to its
    /// final color.
    pending_tool_dot: ?usize = null,
    /// Toggled each `tickDots` call while a tool is pending, to alternate
    /// the dot between `tool_dot_pending_bright`/`_dim` — this file does
    /// its own blink animation rather than relying on terminal-native SGR
    /// blink support, which many terminals ignore.
    tool_dot_blink_on: bool = false,

    dot_phase: u8 = 0,
    last_dot_ns: i64 = 0,

    /// Monotonic timestamp captured by `beginTurn()` when the user submits a
    /// prompt; `onAgentDone()` diffs against it to report how long the whole
    /// round trip (submit → final response) took.
    turn_start_ns: i64 = 0,

    /// Set via `setStyle()`, read directly by `drawStatusLine`. Deliberately
    /// a plain bool, not `core.engine.Style` — this file has no dependency
    /// on `core/*` and shouldn't gain one just for a status-line label.
    plan_execute: bool = false,

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

    fn thinkingWidth(base: usize, is_thinking: bool) usize {
        if (!is_thinking) return base;
        return if (base > thinking_gutter_cols) base - thinking_gutter_cols else 1;
    }

    /// Overwrites the currently pending tool dot's `tool_dot_len` bytes in
    /// place with `final_dot` (`tool_dot_ok`/`tool_dot_fail`) and clears
    /// `pending_tool_dot`. Safe to call with no pending dot (no-op) — a
    /// done-signal arriving with nothing pending shouldn't happen, but
    /// isn't worth crashing over. `self.transcript` only ever grows via
    /// `appendSlice`, never shifts, so a previously recorded offset stays
    /// valid indefinitely; `rows_cache` entries reference this same byte
    /// range by offset, not by copied text, so the very next
    /// `renderMessages()` call picks up the patched color automatically.
    fn patchToolDot(self: *Tui, final_dot: []const u8) void {
        const offset = self.pending_tool_dot orelse return;
        self.pending_tool_dot = null;
        if (offset + tool_dot_len > self.transcript.items.len) return;
        @memcpy(self.transcript.items[offset .. offset + tool_dot_len], final_dot);
    }

    /// Splits `line` (no embedded '\n') into physical rows of at most
    /// `self.cols` visible columns, pushing a Row per wrapped segment.
    /// ANSI escape sequences (ESC '[' ... final-byte) count as zero width
    /// so color codes don't eat into the column budget. `abs_start` is
    /// `line`'s absolute offset within `self.transcript`.
    ///
    /// Also watches for `thinking_start_sgr`/`thinking_end_sgr` to update
    /// `self.thinking_state` and tags each pushed Row with it, reserving
    /// `thinking_gutter_cols` of width for thinking rows so `renderMessages`
    /// can prepend the gutter without overflowing the terminal width.
    fn wrapLogicalLine(self: *Tui, abs_start: usize, line: []const u8) void {
        const base_width: usize = if (self.cols > 0) self.cols else 80;
        if (line.len == 0) {
            self.rows_cache.append(self.gpa, .{ .start = abs_start, .len = 0, .is_thinking = self.thinking_state }) catch {};
            return;
        }
        var seg_start: usize = 0;
        var seg_is_thinking = self.thinking_state;
        var width = thinkingWidth(base_width, seg_is_thinking);
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
                const seq = line[esc_start..i];
                if (std.mem.eql(u8, seq, thinking_start_sgr)) {
                    self.thinking_state = true;
                } else if (std.mem.eql(u8, seq, thinking_end_sgr)) {
                    self.thinking_state = false;
                } else if (std.mem.eql(u8, seq, tool_pending_sgr)) {
                    self.pending_tool_dot = abs_start + esc_start;
                    // The bytes just written are already the bright
                    // variant (engine.zig writes `tool_dot_pending`
                    // unconditionally) — start `tickDots`' toggle from
                    // "currently bright" so its first flip immediately
                    // shows a visible change instead of a no-op re-paint
                    // of the same bytes that happens to land on a stale
                    // `tool_dot_blink_on` value left over from a previous
                    // tool call.
                    self.tool_dot_blink_on = true;
                } else if (std.mem.eql(u8, seq, tool_done_ok_sgr)) {
                    self.patchToolDot(tool_dot_ok);
                } else if (std.mem.eql(u8, seq, tool_done_fail_sgr)) {
                    self.patchToolDot(tool_dot_fail);
                }
                // Nothing visible has been emitted into the current segment
                // yet, so let the new state apply to it retroactively — this
                // is what makes the common case (toggle sits at the very
                // start of a line) reserve gutter width correctly.
                if (col == 0) {
                    seg_is_thinking = self.thinking_state;
                    width = thinkingWidth(base_width, seg_is_thinking);
                }
                continue; // zero width, doesn't count toward col
            }
            col += 1;
            i += 1;
            if (col == width) {
                self.rows_cache.append(self.gpa, .{ .start = abs_start + seg_start, .len = i - seg_start, .is_thinking = seg_is_thinking }) catch {};
                seg_start = i;
                col = 0;
                seg_is_thinking = self.thinking_state;
                width = thinkingWidth(base_width, seg_is_thinking);
            }
        }
        if (seg_start < line.len or seg_start == 0) {
            self.rows_cache.append(self.gpa, .{ .start = abs_start + seg_start, .len = line.len - seg_start, .is_thinking = seg_is_thinking }) catch {};
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
    /// changed, so every previously-cached wrap is invalid). Resets
    /// `thinking_state` since the rescan starts from byte 0 and must derive
    /// the state fresh rather than carry over whatever it was mid-stream.
    fn rebuildRowsCache(self: *Tui) void {
        self.rows_cache.clearRetainingCapacity();
        self.last_line_start = 0;
        self.thinking_state = false;
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
            if (idx < total) {
                const r = self.rows_cache.items[idx];
                if (r.is_thinking) self.rawWrite(thinking_gutter);
                self.rawWrite(self.rowText(r));
            }
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

    /// Sets the orchestration-style tag drawn in the status line and
    /// redraws it immediately (see `plan_execute` field doc comment).
    pub fn setStyle(self: *Tui, plan_execute: bool, thinking: bool) void {
        self.plan_execute = plan_execute;
        self.drawStatusLine(thinking);
    }

    fn drawStatusLine(self: *Tui, thinking: bool) void {
        self.writeFmt("\x1b[{d};1H", .{self.rows - 1});
        self.rawWrite("\x1b[2K");
        self.rawWrite(if (self.plan_execute) "\x1b[2m[plan]\x1b[0m " else "\x1b[2m[react]\x1b[0m ");
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
        if (self.pending_tool_dot) |offset| {
            self.tool_dot_blink_on = !self.tool_dot_blink_on;
            const dot = if (self.tool_dot_blink_on) tool_dot_pending_bright else tool_dot_pending_dim;
            if (offset + tool_dot_len <= self.transcript.items.len) {
                @memcpy(self.transcript.items[offset .. offset + tool_dot_len], dot);
            }
            self.renderMessages();
        }
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

    /// Call once, right when a prompt is handed off to the agent, to mark
    /// the start of the round trip that `onAgentDone()` will time.
    pub fn beginTurn(self: *Tui) void {
        self.turn_start_ns = monoNs();
    }

    pub fn onAgentDone(self: *Tui) void {
        const elapsed_ns = monoNs() - self.turn_start_ns;
        const elapsed_s = @as(f64, @floatFromInt(@max(elapsed_ns, 0))) / 1_000_000_000.0;
        var buf: [64]u8 = undefined;
        // Close the response's last (open) line, report round-trip time on
        // its own dim line, then two blank separators before the next prompt.
        const suffix = std.fmt.bufPrint(&buf, "\n\x1b[2m[{d:.1}s]\x1b[0m\n\n\n", .{elapsed_s}) catch "\n\n\n";
        self.appendTranscript(suffix);
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
                self.transcript.appendSlice(self.gpa, "\n\n") catch {}; // blank line before the response
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

const testing = std.testing;

test "tool-call marker: pending dot is detected and patched in place on the done-signal" {
    const null_fd = try posix.openatZ(posix.AT.FDCWD, "/dev/null", .{ .ACCMODE = .WRONLY }, 0);
    defer _ = std.c.close(null_fd);

    var ui = try Tui.init(testing.allocator, null_fd);
    defer ui.deinit();

    // Matches exactly what core/engine.zig writes for a tool call: the
    // pending marker (no closing newline yet — dispatch is still "running").
    ui.appendOutput("\n[" ++ tool_dot_pending_bright ++ " calculator: add 2 and 3]");
    try testing.expect(ui.pending_tool_dot != null);
    const offset = ui.pending_tool_dot.?;
    try testing.expectEqualStrings(tool_dot_pending_bright, ui.transcript.items[offset .. offset + tool_dot_len]);

    // Blink tick: dot alternates to the dim variant while still pending.
    ui.last_dot_ns = 0; // force tickDots' 400ms threshold to have elapsed
    _ = ui.tickDots(false);
    try testing.expect(ui.pending_tool_dot != null);
    try testing.expectEqualStrings(tool_dot_pending_dim, ui.transcript.items[offset .. offset + tool_dot_len]);

    // The done-signal arrives (dispatch resolved successfully) — patches
    // the SAME bytes to green and clears pending state; the surrounding
    // "[calculator: add 2 and 3]" text is never re-emitted or altered.
    ui.appendOutput(tool_done_ok_sgr ++ "\n");
    try testing.expect(ui.pending_tool_dot == null);
    try testing.expectEqualStrings(tool_dot_ok, ui.transcript.items[offset .. offset + tool_dot_len]);
    try testing.expect(std.mem.indexOf(u8, ui.transcript.items, "calculator: add 2 and 3") != null);

    // A further blink tick is a no-op once nothing is pending.
    ui.last_dot_ns = 0;
    _ = ui.tickDots(false);
    try testing.expectEqualStrings(tool_dot_ok, ui.transcript.items[offset .. offset + tool_dot_len]);
}
