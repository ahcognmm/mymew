const std = @import("std");
const hook = @import("../../core/hook.zig");

/// Sample interceptor hook (design doc §3.7, docs/feat/hooks.MD): an
/// observe-only audit trail of tool dispatch, written to the live output
/// alongside the engine's own `[● name: action]` status markers. It never
/// mutates arguments or results and never vetoes — it validates the hook
/// plumbing end-to-end and serves as the reference hook plugin, the way
/// `calculator` serves as the reference tool.
pub fn name() []const u8 {
    return "tool_audit_log";
}

/// Longest run of args/result bytes echoed per audit line, so one audit
/// entry stays one line no matter how large the payload is.
const preview_len_max: usize = 96;

pub fn preTool(
    ctx: hook.Ctx,
    tool_name: []const u8,
    args_json: *[]const u8,
) anyerror!hook.PreToolAction {
    // No assert on tool_name/args: both arrive verbatim from the LLM
    // before dispatch validates them — external input is handled (printed
    // as-is), never asserted.
    comptime std.debug.assert(preview_len_max > 0);
    if (ctx.writer) |w| {
        // Leading newline only: the engine's marker line that follows
        // starts with its own "\n", which terminates this line.
        try w.print("\n[hook] calling {s} with ", .{tool_name});
        try writePreview(w, args_json.*);
        try w.flush();
    }
    return .proceed;
}

pub fn postTool(
    ctx: hook.Ctx,
    tool_name: []const u8,
    result: *[]const u8,
) anyerror!void {
    comptime std.debug.assert(preview_len_max > 0);
    if (ctx.writer) |w| {
        // The engine has already terminated the marker line (done-signal
        // plus newline) by the time postTool fires, so this line owns both
        // its start and its end.
        try w.print("[hook] {s} returned {d} bytes: ", .{ tool_name, result.*.len });
        try writePreview(w, result.*);
        try w.writeAll("\n");
        try w.flush();
    }
}

/// Writes at most `preview_len_max` bytes of `s`, backing up over a
/// partial multi-byte character at the cut (same approach as `tool.zig`'s
/// `truncateUtf8`) and collapsing control characters to spaces, so an
/// audit entry can never break the one-line rendering the surrounding
/// status markers rely on.
fn writePreview(w: *std.Io.Writer, s: []const u8) !void {
    var end = @min(s.len, preview_len_max);
    if (end < s.len) {
        while (end > 0 and (s[end] & 0xc0) == 0x80) end -= 1;
    }
    std.debug.assert(end <= s.len);
    std.debug.assert(end <= preview_len_max);
    for (s[0..end]) |c| {
        if (c < 0x20) {
            try w.writeAll(" ");
        } else {
            try w.writeAll(&[_]u8{c});
        }
    }
    if (end < s.len) {
        try w.writeAll("…");
    }
}

test "writePreview truncates long payloads and collapses control bytes" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try writePreview(&out.writer, "line1\nline2\ttabbed");
    try std.testing.expectEqualStrings(
        "line1 line2 tabbed",
        out.writer.buffer[0..out.writer.end],
    );

    const long = "x" ** (preview_len_max + 10);
    var out2: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out2.deinit();
    try writePreview(&out2.writer, long);
    // preview_len_max bytes of payload plus the 3-byte ellipsis.
    try std.testing.expectEqual(
        preview_len_max + "…".len,
        out2.writer.end,
    );
}
