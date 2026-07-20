const std = @import("std");
const hook = @import("../../core/hook.zig");
const message = @import("../../core/message.zig");
const Message = message.Message;

/// Reference hook for task/todo tracking (design doc §3.8), paired with the
/// `todo_write` tool. Holds no state of its own — everything it does is
/// derived from message history each call, matching every other tool in
/// this codebase and avoiding any shared-mutable-state pattern between the
/// tool and this hook.
pub fn name() []const u8 {
    return "todo_tracker";
}

/// Shared prefix of whichever content this hook currently has injected —
/// the existing-list reminder or the create-a-list nudge below — so a later
/// call can find and refresh its own prior injection (whichever variant it
/// was) instead of appending a duplicate (docs/feat/hooks.MD: "hooks must
/// be idempotent about what they inject").
const injected_prefix = "[todo tracker] ";

/// Shown when `ctx.style == .todo` (the CLI/TUI style toggle, design doc
/// §3.5) and no `todo_write` call has happened yet this turn — the
/// mechanism that makes the toggle mean something now that it no longer
/// selects a different orchestrator loop.
const create_nudge_body = "no todo list yet. For any task with more than one meaningful " ++
    "step, call todo_write to create one before proceeding — keep exactly one item " ++
    "in_progress at a time and mark items completed as you finish them. Skip this for " ++
    "genuinely single-step requests.";

/// Wraps the raw checklist in `[todos]`/`[/todos]` markers (design doc
/// §5.1) instead of printing it inline: `tui/app.zig` diverts the captured
/// block into a live panel above the composer rather than the scrolling
/// transcript, the same bracket-marker convention §3.6 uses for tool-call
/// status. The `[<dot> todo_write: ...]` marker line itself is unaffected —
/// still produced for free by the existing engine mechanism (via
/// `todo_write.describe`).
pub fn postTool(
    ctx: hook.Ctx,
    tool_name: []const u8,
    result: *[]const u8,
) anyerror!void {
    if (!std.mem.eql(u8, tool_name, "todo_write")) return;
    const w = ctx.writer orelse return;

    try w.print("\n[todos]\n{s}\n[/todos]\n", .{result.*});
    try w.flush();
}

/// Re-derives "what the model should currently believe about its todo
/// list" from `messages` on every call and keeps exactly one system
/// message in the outbound view, refreshed in place — never a growing pile
/// of stale reminders. Two variants share the one slot: once a
/// `todo_write` result exists, its content wins (regardless of style — a
/// list already in progress is worth reminding about either way); before
/// that, `ctx.style == .todo` (design doc §3.5) injects a nudge to create
/// one, while plain `.react` stays silent, identical to today's behavior
/// with no todo tooling at all. Only touches `messages` (the outbound
/// view), never persisted memory — same split every other hook relies on
/// (design doc §3.7).
pub fn preLlm(ctx: hook.Ctx, messages: *std.ArrayList(Message)) anyerror!void {
    var latest_todos: ?[]const u8 = null;
    var i = messages.items.len;
    while (i > 0) {
        i -= 1;
        const m = messages.items[i];
        if (m.role == .tool and std.mem.eql(u8, m.name, "todo_write")) {
            latest_todos = m.content;
            break;
        }
    }

    var prior_idx: ?usize = null;
    for (messages.items, 0..) |m, idx| {
        if (m.role == .system and std.mem.startsWith(u8, m.content, injected_prefix)) {
            prior_idx = idx;
            break;
        }
    }

    const fresh: []const u8 = if (latest_todos) |todos|
        try std.fmt.allocPrint(ctx.scratch, "{s}current list:\n{s}", .{ injected_prefix, todos })
    else if (ctx.style == .todo)
        try std.fmt.allocPrint(ctx.scratch, "{s}{s}", .{ injected_prefix, create_nudge_body })
    else
        return; // plain ReAct, no list yet: stay silent

    if (prior_idx) |pi| {
        if (pi == messages.items.len - 1) {
            messages.items[pi].content = fresh;
            return;
        }
        _ = messages.orderedRemove(pi);
    }
    try messages.append(ctx.scratch, Message.system(fresh));
}

const testing = std.testing;

fn testCtx(arena: std.mem.Allocator) hook.Ctx {
    return .{ .gpa = testing.allocator, .scratch = arena, .writer = null };
}

test "preLlm: does nothing when no todo_write result exists yet and style is plain react" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var messages: std.ArrayList(Message) = .empty;
    try messages.append(arena.allocator(), Message.user("hello"));

    try preLlm(testCtx(arena.allocator()), &messages);

    try testing.expectEqual(@as(usize, 1), messages.items.len);
}

test "preLlm: nudges to create a list when style is .todo and none exists yet" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var messages: std.ArrayList(Message) = .empty;
    try messages.append(arena.allocator(), Message.user("do a multi-step task"));

    var ctx = testCtx(arena.allocator());
    ctx.style = .todo;
    try preLlm(ctx, &messages);

    try testing.expectEqual(@as(usize, 2), messages.items.len);
    try testing.expect(messages.items[1].role == .system);
    try testing.expect(std.mem.startsWith(u8, messages.items[1].content, injected_prefix));
    try testing.expect(std.mem.indexOf(u8, messages.items[1].content, "todo_write") != null);

    // Refreshing again must not duplicate the nudge.
    try preLlm(ctx, &messages);
    try testing.expectEqual(@as(usize, 2), messages.items.len);
}

test "preLlm: injects a reminder after a todo_write result, then refreshes in place without duplicating" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var messages: std.ArrayList(Message) = .empty;
    try messages.append(alloc, Message.user("do the task"));
    try messages.append(alloc, .{
        .role = .tool,
        .tool_call_id = "call_1",
        .name = "todo_write",
        .content = "Todo list (1 items):\n\u{25CB} step one",
    });

    try preLlm(testCtx(alloc), &messages);
    try testing.expectEqual(@as(usize, 3), messages.items.len);
    try testing.expect(std.mem.startsWith(u8, messages.items[2].content, injected_prefix));
    try testing.expect(std.mem.indexOf(u8, messages.items[2].content, "step one") != null);

    // A later todo_write call updates the list; another round-trip message
    // gets appended too (as real tool exchanges do), then preLlm fires
    // again — it must refresh the existing reminder, not add a second one.
    try messages.append(alloc, .{
        .role = .tool,
        .tool_call_id = "call_2",
        .name = "todo_write",
        .content = "Todo list (1 items):\n\u{2713} step one",
    });
    try preLlm(testCtx(alloc), &messages);

    var reminder_count: usize = 0;
    for (messages.items) |m| {
        if (m.role == .system and std.mem.startsWith(u8, m.content, injected_prefix)) reminder_count += 1;
    }
    try testing.expectEqual(@as(usize, 1), reminder_count);
    try testing.expect(std.mem.indexOf(u8, messages.items[messages.items.len - 1].content, "\u{2713} step one") != null);
}

test "postTool: wraps the raw checklist in [todos]/[/todos] markers, and only for todo_write" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var result: []const u8 = "Todo list (2 items):\n\u{25CF} a\n\u{25CB} b";
    var ctx = testCtx(arena.allocator());
    ctx.writer = &out.writer;
    try postTool(ctx, "todo_write", &result);

    try testing.expectEqualStrings(
        "\n[todos]\nTodo list (2 items):\n\u{25CF} a\n\u{25CB} b\n[/todos]\n",
        out.writer.buffer[0..out.writer.end],
    );

    out.clearRetainingCapacity();
    var other: []const u8 = "5";
    try postTool(ctx, "calculator", &other);
    try testing.expectEqual(@as(usize, 0), out.writer.end);
}
