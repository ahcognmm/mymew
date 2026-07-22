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

// ─── panic-safe terminal restoration ─────────────────────────────────────────
//
// Zig panics do not run `defer`s, so without this a panic exits with raw
// mode + the alternate screen still active — the terminal is left unusable
// and the panic trace lands invisibly on the alt screen. `main.zig`'s root
// panic handler calls `emergencyRestore()` before the default handler
// prints. Globals (not Tui fields) because a panic handler has no access
// to stack state; write() and tcsetattr are async-signal-safe.

var restore_in_fd: posix.fd_t = -1;
var restore_out_fd: posix.fd_t = -1;
var restore_termios: ?posix.termios = null;

pub fn registerPanicRestore(in_fd: posix.fd_t, out_fd: posix.fd_t, orig: posix.termios) void {
    restore_in_fd = in_fd;
    restore_out_fd = out_fd;
    restore_termios = orig;
}

/// Leaves the alt screen, disables mouse reporting, shows the cursor, and
/// restores the original termios. Safe to call multiple times or when
/// nothing was registered (no-op). Idempotent on purpose: it runs both from
/// the panic path and (harmlessly) after a clean `leave()`.
pub fn emergencyRestore() void {
    if (restore_out_fd >= 0) {
        const seq = "\x1b[?1000l\x1b[?1006l\x1b[?1049l\x1b[?25h";
        _ = std.c.write(restore_out_fd, seq, seq.len);
    }
    if (restore_termios) |orig| {
        if (restore_in_fd >= 0) posix.tcsetattr(restore_in_fd, .FLUSH, orig) catch {};
    }
}

// ─── theme ────────────────────────────────────────────────────────────────────

/// Semantic color tokens for everything the TUI itself draws (chrome,
/// prompt, gutters, "You:" label). With `colors == false` (NO_COLOR /
/// TERM=dumb) every token is empty AND transcript bytes are stripped of
/// SGR sequences at render time — the stream itself (thinking/error span
/// markers, tool-dot units) is a wire format shared with `core/*` writers
/// and is never themed; only what reaches the terminal changes.
pub const Theme = struct {
    colors: bool,
    bold: []const u8,
    dim: []const u8,
    reset: []const u8,
    accent: []const u8, // cyan — prompt, thinking gutter, todo-panel gutter
    err_c: []const u8, // red — error gutter
    warn: []const u8, // yellow — busy spinner, in_progress todo item
    ok: []const u8, // green — completed todo item
    code_bar: []const u8, // magenta — code-block gutter, distinct from accent/err/warn/ok
    code_bg: []const u8, // 256-color dark-gray tint painted behind fenced code rows
    inline_code: []const u8, // bold accent used for `inline code` spans within a row
    fg_reset: []const u8, // drops foreground to terminal default without touching an active bg

    pub fn init(colors: bool) Theme {
        if (!colors) return .{
            .colors = false,
            .bold = "",
            .dim = "",
            .reset = "",
            .accent = "",
            .err_c = "",
            .warn = "",
            .ok = "",
            .code_bar = "",
            .code_bg = "",
            .inline_code = "",
            .fg_reset = "",
        };
        return .{
            .colors = true,
            .bold = "\x1b[1m",
            .dim = "\x1b[2m",
            .reset = "\x1b[0m",
            .accent = "\x1b[36m",
            .err_c = "\x1b[31m",
            .warn = "\x1b[33m",
            .ok = "\x1b[32m",
            .code_bar = "\x1b[35m",
            .code_bg = "\x1b[48;5;236m",
            .inline_code = "\x1b[1;36m",
            .fg_reset = "\x1b[39m",
        };
    }
};

// ─── unicode width ────────────────────────────────────────────────────────────

const Decoded = struct { cp: u21, len: usize };

/// Decodes one codepoint; invalid/truncated UTF-8 degrades to "one byte,
/// width 1" so garbage input can only miswrap, never stall or split worse.
pub fn decodeCp(bytes: []const u8) Decoded {
    const len = std.unicode.utf8ByteSequenceLength(bytes[0]) catch return .{ .cp = bytes[0], .len = 1 };
    if (len > bytes.len) return .{ .cp = bytes[0], .len = 1 };
    const cp = std.unicode.utf8Decode(bytes[0..len]) catch return .{ .cp = bytes[0], .len = 1 };
    return .{ .cp = cp, .len = len };
}

const wide_ranges = [_][2]u21{
    .{ 0x1100, 0x115F }, // Hangul Jamo
    .{ 0x231A, 0x231B }, .{ 0x2329, 0x232A }, .{ 0x23E9, 0x23EC },
    .{ 0x25FD, 0x25FE }, .{ 0x2614, 0x2615 }, .{ 0x2648, 0x2653 },
    .{ 0x26AA, 0x26AB }, .{ 0x2E80, 0x303E }, // CJK radicals, punctuation
    .{ 0x3041, 0x33FF }, // kana, CJK symbols
    .{ 0x3400, 0x4DBF }, .{ 0x4E00, 0x9FFF }, // CJK ideographs
    .{ 0xA000, 0xA4CF }, // Yi
    .{ 0xAC00, 0xD7A3 }, // Hangul syllables
    .{ 0xF900, 0xFAFF }, .{ 0xFE30, 0xFE4F },
    .{ 0xFF00, 0xFF60 }, .{ 0xFFE0, 0xFFE6 }, // fullwidth forms
    .{ 0x1F300, 0x1F64F }, .{ 0x1F680, 0x1F6FF }, // emoji
    .{ 0x1F900, 0x1FAFF },
    .{ 0x20000, 0x3FFFD }, // CJK extensions
};

const zero_ranges = [_][2]u21{
    .{ 0x0300, 0x036F }, .{ 0x0483, 0x0489 }, .{ 0x0591, 0x05BD },
    .{ 0x1AB0, 0x1AFF }, .{ 0x1DC0, 0x1DFF }, .{ 0x20D0, 0x20FF },
};

/// Display width of one codepoint: 0 (combining marks, ZWJ, variation
/// selectors), 2 (East Asian Wide/Fullwidth + emoji presentation), else 1.
/// A compact wcwidth: grapheme clusters are not segmented (a ZWJ emoji
/// family over-counts by design — miswrapping by a cell beats splitting
/// mid-codepoint, see docs/feat/tui-redesign.md §6).
pub fn charWidth(cp: u21) u2 {
    if (cp == 0x200B or cp == 0x200C or cp == 0x200D) return 0;
    if (cp == 0xFE0E or cp == 0xFE0F) return 0;
    for (zero_ranges) |r| {
        if (cp >= r[0] and cp <= r[1]) return 0;
    }
    for (wide_ranges) |r| {
        if (cp >= r[0] and cp <= r[1]) return 2;
    }
    return 1;
}

/// Sum of `charWidth` over `text` (no escape sequences expected).
/// Longest prefix of `text` fitting in `max_cols` display columns, cut at a
/// codepoint boundary (never mid-UTF-8). Used by the bar's approval prompt
/// to truncate the question without breaking the row.
pub fn truncateCols(text: []const u8, max_cols: usize) []const u8 {
    var w: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const d = decodeCp(text[i..]);
        const cw = charWidth(d.cp);
        if (w + cw > max_cols) break;
        w += cw;
        i += d.len;
    }
    return text[0..i];
}

pub fn displayWidth(text: []const u8) usize {
    var w: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const d = decodeCp(text[i..]);
        w += charWidth(d.cp);
        i += d.len;
    }
    return w;
}

// ─── stream markers (wire format, duplicated from core/* by convention) ──────

/// SGR markers a provider uses to bracket a reasoning/thinking span in the
/// token stream (see `core/llm.zig`). The TUI watches for exactly these
/// sequences while wrapping lines to know where to draw the thinking gutter.
const thinking_start_sgr = "\x1b[2;3;36m";
/// SGR markers `core/agent.zig` uses to bracket an error/diagnostic span
/// (escalation reports, `[error: ...]` lines) — dim red as a plain-stream
/// fallback, red gutter here.
const error_start_sgr = "\x1b[2;31m";
/// Ends either span kind. Shared with plain resets in the stream; a reset
/// outside a span is a harmless none→none transition.
const span_end_sgr = "\x1b[0m";

/// Tool-call status markers (see `core/engine.zig` for the writer side —
/// kept byte-for-byte in sync there; this file has no import of it, same
/// convention as `thinking_start_sgr` above). All four are the same 12
/// bytes so in-place patching never shifts anything. The finals are `✓`/`✗`
/// (each 3-byte UTF-8, like `●`) so ok/fail stays legible without color.
const tool_pending_sgr = "\x1b[33m";
const tool_dot_len: usize = 12; // "\x1b[NNm" (5) + 3-byte UTF-8 glyph + "\x1b[0m" (4)
const tool_dot_pending_bright = "\x1b[33m\u{25CF}\x1b[0m";
const tool_dot_pending_dim = "\x1b[90m\u{25CF}\x1b[0m";
const tool_dot_ok = "\x1b[32m\u{2713}\x1b[0m";
const tool_dot_fail = "\x1b[31m\u{2717}\x1b[0m";
/// Zero-width "patch the pending dot now" signals — undefined SGR
/// sub-codes real terminals silently ignore if they ever leak through.
const tool_done_ok_sgr = "\x1b[900m";
const tool_done_fail_sgr = "\x1b[901m";

// ─── transcript rows ──────────────────────────────────────────────────────────

/// Which left-hand gutter a transcript row renders with. `.thinking` spans
/// come from the provider's reasoning markers; `.err` spans from
/// `core/agent.zig`'s escalation/error markers; `.code` spans from a
/// plain-text ``` fence in the assistant's own reply — unlike the other two,
/// there is no wire SGR marker for it, `wrapLogicalLine` detects the fence
/// bytes directly, since fenced code is just markdown the model wrote.
pub const Gutter = enum { none, thinking, err, code };

/// A single wrapped physical row: a byte span into `Tui.transcript`. Stored
/// as offsets rather than slices because `transcript` is an ArrayList that
/// can reallocate on append — slices taken before a realloc would dangle.
const Row = struct { start: usize, len: usize, gutter: Gutter = .none };

/// Gutter prefix occupies this many visible columns; `wrapLogicalLine`
/// reserves them when wrapping guttered rows.
const gutter_cols: usize = 2;

// ─── composer ─────────────────────────────────────────────────────────────────

/// One wrapped visual row of the composer: a byte span into its text.
pub const VRow = struct { start: usize, len: usize };

/// Wraps plain text (no escape sequences) into visual rows of at most
/// `width` display columns, breaking at '\n' and at width. Always produces
/// at least one row (possibly empty), so a cursor position always maps to
/// a row.
pub fn wrapPlain(gpa: std.mem.Allocator, out: *std.ArrayList(VRow), text: []const u8, width: usize) void {
    out.clearRetainingCapacity();
    const w_max: usize = if (width == 0) 1 else width;
    var seg_start: usize = 0;
    var col: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '\n') {
            out.append(gpa, .{ .start = seg_start, .len = i - seg_start }) catch return;
            seg_start = i + 1;
            col = 0;
            i += 1;
            continue;
        }
        const d = decodeCp(text[i..]);
        const cw: usize = charWidth(d.cp);
        if (col + cw > w_max and col > 0) {
            out.append(gpa, .{ .start = seg_start, .len = i - seg_start }) catch return;
            seg_start = i;
            col = 0;
        }
        col += cw;
        i += d.len;
    }
    out.append(gpa, .{ .start = seg_start, .len = text.len - seg_start }) catch return;
}

pub const RowCol = struct { row: usize, col: usize };

/// Maps a byte offset (`cursor`, 0..text.len inclusive) to its visual
/// row/column within `rows` (as produced by `wrapPlain`). At a wrap
/// boundary the cursor belongs to the start of the *next* row, matching
/// where the next typed character would land.
pub fn cursorRowCol(rows: []const VRow, text: []const u8, cursor: usize) RowCol {
    var row: usize = 0;
    for (rows, 0..) |r, idx| {
        if (r.start <= cursor) row = idx else break;
    }
    const r = rows[row];
    const upto = @min(cursor, r.start + r.len);
    return .{ .row = row, .col = displayWidth(text[r.start..upto]) };
}

/// Byte offset within visual row `r` whose column is closest to (but not
/// past) `target` — for up/down movement preserving the column.
fn byteAtCol(text: []const u8, r: VRow, target: usize) usize {
    var col: usize = 0;
    var i: usize = r.start;
    const end = r.start + r.len;
    while (i < end) {
        const d = decodeCp(text[i..]);
        const cw: usize = charWidth(d.cp);
        if (col + cw > target) return i;
        col += cw;
        i += d.len;
    }
    return end;
}

/// The input editor: UTF-8 text, a byte-offset cursor (always on a
/// codepoint boundary), and prompt history. Pure data + operations — no
/// terminal I/O — so every editing op is unit-testable.
pub const Composer = struct {
    text: std.ArrayList(u8) = .empty,
    cursor: usize = 0,
    history: std.ArrayList([]const u8) = .empty,
    /// null = editing live text; otherwise index into `history` currently
    /// recalled. Any edit snaps back to live (standard readline behavior).
    hist_idx: ?usize = null,
    /// Live text stashed while browsing history, restored when the user
    /// arrows back past the newest entry.
    stash: std.ArrayList(u8) = .empty,

    pub fn deinit(self: *Composer, gpa: std.mem.Allocator) void {
        self.text.deinit(gpa);
        for (self.history.items) |h| gpa.free(h);
        self.history.deinit(gpa);
        self.stash.deinit(gpa);
    }

    fn prevCpStart(text: []const u8, i: usize) usize {
        var p = i;
        while (p > 0) {
            p -= 1;
            if (text[p] & 0xC0 != 0x80) return p;
        }
        return 0;
    }

    pub fn insert(self: *Composer, gpa: std.mem.Allocator, bytes: []const u8) void {
        self.text.insertSlice(gpa, self.cursor, bytes) catch return;
        self.cursor += bytes.len;
        self.hist_idx = null;
    }

    pub fn backspace(self: *Composer, gpa: std.mem.Allocator) void {
        if (self.cursor == 0) return;
        const p = prevCpStart(self.text.items, self.cursor);
        self.text.replaceRange(gpa, p, self.cursor - p, &.{}) catch return;
        self.cursor = p;
        self.hist_idx = null;
    }

    pub fn deleteForward(self: *Composer, gpa: std.mem.Allocator) void {
        if (self.cursor >= self.text.items.len) return;
        const d = decodeCp(self.text.items[self.cursor..]);
        self.text.replaceRange(gpa, self.cursor, d.len, &.{}) catch return;
        self.hist_idx = null;
    }

    pub fn moveLeft(self: *Composer) void {
        if (self.cursor > 0) self.cursor = prevCpStart(self.text.items, self.cursor);
    }

    pub fn moveRight(self: *Composer) void {
        if (self.cursor < self.text.items.len) self.cursor += decodeCp(self.text.items[self.cursor..]).len;
    }

    pub fn lineHome(self: *Composer) void {
        self.cursor = if (std.mem.lastIndexOfScalar(u8, self.text.items[0..self.cursor], '\n')) |p| p + 1 else 0;
    }

    pub fn lineEnd(self: *Composer) void {
        self.cursor = std.mem.indexOfScalarPos(u8, self.text.items, self.cursor, '\n') orelse self.text.items.len;
    }

    pub fn deleteWordBack(self: *Composer, gpa: std.mem.Allocator) void {
        if (self.cursor == 0) return;
        var p = self.cursor;
        while (p > 0 and self.text.items[p - 1] == ' ') p -= 1;
        while (p > 0 and self.text.items[p - 1] != ' ' and self.text.items[p - 1] != '\n') p -= 1;
        self.text.replaceRange(gpa, p, self.cursor - p, &.{}) catch return;
        self.cursor = p;
        self.hist_idx = null;
    }

    pub fn clear(self: *Composer) void {
        self.text.clearRetainingCapacity();
        self.cursor = 0;
        self.hist_idx = null;
    }

    pub fn pushHistory(self: *Composer, gpa: std.mem.Allocator, entry: []const u8) void {
        if (entry.len == 0) return;
        if (self.history.items.len > 0 and
            std.mem.eql(u8, self.history.items[self.history.items.len - 1], entry)) return;
        const copy = gpa.dupe(u8, entry) catch return;
        self.history.append(gpa, copy) catch gpa.free(copy);
    }

    pub fn historyPrev(self: *Composer, gpa: std.mem.Allocator) void {
        if (self.history.items.len == 0) return;
        if (self.hist_idx) |idx| {
            if (idx == 0) return;
            self.hist_idx = idx - 1;
        } else {
            self.stash.clearRetainingCapacity();
            self.stash.appendSlice(gpa, self.text.items) catch return;
            self.hist_idx = self.history.items.len - 1;
        }
        self.loadEntry(gpa, self.history.items[self.hist_idx.?]);
    }

    pub fn historyNext(self: *Composer, gpa: std.mem.Allocator) void {
        const idx = self.hist_idx orelse return;
        if (idx + 1 < self.history.items.len) {
            self.hist_idx = idx + 1;
            self.loadEntry(gpa, self.history.items[idx + 1]);
        } else {
            self.hist_idx = null;
            // `loadEntry` reads `stash` while writing `text` — two distinct
            // lists, no aliasing.
            self.loadEntry(gpa, self.stash.items);
        }
    }

    fn loadEntry(self: *Composer, gpa: std.mem.Allocator, entry: []const u8) void {
        self.text.clearRetainingCapacity();
        self.text.appendSlice(gpa, entry) catch {};
        self.cursor = self.text.items.len;
    }
};

// ─── TUI ──────────────────────────────────────────────────────────────────────

/// Layout (bottom-up):
///   row  rows              →  status/hint bar (contextual)
///   rows rows-comp_h..rows-1 →  composer (1..5 rows, grows by shrinking
///                               the transcript; prompt "❯ ")
///   rows 1..rows-comp_h-1  →  message viewport (owned transcript,
///                               own scrolling)
///
/// Runs in the alternate screen buffer: the TUI is the sole source of truth
/// for what's on screen, so the terminal's own scrollback/reflow is never
/// involved and can't leak stale content into view.
pub const Tui = struct {
    gpa: std.mem.Allocator,
    rows: u16,
    cols: u16,
    stdout_fd: posix.fd_t,
    theme: Theme,

    transcript: std.ArrayList(u8),
    rows_cache: std.ArrayList(Row),
    last_line_start: usize = 0,
    /// null = pinned to live tail (auto-follow). Some(x) = fixed absolute
    /// row index of the viewport's top; set when the user scrolls up.
    view_start: ?usize = null,

    /// Whether the scan position is currently inside a provider-marked
    /// thinking span or an agent-marked error span. Persists across
    /// incremental `wrapLogicalLine` calls since a span can outlive any
    /// single call as tokens stream in.
    gutter_state: Gutter = .none,

    /// Whether the scan position is currently inside a ```-fenced code
    /// block. Tracked separately from `gutter_state` (rather than as
    /// another value fed through the same field) because it's detected
    /// from plain fence bytes the model wrote, not a wire SGR marker, and
    /// must survive across the many `wrapLogicalLine` calls one streamed
    /// block spans.
    in_code: bool = false,

    /// Byte offset in `self.transcript` of the currently in-flight tool
    /// call's dot (see `tool_pending_sgr`), or null if no tool call is
    /// pending. At most one at a time — tool calls run sequentially.
    pending_tool_dot: ?usize = null,
    tool_dot_blink_on: bool = false,

    dot_phase: u8 = 0,
    last_dot_ns: i64 = 0,

    /// Monotonic timestamp captured by `beginTurn()`; `onAgentDone()` diffs
    /// against it for the round-trip time line, `drawBar` for the live
    /// elapsed counter.
    turn_start_ns: i64 = 0,

    /// Deliberately plain bools/ints, not `core.engine` types — this file
    /// has no dependency on `core/*` and shouldn't gain one for labels.
    /// Drives the bar's `[react]`/`[todo]` tag (design doc §3.5); the
    /// engine-side effect of this toggle (a hook-injected system nudge) is
    /// invisible here — this file only labels the current mode.
    todo_mode: bool = false,
    busy: bool = false,
    cancelling: bool = false,
    help_visible: bool = false,
    /// Pending human-approval question (gpa-owned copy, set via
    /// `setApproval`), or null. While non-null the bar's left side becomes
    /// the approval prompt (top priority) and the main loop routes y/n keys
    /// to the agent instead of the composer. Plain string, not a `core/*`
    /// type — same no-core-dependency rule as every other field here.
    approval_text: ?[]u8 = null,
    /// Whether the next streamed byte starts a line (also drives marker
    /// detection in `processStream`).
    line_start: bool = true,

    /// Todo panel state (design doc §5.1/§3.8), fed by `processStream`'s
    /// `[todos]`/`[/todos]` marker capture and by `setTodos` (also called
    /// directly at startup to hydrate from persisted memory — see
    /// `main.zig`). Each entry is one already-glyphed line as `todo_write`
    /// rendered it (`"✓ locate plan-mode code"`) — the panel colors by
    /// leading glyph rather than tracking status itself. Unlike the old
    /// plan panel, nothing resets this on turn end: a todo list is a
    /// standing, multi-turn artifact.
    todo_lines: std.ArrayList([]const u8),
    todo_total: usize = 0,
    todo_done: usize = 0,
    /// Todo-panel height in rows for the current frame (0 = hidden);
    /// computed by `renderAll`, read by `msgViewportRows`.
    todo_panel_h: u16 = 0,
    /// Hold-back buffer for a line that may still turn out to be a
    /// `[todos]`/`[/todos]` marker (`processStream`). Persists across chunk
    /// boundaries — markers can arrive split across channel drains.
    filter_line: std.ArrayList(u8),
    /// True while stream content is being diverted into `todo_buf`.
    capturing_todos: bool = false,
    /// Raw bytes captured between `[todos]` and `[/todos]`.
    todo_buf: std.ArrayList(u8),

    /// Static context labels for the bar's right side; set once via
    /// `setContext`, borrowed (caller keeps them alive for the whole run).
    model_label: []const u8 = "",
    session_label: []const u8 = "",

    composer: Composer = .{},
    comp_rows: std.ArrayList(VRow),
    comp_scroll: usize = 0,
    comp_h: u16 = 1,

    /// Multi-byte UTF-8 input accumulation: the event loop reads stdin one
    /// byte at a time, so a lead byte parks here until its continuation
    /// bytes arrive.
    pending_utf8: [4]u8 = undefined,
    pending_utf8_len: u8 = 0,
    pending_utf8_need: u8 = 0,

    pub fn init(gpa: std.mem.Allocator, stdout_fd: posix.fd_t, theme: Theme) !Tui {
        const size = getTermSize(stdout_fd);
        return .{
            .gpa = gpa,
            .rows = size.rows,
            .cols = size.cols,
            .stdout_fd = stdout_fd,
            .theme = theme,
            .transcript = .empty,
            .rows_cache = .empty,
            .comp_rows = .empty,
            .todo_lines = .empty,
            .filter_line = .empty,
            .todo_buf = .empty,
        };
    }

    pub fn deinit(self: *Tui) void {
        if (self.approval_text) |q| self.gpa.free(q);
        self.transcript.deinit(self.gpa);
        self.rows_cache.deinit(self.gpa);
        self.composer.deinit(self.gpa);
        self.comp_rows.deinit(self.gpa);
        self.clearTodoLines();
        self.todo_lines.deinit(self.gpa);
        self.filter_line.deinit(self.gpa);
        self.todo_buf.deinit(self.gpa);
    }

    fn clearTodoLines(self: *Tui) void {
        for (self.todo_lines.items) |s| self.gpa.free(s);
        self.todo_lines.clearRetainingCapacity();
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
        self.rawWrite("\x1b[?1049h"); // alternate screen buffer
        self.rawWrite("\x1b[?1000h\x1b[?1006h"); // mouse reporting (wheel scroll; SGR encoding)
        self.rawWrite("\x1b[2J");
        self.renderAll();
    }

    pub fn leave(self: *Tui) void {
        self.rawWrite("\x1b[?1000l\x1b[?1006l"); // mouse off
        self.rawWrite("\x1b[?25h"); // cursor back on
        self.rawWrite("\x1b[?1049l"); // restore primary screen exactly as it was
    }

    /// Recomputes terminal geometry after a SIGWINCH, rewraps the whole
    /// transcript at the new width, and redraws everything. Scroll position
    /// re-pins to the live tail (row indices from before a width change
    /// don't mean anything after it).
    pub fn handleResize(self: *Tui) void {
        const size = getTermSize(self.stdout_fd);
        self.rows = size.rows;
        self.cols = size.cols;
        self.view_start = null;
        self.rebuildRowsCache();
        self.rawWrite("\x1b[2J");
        self.renderAll();
    }

    pub fn setContext(self: *Tui, model: []const u8, session: []const u8) void {
        self.model_label = model;
        self.session_label = session;
    }

    fn tooSmall(self: *Tui) bool {
        return self.rows < 6 or self.cols < 24;
    }

    fn compWidth(self: *Tui) usize {
        return if (self.cols > 2) self.cols - 2 else 1;
    }

    fn msgViewportRows(self: *Tui) u16 {
        const chrome = self.comp_h + 1 + self.todo_panel_h; // composer + bar + todo panel
        return if (self.rows > chrome) self.rows - chrome else 1;
    }

    /// Rows the todo panel gets this frame: 0 when empty, header-only on
    /// short terminals, else header + up to 6 item rows — never squeezing
    /// the transcript below 8 rows.
    fn todoPanelHeight(self: *Tui) u16 {
        if (self.todo_lines.items.len == 0) return 0;
        if (self.rows < 16) return 1; // header only
        const chrome: usize = @as(usize, self.comp_h) + 1;
        const max_h: usize = if (self.rows > chrome + 8) self.rows - chrome - 8 else 1;
        const want: usize = 1 + @min(self.todo_lines.items.len, 6);
        return @intCast(@max(@min(want, max_h), 1));
    }

    /// Recomputes the composer's wrapped rows, its on-screen height
    /// (1..5 rows, also bounded by terminal height), and its internal
    /// scroll so the cursor row stays visible.
    fn layoutComposer(self: *Tui) void {
        wrapPlain(self.gpa, &self.comp_rows, self.composer.text.items, self.compWidth());
        const n = self.comp_rows.items.len;
        const avail: usize = if (self.rows > 3) self.rows - 3 else 1;
        var h = @min(n, @min(@as(usize, 5), avail));
        if (h == 0) h = 1;
        self.comp_h = @intCast(h);

        const rc = cursorRowCol(self.comp_rows.items, self.composer.text.items, self.composer.cursor);
        if (rc.row < self.comp_scroll) self.comp_scroll = rc.row;
        if (rc.row >= self.comp_scroll + h) self.comp_scroll = rc.row - h + 1;
        if (self.comp_scroll + h > n) self.comp_scroll = n - h;
    }

    /// One full frame: transcript viewport, composer, bar, cursor (or the
    /// help overlay / too-small notice instead). Everything else funnels
    /// through here — the frame is small (≤ terminal size), so partial
    /// redraw bookkeeping isn't worth its bugs. Cursor is hidden during
    /// drawing to avoid flicker.
    pub fn renderAll(self: *Tui) void {
        if (self.tooSmall()) {
            self.rawWrite("\x1b[?25l\x1b[2J\x1b[1;1H");
            self.rawWrite("terminal too small (24x6 min)");
            return;
        }
        self.rawWrite("\x1b[?25l");
        self.layoutComposer();
        self.todo_panel_h = self.todoPanelHeight();
        self.renderMessages();
        self.drawTodoPanel();
        self.drawComposer();
        self.drawBar();
        if (self.help_visible) {
            self.drawHelp();
            return; // cursor stays hidden under the overlay
        }
        self.positionCursor();
    }

    /// Clears and redraws from scratch (Ctrl+L — recovers from anything
    /// that corrupted the screen outside our control).
    pub fn redraw(self: *Tui) void {
        self.rawWrite("\x1b[2J");
        self.renderAll();
    }

    fn rowText(self: *Tui, r: Row) []const u8 {
        return self.transcript.items[r.start .. r.start + r.len];
    }

    fn gutterWidth(base: usize, g: Gutter) usize {
        if (g == .none) return base;
        return if (base > gutter_cols) base - gutter_cols else 1;
    }

    /// The gutter the row being scanned right now should carry: a
    /// wire-marked thinking/error span always wins (it can't nest inside a
    /// code fence in practice), otherwise `.code` while inside a ```-fenced
    /// block, otherwise none.
    fn currentGutter(self: *Tui) Gutter {
        if (self.gutter_state != .none) return self.gutter_state;
        if (self.in_code) return .code;
        return .none;
    }

    /// Overwrites the currently pending tool dot's `tool_dot_len` bytes in
    /// place with `final_dot` (`tool_dot_ok`/`tool_dot_fail`) and clears
    /// `pending_tool_dot`. Safe to call with no pending dot (no-op).
    /// `self.transcript` only ever grows via append, never shifts, so a
    /// previously recorded offset stays valid indefinitely; `rows_cache`
    /// entries reference this byte range by offset, so the next
    /// `renderMessages()` picks up the patched glyph automatically.
    fn patchToolDot(self: *Tui, final_dot: []const u8) void {
        const offset = self.pending_tool_dot orelse return;
        self.pending_tool_dot = null;
        if (offset + tool_dot_len > self.transcript.items.len) return;
        @memcpy(self.transcript.items[offset .. offset + tool_dot_len], final_dot);
    }

    /// Splits `line` (no embedded '\n') into physical rows of at most
    /// `self.cols` visible columns, pushing a Row per wrapped segment.
    /// ANSI escape sequences count as zero width; visible characters are
    /// charged their Unicode display width (`charWidth`), decoded per
    /// codepoint so multi-byte UTF-8 never splits mid-sequence. `abs_start`
    /// is `line`'s absolute offset within `self.transcript`.
    ///
    /// Also watches for the thinking/error span markers to update
    /// `self.gutter_state` and tags each pushed Row with it, reserving
    /// `gutter_cols` of width for guttered rows so `renderMessages` can
    /// prepend the gutter without overflowing the terminal width.
    fn wrapLogicalLine(self: *Tui, abs_start: usize, line: []const u8) void {
        // A ```-fence line toggles code-block state before anything else on
        // this line is measured. The toggle alone would make the *closing*
        // fence read as `.none` (state has already flipped off by the time
        // its own gutter is picked) — `line_gutter` pins both the opening
        // and closing fence to `.code` explicitly so the tinted block reads
        // as a visible border around the lines it delimits, not just the
        // lines strictly between them.
        const is_fence = std.mem.startsWith(u8, line, "```");
        if (is_fence) self.in_code = !self.in_code;
        const line_gutter: ?Gutter = if (is_fence) .code else null;

        const base_width: usize = if (self.cols > 0) self.cols else 80;
        if (line.len == 0) {
            self.rows_cache.append(self.gpa, .{ .start = abs_start, .len = 0, .gutter = line_gutter orelse self.currentGutter() }) catch {};
            return;
        }
        var seg_start: usize = 0;
        var seg_gutter = line_gutter orelse self.currentGutter();
        var width = gutterWidth(base_width, seg_gutter);
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
                    self.gutter_state = .thinking;
                } else if (std.mem.eql(u8, seq, error_start_sgr)) {
                    self.gutter_state = .err;
                } else if (std.mem.eql(u8, seq, span_end_sgr)) {
                    self.gutter_state = .none;
                } else if (std.mem.eql(u8, seq, tool_pending_sgr)) {
                    self.pending_tool_dot = abs_start + esc_start;
                    // The bytes just written are the bright variant — start
                    // the blink toggle from "currently bright" so its first
                    // flip shows a visible change.
                    self.tool_dot_blink_on = true;
                } else if (std.mem.eql(u8, seq, tool_done_ok_sgr)) {
                    self.patchToolDot(tool_dot_ok);
                } else if (std.mem.eql(u8, seq, tool_done_fail_sgr)) {
                    self.patchToolDot(tool_dot_fail);
                }
                // Nothing visible emitted into the current segment yet, so
                // let the new state apply retroactively — this makes the
                // common case (marker at line start) reserve gutter width
                // correctly.
                if (col == 0) {
                    seg_gutter = line_gutter orelse self.currentGutter();
                    width = gutterWidth(base_width, seg_gutter);
                }
                continue; // zero width, doesn't count toward col
            }
            const d = decodeCp(line[i..]);
            const cw: usize = charWidth(d.cp);
            if (col + cw > width and col > 0) {
                self.rows_cache.append(self.gpa, .{ .start = abs_start + seg_start, .len = i - seg_start, .gutter = seg_gutter }) catch {};
                seg_start = i;
                col = 0;
                seg_gutter = line_gutter orelse self.currentGutter();
                width = gutterWidth(base_width, seg_gutter);
            }
            col += cw;
            i += d.len;
        }
        if (seg_start < line.len or seg_start == 0) {
            self.rows_cache.append(self.gpa, .{ .start = abs_start + seg_start, .len = line.len - seg_start, .gutter = seg_gutter }) catch {};
        }
    }

    /// Rewraps from `self.last_line_start` onward: drops cached rows
    /// belonging to the still-open last line, then re-walks just the new
    /// tail of the transcript. Cost is proportional to newly appended
    /// bytes, not total transcript size.
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
    /// `gutter_state` since the rescan starts from byte 0.
    fn rebuildRowsCache(self: *Tui) void {
        self.rows_cache.clearRetainingCapacity();
        self.last_line_start = 0;
        self.gutter_state = .none;
        self.in_code = false;
        self.rewrapTail();
    }

    /// Appends locally generated bytes (the "You:" label, the round-trip
    /// time line) straight to the transcript, stripping '\r'. Does NOT
    /// rewrap or render — callers batch that. Streamed agent output goes
    /// through `processStream` instead.
    fn appendBytes(self: *Tui, bytes: []const u8) void {
        if (bytes.len == 0) return;
        var start: usize = 0;
        for (bytes, 0..) |b, idx| {
            if (b == '\r') {
                self.transcript.appendSlice(self.gpa, bytes[start..idx]) catch return;
                start = idx + 1;
            }
        }
        self.transcript.appendSlice(self.gpa, bytes[start..]) catch return;
        self.line_start = bytes[bytes.len - 1] == '\n';
    }

    /// The only markers `processStream` recognizes (design doc §3.8) — far
    /// smaller than the old Plan-and-Execute phase-marker table, since a
    /// todo-list block only needs a start/end pair, no free-form step
    /// markers.
    const todo_markers = [_][]const u8{ "[todos]", "[/todos]" };

    /// Could `h` (a line fragment starting with '[') still grow into one of
    /// `todo_markers`?
    fn markerCandidate(h: []const u8) bool {
        for (todo_markers) |m| {
            if (h.len <= m.len) {
                if (std.mem.startsWith(u8, m, h)) return true;
            } else if (std.mem.startsWith(u8, h, m)) {
                // Full marker matched but the line continues — hold until
                // the newline proves/disproves an exact match.
                return true;
            }
        }
        return false;
    }

    /// Streamed-output front door: routes bytes to the transcript (or,
    /// inside a `[todos]` block, to `todo_buf`) while holding back any line
    /// that may be a `[todos]`/`[/todos]` marker. Hold-back is
    /// prefix-driven, so ordinary content — including the tool-dot marker
    /// lines, whose second byte is ESC — flushes through after at most a
    /// byte or two of buffering; the buffer survives across calls because
    /// markers can arrive split across channel drains.
    fn processStream(self: *Tui, bytes: []const u8) void {
        for (bytes) |b| {
            if (self.filter_line.items.len > 0) {
                self.filter_line.append(self.gpa, b) catch {};
                if (b == '\n') {
                    self.classifyFilterLine();
                } else if (self.filter_line.items.len > 16 or !markerCandidate(self.filter_line.items)) {
                    self.flushFilterLine();
                }
                continue;
            }
            if (b == '[' and self.line_start) {
                self.filter_line.append(self.gpa, b) catch {};
                continue;
            }
            self.routeByte(b);
        }
    }

    fn routeByte(self: *Tui, b: u8) void {
        if (self.capturing_todos) {
            self.todo_buf.append(self.gpa, b) catch {};
        } else if (b != '\r') {
            self.transcript.append(self.gpa, b) catch {};
        }
        self.line_start = b == '\n';
    }

    /// The held line turned out to be ordinary content — release it.
    fn flushFilterLine(self: *Tui) void {
        for (self.filter_line.items) |b| self.routeByte(b);
        self.filter_line.clearRetainingCapacity();
    }

    /// A complete '['-line arrived: act on a `[todos]`/`[/todos]` marker
    /// (suppressing it from the transcript) or flush it as content.
    fn classifyFilterLine(self: *Tui) void {
        const with_nl = self.filter_line.items;
        const line = with_nl[0 .. with_nl.len - 1];
        if (std.mem.eql(u8, line, "[todos]")) {
            self.capturing_todos = true;
            self.todo_buf.clearRetainingCapacity();
        } else if (std.mem.eql(u8, line, "[/todos]")) {
            self.capturing_todos = false;
            self.setTodos(self.todo_buf.items);
        } else {
            self.flushFilterLine();
            return;
        }
        self.filter_line.clearRetainingCapacity();
        self.line_start = true;
    }

    /// Parses a raw `todo_write` result (header line + one item per
    /// remaining line) into panel rows, replacing whatever was there —
    /// `todo_write` always sends the full list, so there's never a partial
    /// update to merge. Zero item lines (the "Todo list is now empty."
    /// case) hides the panel. Called both from the marker capture above and
    /// directly by `main.zig` at startup to hydrate from persisted memory.
    pub fn setTodos(self: *Tui, raw: []const u8) void {
        self.clearTodoLines();
        self.todo_done = 0;
        var lines = std.mem.splitScalar(u8, raw, '\n');
        _ = lines.next(); // header line ("Todo list (N items):"), not shown in the panel
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            const copy = self.gpa.dupe(u8, line) catch continue;
            self.todo_lines.append(self.gpa, copy) catch {
                self.gpa.free(copy);
                continue;
            };
            if (std.mem.startsWith(u8, line, "\u{2713}")) self.todo_done += 1;
        }
        self.todo_total = self.todo_lines.items.len;
    }

    /// Truncates `text` to at most `maxw` display columns, reserving one
    /// column for an ellipsis when it doesn't fit.
    fn writeTruncated(self: *Tui, text: []const u8, maxw: usize) void {
        var w: usize = 0;
        var i: usize = 0;
        var cut: usize = text.len;
        var truncated = false;
        while (i < text.len) {
            const d = decodeCp(text[i..]);
            const cw: usize = charWidth(d.cp);
            if (w + cw > maxw -| 1 and cut == text.len) cut = i; // ellipsis fallback point
            if (w + cw > maxw) {
                truncated = true;
                break;
            }
            w += cw;
            i += d.len;
        }
        if (!truncated) {
            self.rawWrite(text);
        } else {
            self.rawWrite(text[0..cut]);
            self.rawWrite("\u{2026}");
        }
    }

    /// The todo panel (between transcript and composer): an accent-guttered
    /// block with a header row (`▍ todo 2/5`) and one row per item, colored
    /// by each line's already-baked-in leading glyph — `todo_write` picked
    /// ✓/●/○, this only maps glyph to theme color. When items outnumber the
    /// panel rows, the overflow is summarized as a trailing "… N more" row
    /// rather than windowed around a "current" item — todos aren't linear
    /// the way plan-execute steps were (design doc §3.8).
    fn drawTodoPanel(self: *Tui) void {
        if (self.todo_panel_h == 0) return;
        const first: u16 = self.rows - self.comp_h - self.todo_panel_h;

        self.writeFmt("\x1b[{d};1H", .{first});
        self.rawWrite("\x1b[2K");
        self.rawWrite(self.theme.accent);
        self.rawWrite("\u{258D}");
        self.rawWrite(self.theme.reset);
        self.rawWrite(self.theme.dim);
        var hdr_buf: [32]u8 = undefined;
        const header = std.fmt.bufPrint(&hdr_buf, "todo {d}/{d}", .{ self.todo_done, self.todo_total }) catch "todo";
        self.rawWrite(header);
        self.rawWrite(self.theme.reset);

        const avail: usize = self.todo_panel_h - 1;
        const items = self.todo_lines.items;
        if (avail == 0) return;
        const shown = @min(items.len, avail);
        const overflow = items.len > avail;
        // Reserve the last row for a "… N more" notice when truncated, so
        // it's never silently cut off.
        const item_rows: usize = if (overflow and shown > 0) shown - 1 else shown;

        var r: usize = 0;
        while (r < item_rows) : (r += 1) {
            const term_row = first + 1 + @as(u16, @intCast(r));
            self.writeFmt("\x1b[{d};1H", .{term_row});
            self.rawWrite("\x1b[2K");
            self.rawWrite(self.theme.accent);
            self.rawWrite("\u{258D}");
            self.rawWrite(self.theme.reset);
            const line = items[r];
            const color = if (std.mem.startsWith(u8, line, "\u{2713}"))
                self.theme.ok
            else if (std.mem.startsWith(u8, line, "\u{25CF}"))
                self.theme.warn
            else
                self.theme.dim;
            self.rawWrite(color);
            self.writeTruncated(line, @as(usize, self.cols) -| 3);
            self.rawWrite(self.theme.reset);
        }
        if (overflow) {
            const term_row = first + 1 + @as(u16, @intCast(item_rows));
            self.writeFmt("\x1b[{d};1H", .{term_row});
            self.rawWrite("\x1b[2K");
            self.rawWrite(self.theme.accent);
            self.rawWrite("\u{258D}");
            self.rawWrite(self.theme.reset);
            self.rawWrite(self.theme.dim);
            var more_buf: [32]u8 = undefined;
            const more = std.fmt.bufPrint(&more_buf, "\u{2026} {d} more", .{items.len - item_rows}) catch "\u{2026} more";
            self.rawWrite(more);
            self.rawWrite(self.theme.reset);
        }
    }

    /// Writes row text to the terminal. With colors disabled, SGR/CSI
    /// escape sequences are stripped so NO_COLOR output is genuinely plain.
    /// With colors enabled, any embedded SGR (wire markers, tool-marker
    /// inline styling) passes through untouched; when `highlight_inline` is
    /// set, `` `backtick` `` spans additionally get colored as inline code.
    /// Highlighting is render-time and row-local: a span split across a
    /// wrapped-row boundary loses its color on the far side, and a span
    /// still open at row end is force-closed with `fg_reset` so it can
    /// never bleed into whatever renders next. Callers pass `false` for
    /// `.thinking`/`.err` rows — `renderMessages` re-emits those spans'
    /// start SGR before the text on every row (a wrapped span's marker
    /// lives only in its first row's bytes), so the backtick highlighter's
    /// `fg_reset` would strip that color mid-row for the rest of the span,
    /// not just the backtick run. The span's own closing `\x1b[0m` (in its
    /// last row) still ends it; no reset is emitted after these rows.
    fn writeRowFiltered(self: *Tui, text: []const u8, highlight_inline: bool) void {
        if (!self.theme.colors) {
            var start: usize = 0;
            var i: usize = 0;
            while (i < text.len) {
                if (text[i] == 0x1b) {
                    self.rawWrite(text[start..i]);
                    i += 1;
                    if (i < text.len and text[i] == '[') {
                        i += 1;
                        while (i < text.len and !(text[i] >= 0x40 and text[i] <= 0x7e)) : (i += 1) {}
                        if (i < text.len) i += 1;
                    }
                    start = i;
                    continue;
                }
                i += 1;
            }
            self.rawWrite(text[start..]);
            return;
        }
        if (!highlight_inline) {
            self.rawWrite(text);
            return;
        }

        var in_span = false;
        var i: usize = 0;
        while (i < text.len) {
            if (text[i] == 0x1b) {
                const esc_start = i;
                i += 1;
                if (i < text.len and text[i] == '[') {
                    i += 1;
                    while (i < text.len and !(text[i] >= 0x40 and text[i] <= 0x7e)) : (i += 1) {}
                    if (i < text.len) i += 1;
                }
                self.rawWrite(text[esc_start..i]);
                continue;
            }
            if (text[i] == '`') {
                self.rawWrite(if (in_span) self.theme.fg_reset else self.theme.inline_code);
                in_span = !in_span;
                self.rawWrite("`");
                i += 1;
                continue;
            }
            const d = decodeCp(text[i..]);
            self.rawWrite(text[i .. i + d.len]);
            i += d.len;
        }
        if (in_span) self.rawWrite(self.theme.fg_reset);
    }

    /// Redraws the message viewport from `rows_cache`, honoring
    /// `view_start`. Cost is O(viewport height), independent of transcript
    /// length.
    fn renderMessages(self: *Tui) void {
        const viewport_h = self.msgViewportRows();
        const total = self.rows_cache.items.len;
        const max_start: usize = if (total > viewport_h) total - viewport_h else 0;

        var start = self.view_start orelse max_start;
        if (start > max_start) start = max_start;

        var row: u16 = 0;
        while (row < viewport_h) : (row += 1) {
            self.writeFmt("\x1b[{d};1H", .{row + 1});
            const idx = start + row;
            // A code row's background tint is set *before* the line-erase
            // below so the erase fills the whole row width with it (the
            // standard "set bg, then erase-to-eol" trick) — a plain string
            // write can only tint the columns it covers.
            const upcoming_gutter: Gutter = if (idx < total) self.rows_cache.items[idx].gutter else .none;
            if (upcoming_gutter == .code) self.rawWrite(self.theme.code_bg);
            self.rawWrite("\x1b[2K");
            if (idx < total) {
                const r = self.rows_cache.items[idx];
                switch (r.gutter) {
                    .none => {},
                    .thinking => {
                        self.rawWrite(self.theme.accent);
                        self.rawWrite("\u{2502}");
                        self.rawWrite(self.theme.reset);
                        self.rawWrite(" ");
                        // Re-establish the span color on *every* row. A
                        // wrapped thinking span's `\x1b[2;3;36m` marker
                        // lives only in its FIRST row's bytes, so without
                        // this the `reset` just above leaves continuation
                        // rows in the terminal default — the bug where only
                        // the first thinking line was colored. The SGR is
                        // idempotent (row 0's text also begins with it, so
                        // emitting twice is harmless); NO_COLOR skips it.
                        if (self.theme.colors) self.rawWrite(thinking_start_sgr);
                    },
                    .err => {
                        self.rawWrite(self.theme.err_c);
                        self.rawWrite("\u{2502}");
                        self.rawWrite(self.theme.reset);
                        self.rawWrite(" ");
                        // Same per-row re-establish as `.thinking` above:
                        // an error span's marker is only in its first row.
                        if (self.theme.colors) self.rawWrite(error_start_sgr);
                    },
                    .code => {
                        self.rawWrite(self.theme.code_bar);
                        self.rawWrite("\u{2502}");
                        // fg-only reset: the code-block background painted
                        // above must survive into the row text that follows.
                        self.rawWrite(self.theme.fg_reset);
                        self.rawWrite(" ");
                    },
                }
                self.writeRowFiltered(self.rowText(r), r.gutter == .none or r.gutter == .code);
                // Detection here is render-time (fence bytes, not a wire
                // marker), so unlike thinking/err spans nothing in the row
                // text itself carries a closing reset — do it explicitly.
                if (r.gutter == .code) self.rawWrite(self.theme.reset);
            }
        }
    }

    fn drawComposer(self: *Tui) void {
        var r: u16 = 0;
        while (r < self.comp_h) : (r += 1) {
            const term_row = self.rows - self.comp_h + r;
            self.writeFmt("\x1b[{d};1H", .{term_row});
            self.rawWrite("\x1b[2K");
            const idx = self.comp_scroll + r;
            if (idx >= self.comp_rows.items.len) continue;
            if (idx == 0) {
                self.rawWrite(self.theme.accent);
                self.rawWrite("\u{276F}");
                self.rawWrite(self.theme.reset);
                self.rawWrite(" ");
            } else {
                self.rawWrite("  ");
            }
            const vr = self.comp_rows.items[idx];
            self.rawWrite(self.composer.text.items[vr.start .. vr.start + vr.len]);
        }
    }

    /// The single bottom bar. Left side is contextual state, in priority
    /// order busy > scrolled > hints; right side is persistent identity
    /// (orchestration style with live plan progress, model, session).
    /// Right-side pieces drop first when the terminal is narrow; hints
    /// compress below 70 columns.
    fn drawBar(self: *Tui) void {
        self.writeFmt("\x1b[{d};1H", .{self.rows});
        self.rawWrite("\x1b[2K");

        var left_buf: [160]u8 = undefined;
        var left: []const u8 = undefined;
        var left_is_busy = false;
        if (self.approval_text) |q| {
            // Top-priority state: the orchestrator is blocked on a yes/no.
            // Truncate the question (never the controls) to fit the row.
            left_is_busy = true;
            const fixed = "\u{25CF} allow?  \u{B7} y run \u{B7} n deny";
            const budget = @min(@as(usize, self.cols) -| displayWidth(fixed), 100);
            const shown = truncateCols(q, budget);
            left = std.fmt.bufPrint(&left_buf, "\u{25CF} allow? {s}{s} \u{B7} y run \u{B7} n deny", .{
                shown, if (shown.len < q.len) "\u{2026}" else "",
            }) catch "\u{25CF} allow? \u{B7} y run \u{B7} n deny";
        } else if (self.busy) {
            left_is_busy = true;
            if (self.cancelling) {
                left = "\u{25CF} cancelling\u{2026}";
            } else {
                const dots: []const u8 = switch (self.dot_phase) {
                    0 => ".", 1 => "..", else => "...",
                };
                const elapsed_s = @divTrunc(monoNs() - self.turn_start_ns, 1_000_000_000);
                left = std.fmt.bufPrint(&left_buf, "\u{25CF} thinking{s} {d}s \u{B7} Esc cancel", .{ dots, elapsed_s }) catch "\u{25CF} thinking";
            }
        } else if (self.view_start != null) {
            const viewport_h = self.msgViewportRows();
            const total = self.rows_cache.items.len;
            const below = total -| (self.view_start.? + viewport_h);
            left = std.fmt.bufPrint(&left_buf, "\u{2191} {d} rows below \u{B7} PgDn newest \u{B7} Esc tail", .{below}) catch "\u{2191} scrolled";
        } else if (self.cols >= 60) {
            // ^P (style toggle) et al live in the ^G help overlay; keeping
            // the hint row at 44 cols leaves room for the full right-side
            // identity at a standard 80-col terminal.
            left = "Enter send \u{B7} M-\u{21B5} newline \u{B7} ^G help \u{B7} ^C quit";
        } else {
            left = "\u{21B5} send \u{B7} ^G help";
        }

        // Right side: [style] · model · session, dropping pieces to fit.
        var right_buf: [128]u8 = undefined;
        const style_tag: []const u8 = if (self.todo_mode) "[todo]" else "[react]";

        const left_w = displayWidth(left);
        var right: []const u8 = "";
        const full = std.fmt.bufPrint(&right_buf, "{s} \u{B7} {s} \u{B7} {s}", .{ style_tag, self.model_label, self.session_label }) catch style_tag;
        if (left_w + 3 + displayWidth(full) <= self.cols) {
            right = full;
        } else if (left_w + 3 + displayWidth(style_tag) <= self.cols) {
            right = style_tag;
        }

        // Left: busy state gets a colored spinner glyph, the rest is dim.
        if (left_is_busy and self.theme.colors) {
            // First glyph of `left` is the 3-byte "●" — color it warn/err.
            // An approval prompt gets the err color: stop, decision needed.
            self.rawWrite(if (self.cancelling or self.approval_text != null) self.theme.err_c else self.theme.warn);
            self.rawWrite(left[0..3]);
            self.rawWrite(self.theme.reset);
            self.rawWrite(self.theme.dim);
            self.rawWrite(left[3..]);
            self.rawWrite(self.theme.reset);
        } else {
            self.rawWrite(self.theme.dim);
            self.rawWrite(left);
            self.rawWrite(self.theme.reset);
        }

        if (right.len > 0) {
            const col = self.cols - displayWidth(right) + 1;
            self.writeFmt("\x1b[{d};{d}H", .{ self.rows, col });
            self.rawWrite(self.theme.dim);
            self.rawWrite(right);
            self.rawWrite(self.theme.reset);
        }
    }

    const help_title = " keys ";
    const help_lines = [_][]const u8{
        "Enter         send prompt",
        "Alt+Enter     insert newline",
        "\u{2190} \u{2192} Home End  move cursor",
        "\u{2191} \u{2193}           move \u{B7} history at edges",
        "Ctrl+A / E    line start / end",
        "Ctrl+W / U    delete word / clear input",
        "PgUp PgDn     scroll transcript (wheel too)",
        "Esc           cancel turn \u{B7} jump tail \u{B7} clear",
        "y / n         allow / deny a command prompt",
        "Ctrl+P        toggle react / todo style",
        "Ctrl+L        redraw screen",
        "Ctrl+Z        suspend",
        "Ctrl+G        toggle this help",
        "Ctrl+C / D    quit",
    };

    fn drawHelp(self: *Tui) void {
        var inner_w: usize = displayWidth(help_title);
        for (help_lines) |l| inner_w = @max(inner_w, displayWidth(l));
        const box_w = inner_w + 4; // "│ " + text + " │"
        const box_h = help_lines.len + 2;
        if (box_w > self.cols or box_h + 2 > self.rows) return; // doesn't fit; hints still in bar
        const top: u16 = @intCast((@as(usize, self.msgViewportRows()) -| box_h) / 2 + 1);
        const left_col: u16 = @intCast((self.cols - box_w) / 2 + 1);

        self.writeFmt("\x1b[{d};{d}H", .{ top, left_col });
        self.rawWrite(self.theme.dim);
        self.rawWrite("\u{256D}");
        self.rawWrite(help_title);
        var i: usize = displayWidth(help_title);
        while (i < box_w - 2) : (i += 1) self.rawWrite("\u{2500}");
        self.rawWrite("\u{256E}");

        for (help_lines, 0..) |l, li| {
            self.writeFmt("\x1b[{d};{d}H", .{ top + 1 + @as(u16, @intCast(li)), left_col });
            self.rawWrite("\u{2502} ");
            self.rawWrite(l);
            var pad = inner_w - displayWidth(l);
            while (pad > 0) : (pad -= 1) self.rawWrite(" ");
            self.rawWrite(" \u{2502}");
        }

        self.writeFmt("\x1b[{d};{d}H", .{ top + 1 + @as(u16, @intCast(help_lines.len)), left_col });
        self.rawWrite("\u{2570}");
        i = 0;
        while (i < box_w - 2) : (i += 1) self.rawWrite("\u{2500}");
        self.rawWrite("\u{256F}");
        self.rawWrite(self.theme.reset);
    }

    fn positionCursor(self: *Tui) void {
        const rc = cursorRowCol(self.comp_rows.items, self.composer.text.items, self.composer.cursor);
        const vis_row: usize = rc.row -| self.comp_scroll;
        const term_row: usize = @as(usize, self.rows) - self.comp_h + vis_row;
        var term_col: usize = rc.col + 3; // 1-based, after the 2-col prompt
        if (term_col > self.cols) term_col = self.cols;
        self.writeFmt("\x1b[{d};{d}H", .{ term_row, term_col });
        self.rawWrite("\x1b[?25h");
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
        self.renderAll(); // bar's scroll indicator changes with the position
    }

    pub fn scrollLine(self: *Tui, dir: ScrollDir) void {
        self.scrollBy(if (dir == .up) 1 else -1);
    }

    pub fn scrollPage(self: *Tui, dir: ScrollDir) void {
        const page: isize = @max(1, @as(isize, @intCast(self.msgViewportRows())) - 1);
        self.scrollBy(if (dir == .up) page else -page);
    }

    pub fn scrolled(self: *Tui) bool {
        return self.view_start != null;
    }

    pub fn jumpTail(self: *Tui) void {
        self.view_start = null;
        self.renderAll();
    }

    pub fn setStyle(self: *Tui, todo_mode: bool) void {
        self.todo_mode = todo_mode;
        self.drawBar();
        if (!self.help_visible) self.positionCursor();
    }

    /// Tracks the agent's thinking flag; redraws the bar only on a state
    /// change so the render loop can call this every iteration for free.
    pub fn setBusy(self: *Tui, busy: bool) void {
        if (busy == self.busy) return;
        self.busy = busy;
        if (!busy) self.cancelling = false;
        self.drawBar();
        if (!self.help_visible) self.positionCursor();
    }

    pub fn setCancelling(self: *Tui) void {
        self.cancelling = true;
        self.drawBar();
        if (!self.help_visible) self.positionCursor();
    }

    /// Shows the human-approval prompt in the bar (takes a gpa-owned copy
    /// of `question`); the main loop routes y/n to the agent while active.
    pub fn setApproval(self: *Tui, question: []const u8) void {
        if (self.approval_text) |old| self.gpa.free(old);
        self.approval_text = self.gpa.dupe(u8, question) catch null;
        self.drawBar();
        if (!self.help_visible) self.positionCursor();
    }

    pub fn clearApproval(self: *Tui) void {
        if (self.approval_text) |old| self.gpa.free(old);
        self.approval_text = null;
        self.drawBar();
        if (!self.help_visible) self.positionCursor();
    }

    pub fn approvalActive(self: *Tui) bool {
        return self.approval_text != null;
    }

    pub fn toggleHelp(self: *Tui) void {
        self.help_visible = !self.help_visible;
        // Underlying content may be stale under the dismissed overlay.
        self.redraw();
    }

    /// Animation tick (~400ms, driven by the render loop's poll timeout):
    /// advances the bar's busy spinner/elapsed counter and blinks a pending
    /// tool dot. Returns true if anything was redrawn.
    pub fn tickDots(self: *Tui) bool {
        if (!self.busy and self.pending_tool_dot == null) return false;
        const now = monoNs();
        const elapsed_ms: i64 = @divTrunc(now - self.last_dot_ns, 1_000_000);
        if (elapsed_ms < 400) return false;
        self.last_dot_ns = now;
        self.dot_phase = (self.dot_phase + 1) % 3;
        if (self.busy) self.drawBar();
        if (self.pending_tool_dot) |offset| {
            self.tool_dot_blink_on = !self.tool_dot_blink_on;
            const dot = if (self.tool_dot_blink_on) tool_dot_pending_bright else tool_dot_pending_dim;
            if (offset + tool_dot_len <= self.transcript.items.len) {
                @memcpy(self.transcript.items[offset .. offset + tool_dot_len], dot);
            }
            self.renderMessages();
        }
        if (!self.help_visible) self.positionCursor();
        return true;
    }

    /// Streamed agent output: filter phase markers / divert plan bytes,
    /// rewrap the transcript tail, redraw.
    pub fn appendOutput(self: *Tui, bytes: []const u8) void {
        if (bytes.len == 0) return;
        self.processStream(bytes);
        self.rewrapTail();
        self.renderAll();
    }

    /// Call once, right when a prompt is handed off to the agent, to mark
    /// the start of the round trip that `onAgentDone()` will time.
    pub fn beginTurn(self: *Tui) void {
        self.turn_start_ns = monoNs();
        self.last_dot_ns = monoNs();
    }

    pub fn onAgentDone(self: *Tui) void {
        const elapsed_ns = monoNs() - self.turn_start_ns;
        const elapsed_s = @as(f64, @floatFromInt(@max(elapsed_ns, 0))) / 1_000_000_000.0;
        var buf: [64]u8 = undefined;
        // Close the response's last (open) line, report round-trip time on
        // its own dim line, then two blank separators before the next
        // prompt. (SGR here is stream data; NO_COLOR strips it at render.)
        const suffix = std.fmt.bufPrint(&buf, "\n\x1b[2m[{d:.1}s]\x1b[0m\n\n\n", .{elapsed_s}) catch "\n\n\n";
        self.appendBytes(suffix);
        self.rewrapTail();
        self.busy = false;
        self.cancelling = false;
        self.renderAll();
    }

    /// Feeds one input byte through UTF-8 accumulation and the composer.
    /// Returns true when Enter submitted non-empty input (the caller then
    /// harvests it via `takeInput`).
    ///
    /// Callers must intercept a leading ESC (27) themselves via
    /// `readEscapeSequence` before reaching here.
    pub fn handleKey(self: *Tui, key: u8) bool {
        if (self.pending_utf8_need > 0) {
            if (key & 0xC0 == 0x80) {
                self.pending_utf8[self.pending_utf8_len] = key;
                self.pending_utf8_len += 1;
                if (self.pending_utf8_len == self.pending_utf8_need) {
                    self.composer.insert(self.gpa, self.pending_utf8[0..self.pending_utf8_len]);
                    self.pending_utf8_need = 0;
                    self.pending_utf8_len = 0;
                    self.renderAll();
                }
                return false;
            }
            // Broken sequence: drop it and fall through to handle `key`.
            self.pending_utf8_need = 0;
            self.pending_utf8_len = 0;
        }
        switch (key) {
            27 => return false, // stray ESC that reached us anyway: no-op
            '\r', '\n' => {
                const text = self.composer.text.items;
                if (std.mem.indexOfNone(u8, text, " \t\n") == null) return false;
                self.appendBytes(self.theme.bold);
                self.appendBytes("You:");
                self.appendBytes(self.theme.reset);
                self.appendBytes(" ");
                self.appendBytes(text);
                self.appendBytes("\n\n"); // blank line before the response
                self.rewrapTail();
                self.view_start = null; // snap to live tail
                return true;
            },
            127, 8 => {
                self.composer.backspace(self.gpa);
                self.renderAll();
                return false;
            },
            1 => { // Ctrl+A
                self.composer.lineHome();
                self.renderAll();
                return false;
            },
            5 => { // Ctrl+E
                self.composer.lineEnd();
                self.renderAll();
                return false;
            },
            23 => { // Ctrl+W
                self.composer.deleteWordBack(self.gpa);
                self.renderAll();
                return false;
            },
            21 => { // Ctrl+U
                self.composer.clear();
                self.renderAll();
                return false;
            },
            else => {
                if (key >= 32 and key < 127) {
                    self.composer.insert(self.gpa, &[_]u8{key});
                    self.renderAll();
                } else if (key >= 0xC2 and key <= 0xF4) {
                    const need = std.unicode.utf8ByteSequenceLength(key) catch return false;
                    self.pending_utf8[0] = key;
                    self.pending_utf8_len = 1;
                    self.pending_utf8_need = @intCast(need);
                }
                return false;
            },
        }
    }

    pub fn insertNewline(self: *Tui) void {
        self.composer.insert(self.gpa, "\n");
        self.renderAll();
    }

    pub fn clearComposer(self: *Tui) void {
        self.composer.clear();
        self.renderAll();
    }

    pub const Move = enum { left, right, up, down, home, end, delete };

    pub fn composerMove(self: *Tui, m: Move) void {
        switch (m) {
            .left => self.composer.moveLeft(),
            .right => self.composer.moveRight(),
            .home => self.composer.lineHome(),
            .end => self.composer.lineEnd(),
            .delete => self.composer.deleteForward(self.gpa),
            .up, .down => {
                // Needs fresh wrap data to know the cursor's visual row.
                self.layoutComposer();
                const text = self.composer.text.items;
                const rc = cursorRowCol(self.comp_rows.items, text, self.composer.cursor);
                if (m == .up) {
                    if (rc.row == 0) {
                        self.composer.historyPrev(self.gpa);
                    } else {
                        self.composer.cursor = byteAtCol(text, self.comp_rows.items[rc.row - 1], rc.col);
                    }
                } else {
                    if (rc.row + 1 >= self.comp_rows.items.len) {
                        self.composer.historyNext(self.gpa);
                    } else {
                        self.composer.cursor = byteAtCol(text, self.comp_rows.items[rc.row + 1], rc.col);
                    }
                }
            },
        }
        self.renderAll();
    }

    pub fn pushHistory(self: *Tui, entry: []const u8) void {
        self.composer.pushHistory(self.gpa, entry);
    }

    /// Returns an owned copy of the current input, records it in prompt
    /// history, and resets the composer.
    pub fn takeInput(self: *Tui) []const u8 {
        const text: []const u8 = self.gpa.dupe(u8, self.composer.text.items) catch "";
        self.pushHistory(text);
        self.composer.clear();
        self.renderAll();
        return text;
    }
};

// ─── input escape sequences ───────────────────────────────────────────────────

/// What a byte sequence following a bare ESC turned out to mean.
/// `.escape` is a standalone Escape keypress (nothing queued after it);
/// `.none` is a recognized-but-unmapped sequence, fully consumed.
pub const EscapeResult = enum {
    none,
    escape,
    up,
    down,
    left,
    right,
    home,
    end_key,
    delete,
    page_up,
    page_down,
    alt_enter,
    wheel_up,
    wheel_down,
};

/// Reads and classifies what follows an ESC byte already read from `fd`:
/// CSI/SS3 sequences (arrows, Home/End, PgUp/PgDn, Delete), SGR mouse
/// reports (wheel), kitty CSI-u Enter variants, Alt+Enter — or nothing,
/// which means the user pressed Escape itself. Uses zero-timeout polls: a
/// lone Escape keypress has no follow-up bytes queued, so peeking
/// non-blockingly is the only way to tell "standalone Escape" from
/// "sequence introducer" without artificial delays.
pub fn readEscapeSequence(fd: posix.fd_t) EscapeResult {
    var pfd = [_]posix.pollfd{.{ .fd = fd, .events = posix.POLL.IN, .revents = 0 }};
    if ((posix.poll(&pfd, 0) catch 0) <= 0) return .escape;

    var b: [1]u8 = undefined;
    if (std.c.read(fd, &b, 1) <= 0) return .escape;

    if (b[0] == '\r' or b[0] == '\n') return .alt_enter;

    if (b[0] == 'O') {
        // SS3: exactly one more byte (Home/End on some terminals, F1-F4).
        if ((posix.poll(&pfd, 0) catch 0) <= 0) return .none;
        if (std.c.read(fd, &b, 1) <= 0) return .none;
        return switch (b[0]) {
            'H' => .home,
            'F' => .end_key,
            else => .none,
        };
    }

    if (b[0] != '[') return .none; // Alt+<key>: consumed, unmapped

    var param_buf: [24]u8 = undefined;
    var param_len: usize = 0;
    while ((posix.poll(&pfd, 0) catch 0) > 0) {
        if (std.c.read(fd, &b, 1) <= 0) return .none;
        if (b[0] >= 0x40 and b[0] <= 0x7e and b[0] != '<') {
            const params = param_buf[0..param_len];
            return switch (b[0]) {
                'A' => .up,
                'B' => .down,
                'C' => .right,
                'D' => .left,
                'H' => .home,
                'F' => .end_key,
                '~' => classifyTilde(params),
                'u' => classifyCsiU(params),
                'M', 'm' => classifyMouse(params, b[0]),
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

fn classifyTilde(params: []const u8) EscapeResult {
    if (std.mem.eql(u8, params, "1") or std.mem.eql(u8, params, "7")) return .home;
    if (std.mem.eql(u8, params, "4") or std.mem.eql(u8, params, "8")) return .end_key;
    if (std.mem.eql(u8, params, "3")) return .delete;
    if (std.mem.eql(u8, params, "5")) return .page_up;
    if (std.mem.eql(u8, params, "6")) return .page_down;
    return .none;
}

/// kitty CSI-u: honored if the terminal happens to send it (we never
/// request the protocol — progressive enhancement only). Enter (13) with
/// any modifier inserts a newline; a modified Escape (27) is still Escape.
fn classifyCsiU(params: []const u8) EscapeResult {
    const semi = std.mem.indexOfScalar(u8, params, ';') orelse params.len;
    const code = std.fmt.parseInt(u32, params[0..semi], 10) catch return .none;
    return switch (code) {
        13 => if (semi < params.len) .alt_enter else .none,
        27 => .escape,
        else => .none,
    };
}

/// SGR mouse report: `<button;x;y` + 'M' (press) / 'm' (release). Only the
/// wheel is mapped; clicks and drags are deliberately ignored (keyboard
/// has full parity — wheel capture is only worth it because alt-screen
/// wheel fallback would otherwise send arrow keys into the composer).
fn classifyMouse(params: []const u8, final: u8) EscapeResult {
    if (params.len == 0 or params[0] != '<') return .none;
    if (final != 'M') return .none;
    const rest = params[1..];
    const semi = std.mem.indexOfScalar(u8, rest, ';') orelse rest.len;
    const btn = std.fmt.parseInt(u32, rest[0..semi], 10) catch return .none;
    return switch (btn) {
        64 => .wheel_up,
        65 => .wheel_down,
        else => .none,
    };
}

// ─── terminal resize (SIGWINCH) ────────────────────────────────────────────────

var resize_pending: std.atomic.Value(bool) = .init(false);
var resize_wakeup_fd: posix.fd_t = -1;

fn onSigwinch(_: posix.SIG) callconv(.c) void {
    resize_pending.store(true, .release);
    // Nudge the render loop's poll() awake immediately. Without this, a
    // dragged/held resize fires SIGWINCH repeatedly; Zig's posix.poll
    // retries its *entire original timeout* on EINTR, so as long as
    // signals keep arriving faster than the timeout, poll() never returns
    // — the redraw would only happen once resizing pauses. write() is
    // async-signal-safe.
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

// ─── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

/// The raw O_NONBLOCK bit for the fcntl(F_SETFL) calls below. Not
/// `0o4000` — that's the Linux value; on Darwin `NONBLOCK` sits at bit 2
/// of `posix.O` (after the 2-bit `ACCMODE` field), i.e. `4`. Using the
/// wrong bit is a silent no-op (fcntl still returns success), so a "frame"
/// test's drain loop below blocks forever in `read()` once the pipe empties
/// — the write end stays open until after the loop, so there's no EOF to
/// stop it either. Derived from the struct rather than hardcoded again so
/// it can't drift from `posix.O`'s actual layout on whatever target this
/// is compiled for.
const o_nonblock: c_int = @bitCast(@as(u32, @bitCast(posix.O{ .NONBLOCK = true })));

fn testTui() !Tui {
    const null_fd = try posix.openatZ(posix.AT.FDCWD, "/dev/null", .{ .ACCMODE = .WRONLY }, 0);
    return Tui.init(testing.allocator, null_fd, Theme.init(true));
}

fn closeTui(ui: *Tui) void {
    const fd = ui.stdout_fd;
    ui.deinit();
    _ = std.c.close(fd);
}

test "charWidth: ascii, CJK, emoji, combining, ZWJ" {
    try testing.expectEqual(@as(u2, 1), charWidth('a'));
    try testing.expectEqual(@as(u2, 2), charWidth('世'));
    try testing.expectEqual(@as(u2, 2), charWidth(0x1F600)); // 😀
    try testing.expectEqual(@as(u2, 0), charWidth(0x0301)); // combining acute
    try testing.expectEqual(@as(u2, 0), charWidth(0x200D)); // ZWJ
    try testing.expectEqual(@as(u2, 1), charWidth('\u{2502}')); // │ box drawing stays narrow
}

test "wrapPlain: wraps by display width, never splits codepoints" {
    var rows: std.ArrayList(VRow) = .empty;
    defer rows.deinit(testing.allocator);

    // "世世世" = 3 codepoints × 2 cols; width 4 fits exactly two per row.
    wrapPlain(testing.allocator, &rows, "世世世", 4);
    try testing.expectEqual(@as(usize, 2), rows.items.len);
    try testing.expectEqual(@as(usize, 6), rows.items[0].len); // two 3-byte chars
    try testing.expectEqual(@as(usize, 6), rows.items[1].start);
    try testing.expectEqual(@as(usize, 3), rows.items[1].len);

    // newline handling + trailing empty row for cursor-after-\n
    wrapPlain(testing.allocator, &rows, "ab\n", 80);
    try testing.expectEqual(@as(usize, 2), rows.items.len);
    try testing.expectEqual(@as(usize, 0), rows.items[1].len);
}

test "transcript wrap: CJK counts columns not bytes" {
    var ui = try testTui();
    defer closeTui(&ui);
    ui.cols = 10;

    // 8 wide chars = 16 columns → must wrap at 5 chars (10 cols), not at
    // 10 bytes (3⅓ chars) the old byte-counting wrap would have produced.
    ui.appendOutput("世世世世世世世世");
    try testing.expectEqual(@as(usize, 2), ui.rows_cache.items.len);
    try testing.expectEqual(@as(usize, 15), ui.rows_cache.items[0].len); // 5 chars × 3 bytes
}

test "composer: utf-8 editing, cursor stays on codepoint boundaries" {
    var c: Composer = .{};
    defer c.deinit(testing.allocator);

    c.insert(testing.allocator, "a\u{4E16}b"); // a世b
    try testing.expectEqual(@as(usize, 5), c.cursor);
    c.moveLeft(); // before b
    c.moveLeft(); // before 世
    try testing.expectEqual(@as(usize, 1), c.cursor);
    c.deleteForward(testing.allocator); // remove 世 in one op
    try testing.expectEqualStrings("ab", c.text.items);
    c.insert(testing.allocator, "\u{1F600}");
    try testing.expectEqualStrings("a\u{1F600}b", c.text.items);
    c.backspace(testing.allocator); // removes all 4 emoji bytes
    try testing.expectEqualStrings("ab", c.text.items);
    try testing.expectEqual(@as(usize, 1), c.cursor);
}

test "composer: line ops and word delete" {
    var c: Composer = .{};
    defer c.deinit(testing.allocator);

    c.insert(testing.allocator, "first line\nsecond word");
    c.lineHome();
    try testing.expectEqual(@as(usize, 11), c.cursor); // after the \n
    c.lineEnd();
    try testing.expectEqual(@as(usize, 22), c.cursor);
    c.deleteWordBack(testing.allocator);
    try testing.expectEqualStrings("first line\nsecond ", c.text.items);
}

test "composer: history recall round-trip preserves live text" {
    var c: Composer = .{};
    defer c.deinit(testing.allocator);

    c.pushHistory(testing.allocator, "older");
    c.pushHistory(testing.allocator, "newer");
    c.insert(testing.allocator, "live");

    c.historyPrev(testing.allocator);
    try testing.expectEqualStrings("newer", c.text.items);
    c.historyPrev(testing.allocator);
    try testing.expectEqualStrings("older", c.text.items);
    c.historyNext(testing.allocator);
    try testing.expectEqualStrings("newer", c.text.items);
    c.historyNext(testing.allocator);
    try testing.expectEqualStrings("live", c.text.items);
    try testing.expect(c.hist_idx == null);
}

test "cursorRowCol: wrap boundary belongs to the next row" {
    var rows: std.ArrayList(VRow) = .empty;
    defer rows.deinit(testing.allocator);
    const text = "abcdef";
    wrapPlain(testing.allocator, &rows, text, 3);
    try testing.expectEqual(@as(usize, 2), rows.items.len);
    const rc = cursorRowCol(rows.items, text, 3);
    try testing.expectEqual(@as(usize, 1), rc.row);
    try testing.expectEqual(@as(usize, 0), rc.col);
}

test "tool-call marker: pending dot is detected and patched to ✓ in place" {
    var ui = try testTui();
    defer closeTui(&ui);

    // Matches exactly what core/engine.zig writes for a tool call: the
    // pending marker (no closing newline yet — dispatch is still "running").
    ui.appendOutput("\n[" ++ tool_dot_pending_bright ++ " calculator: add 2 and 3]");
    try testing.expect(ui.pending_tool_dot != null);
    const offset = ui.pending_tool_dot.?;
    try testing.expectEqualStrings(tool_dot_pending_bright, ui.transcript.items[offset .. offset + tool_dot_len]);

    // Blink tick: dot alternates to the dim variant while still pending.
    ui.last_dot_ns = 0; // force tickDots' 400ms threshold to have elapsed
    _ = ui.tickDots();
    try testing.expect(ui.pending_tool_dot != null);
    try testing.expectEqualStrings(tool_dot_pending_dim, ui.transcript.items[offset .. offset + tool_dot_len]);

    // The done-signal arrives (dispatch resolved successfully) — patches
    // the SAME bytes to the green ✓ and clears pending state; the
    // surrounding "[calculator: ...]" text is never re-emitted or altered.
    ui.appendOutput(tool_done_ok_sgr ++ "\n");
    try testing.expect(ui.pending_tool_dot == null);
    try testing.expectEqualStrings(tool_dot_ok, ui.transcript.items[offset .. offset + tool_dot_len]);
    try testing.expect(std.mem.indexOf(u8, ui.transcript.items, "calculator: add 2 and 3") != null);

    // A further blink tick is a no-op once nothing is pending.
    ui.last_dot_ns = 0;
    _ = ui.tickDots();
    try testing.expectEqualStrings(tool_dot_ok, ui.transcript.items[offset .. offset + tool_dot_len]);
}

test "error span: agent error markers produce err-guttered rows" {
    var ui = try testTui();
    defer closeTui(&ui);

    ui.appendOutput("before\n" ++ error_start_sgr ++ "tool failed\nbadly" ++ span_end_sgr ++ "\nafter");
    var saw_err = false;
    var saw_none = false;
    for (ui.rows_cache.items) |r| {
        switch (r.gutter) {
            .err => saw_err = true,
            .none => saw_none = true,
            .thinking, .code => return error.TestUnexpectedResult,
        }
    }
    try testing.expect(saw_err);
    try testing.expect(saw_none);
}

test "code fence: a ```-delimited block produces code-guttered rows, including the fence lines" {
    var ui = try testTui();
    defer closeTui(&ui);

    ui.appendOutput("before\n```zig\nconst x = 1;\n```\nafter");
    var saw_code = false;
    var saw_none = false;
    var code_rows: usize = 0;
    for (ui.rows_cache.items) |r| {
        switch (r.gutter) {
            .code => {
                saw_code = true;
                code_rows += 1;
            },
            .none => saw_none = true,
            .thinking, .err => return error.TestUnexpectedResult,
        }
    }
    try testing.expect(saw_code);
    try testing.expect(saw_none);
    // Both fence lines plus the one content line = 3 code-guttered rows.
    try testing.expectEqual(@as(usize, 3), code_rows);
    // The fence toggles closed, so trailing content is ungoverned again.
    try testing.expect(!ui.in_code);
}

test "inline code: a backtick span is colored and does not bleed past its closing tick" {
    var ui = try testTui();
    defer closeTui(&ui);

    ui.appendOutput("run `zig build test` now\n");
    try testing.expect(std.mem.indexOf(u8, ui.transcript.items, "`zig build test`") != null);
}

test "processStream: bracketed content flows through to the transcript untouched" {
    var ui = try testTui();
    defer closeTui(&ui);

    ui.appendOutput("[hook] calling calculator\n[cancelled]\n[plans are nice]\n[step without numbers]\n");
    try testing.expect(std.mem.indexOf(u8, ui.transcript.items, "[hook] calling calculator") != null);
    try testing.expect(std.mem.indexOf(u8, ui.transcript.items, "[cancelled]") != null);
    try testing.expect(std.mem.indexOf(u8, ui.transcript.items, "[plans are nice]") != null);
    try testing.expect(std.mem.indexOf(u8, ui.transcript.items, "[step without numbers]") != null);
}

test "todo panel: [todos]/[/todos] block is diverted out of the transcript and parsed into rows" {
    var ui = try testTui();
    defer closeTui(&ui);

    ui.appendOutput("\n[todos]\nTodo list (2 items):\n\u{2713} a\n\u{25CB} b\n[/todos]\n");

    try testing.expectEqual(@as(usize, 2), ui.todo_lines.items.len);
    try testing.expectEqual(@as(usize, 1), ui.todo_done);
    try testing.expectEqual(@as(usize, 2), ui.todo_total);
    try testing.expectEqualStrings("\u{2713} a", ui.todo_lines.items[0]);
    try testing.expectEqualStrings("\u{25CB} b", ui.todo_lines.items[1]);
    // None of it reached the chat view.
    try testing.expect(std.mem.indexOf(u8, ui.transcript.items, "Todo list") == null);
    try testing.expect(std.mem.indexOf(u8, ui.transcript.items, "[todos]") == null);
}

test "todo panel: markers split across arbitrary chunk boundaries still parse" {
    var ui = try testTui();
    defer closeTui(&ui);

    const stream = "\n[todos]\nTodo list (1 items):\n\u{25CF} in progress\n[/todos]\n";
    // Worst case: one byte per channel drain.
    for (stream) |b| ui.appendOutput(&[_]u8{b});

    try testing.expectEqual(@as(usize, 1), ui.todo_lines.items.len);
    try testing.expectEqualStrings("\u{25CF} in progress", ui.todo_lines.items[0]);
    try testing.expect(std.mem.indexOf(u8, ui.transcript.items, "Todo list") == null);
}

test "todo panel: an empty list hides the panel, a non-empty one shows it" {
    var ui = try testTui();
    defer closeTui(&ui);

    ui.appendOutput("\n[todos]\nTodo list (1 items):\n\u{25CB} step one\n[/todos]\n");
    try testing.expect(ui.todoPanelHeight() > 0);

    ui.appendOutput("\n[todos]\nTodo list is now empty.\n[/todos]\n");
    try testing.expectEqual(@as(usize, 0), ui.todo_lines.items.len);
    try testing.expectEqual(@as(u16, 0), ui.todoPanelHeight());
}

test "todo panel: survives onAgentDone — unlike the old plan panel, it is not turn-scoped" {
    var ui = try testTui();
    defer closeTui(&ui);

    ui.appendOutput("\n[todos]\nTodo list (1 items):\n\u{25CB} still going\n[/todos]\n");
    ui.onAgentDone();

    try testing.expectEqual(@as(usize, 1), ui.todo_lines.items.len);
    try testing.expectEqualStrings("\u{25CB} still going", ui.todo_lines.items[0]);
}

test "frame: pinned 80x24 render carries transcript, prompt, and bar" {
    var pipe_fds: [2]posix.fd_t = undefined;
    if (std.c.pipe(&pipe_fds) != 0) return error.PipeFailed;
    defer _ = std.c.close(pipe_fds[0]);
    // Non-blocking read end so the drain loop below terminates.
    const fl = std.c.fcntl(pipe_fds[0], posix.F.GETFL, @as(c_int, 0));
    _ = std.c.fcntl(pipe_fds[0], posix.F.SETFL, fl | o_nonblock); // O_NONBLOCK

    var ui = try Tui.init(testing.allocator, pipe_fds[1], Theme.init(true));
    defer {
        ui.deinit();
        _ = std.c.close(pipe_fds[1]);
    }
    // A pipe has no window size: init fell back to the pinned 80×24.
    try testing.expectEqual(@as(u16, 24), ui.rows);
    try testing.expectEqual(@as(u16, 80), ui.cols);

    ui.setContext("glm-test", "default");
    ui.composer.insert(testing.allocator, "typed");
    ui.appendOutput("hello world\n");

    var frame: std.ArrayList(u8) = .empty;
    defer frame.deinit(testing.allocator);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = std.c.read(pipe_fds[0], &buf, buf.len);
        if (n <= 0) break;
        try frame.appendSlice(testing.allocator, buf[0..@intCast(n)]);
    }

    try testing.expect(std.mem.indexOf(u8, frame.items, "hello world") != null);
    // Prompt glyph and composer text (an SGR reset sits between them).
    try testing.expect(std.mem.indexOf(u8, frame.items, "\u{276F}") != null);
    try testing.expect(std.mem.indexOf(u8, frame.items, " typed") != null);
    try testing.expect(std.mem.indexOf(u8, frame.items, "Enter send") != null); // idle hint bar
    try testing.expect(std.mem.indexOf(u8, frame.items, "[react]") != null); // style tag
    try testing.expect(std.mem.indexOf(u8, frame.items, "glm-test") != null); // model label
    try testing.expect(std.mem.indexOf(u8, frame.items, "\x1b[24;1H") != null); // bar on the last row
}

test "frame: todo panel renders above the composer with a done/total header and glyph colors" {
    var pipe_fds: [2]posix.fd_t = undefined;
    if (std.c.pipe(&pipe_fds) != 0) return error.PipeFailed;
    defer _ = std.c.close(pipe_fds[0]);
    const fl = std.c.fcntl(pipe_fds[0], posix.F.GETFL, @as(c_int, 0));
    _ = std.c.fcntl(pipe_fds[0], posix.F.SETFL, fl | o_nonblock); // O_NONBLOCK

    var ui = try Tui.init(testing.allocator, pipe_fds[1], Theme.init(true));
    defer {
        ui.deinit();
        _ = std.c.close(pipe_fds[1]);
    }

    ui.appendOutput("\n[todos]\nTodo list (2 items):\n\u{2713} first task\n\u{25CB} second task\n[/todos]\n");

    var frame: std.ArrayList(u8) = .empty;
    defer frame.deinit(testing.allocator);
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = std.c.read(pipe_fds[0], &buf, buf.len);
        if (n <= 0) break;
        try frame.appendSlice(testing.allocator, buf[0..@intCast(n)]);
    }

    // Panel sits directly above the 1-row composer at 80×24: header on row
    // 20, items on 21-22, composer row 23, bar row 24.
    try testing.expect(std.mem.indexOf(u8, frame.items, "todo 1/2") != null);
    try testing.expect(std.mem.indexOf(u8, frame.items, "\u{258D}") != null); // panel gutter
    // Done: green "✓" ahead of the item text.
    try testing.expect(std.mem.indexOf(u8, frame.items, "\u{2713} first task") != null);
    try testing.expect(std.mem.indexOf(u8, frame.items, "\x1b[20;1H") != null); // header row position
    // The list text never rendered inside the transcript viewport (its
    // only occurrences are the panel rows 20-22).
    try testing.expect(std.mem.indexOf(u8, frame.items, "Todo list") == null);
}

test "NO_COLOR: rendered output contains no SGR sequences" {
    var pipe_fds: [2]posix.fd_t = undefined;
    if (std.c.pipe(&pipe_fds) != 0) return error.PipeFailed;
    defer _ = std.c.close(pipe_fds[0]);
    const fl = std.c.fcntl(pipe_fds[0], posix.F.GETFL, @as(c_int, 0));
    _ = std.c.fcntl(pipe_fds[0], posix.F.SETFL, fl | o_nonblock);

    var ui = try Tui.init(testing.allocator, pipe_fds[1], Theme.init(false));
    defer {
        ui.deinit();
        _ = std.c.close(pipe_fds[1]);
    }

    // Stream data arrives with SGR in it (thinking span + colored label);
    // the render must strip all of it.
    ui.appendOutput("plain " ++ thinking_start_sgr ++ "thinking text" ++ span_end_sgr ++ " tail\n");

    var frame: std.ArrayList(u8) = .empty;
    defer frame.deinit(testing.allocator);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = std.c.read(pipe_fds[0], &buf, buf.len);
        if (n <= 0) break;
        try frame.appendSlice(testing.allocator, buf[0..@intCast(n)]);
    }

    // Cursor moves (CSI H/J/K) are fine; SGR ('m' final) must be gone.
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, frame.items, i, "\x1b[")) |p| {
        var j = p + 2;
        while (j < frame.items.len and !(frame.items[j] >= 0x40 and frame.items[j] <= 0x7e)) : (j += 1) {}
        try testing.expect(j < frame.items.len);
        try testing.expect(frame.items[j] != 'm');
        i = j;
    }
    try testing.expect(std.mem.indexOf(u8, frame.items, "thinking text") != null);
}

test "thinking span: a wrapped span colors every row, not just the first" {
    var pipe_fds: [2]posix.fd_t = undefined;
    if (std.c.pipe(&pipe_fds) != 0) return error.PipeFailed;
    defer _ = std.c.close(pipe_fds[0]);
    const fl = std.c.fcntl(pipe_fds[0], posix.F.GETFL, @as(c_int, 0));
    _ = std.c.fcntl(pipe_fds[0], posix.F.SETFL, fl | o_nonblock);

    var ui = try Tui.init(testing.allocator, pipe_fds[1], Theme.init(true));
    defer {
        ui.deinit();
        _ = std.c.close(pipe_fds[1]);
    }
    // Pipe → pinned 80×24; a thinking row reserves 2 gutter cols, so its
    // text wraps at column 78.
    try testing.expectEqual(@as(u16, 80), ui.cols);

    // 78 'a's fill row 0 exactly; the sentinel begins row 1. The span's
    // start marker is at the start of the logical line, so in `transcript`
    // the sentinel is NOT preceded by any SGR — only the per-row re-emit
    // in renderMessages can put `thinking_start_sgr` right before it.
    const payload = thinking_start_sgr ++ ("a" ** 78) ++ "SENTINEL" ++ ("a" ** 20) ++ span_end_sgr ++ "\n";
    ui.appendOutput(payload);

    var frame: std.ArrayList(u8) = .empty;
    defer frame.deinit(testing.allocator);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = std.c.read(pipe_fds[0], &buf, buf.len);
        if (n <= 0) break;
        try frame.appendSlice(testing.allocator, buf[0..@intCast(n)]);
    }

    // The continuation row's sentinel must be preceded by the re-emitted
    // span color — without the fix it renders in the terminal default.
    try testing.expect(std.mem.indexOf(u8, frame.items, thinking_start_sgr ++ "SENTINEL") != null);
    // And row 0 (which carries the marker in its own bytes) still renders.
    try testing.expect(std.mem.indexOf(u8, frame.items, thinking_start_sgr ++ ("a" ** 78)) != null);
}
