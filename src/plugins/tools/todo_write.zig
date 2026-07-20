const std = @import("std");

/// Reference tool for task/todo tracking (design doc §3.8): the model's own
/// checklist for a multi-step turn. `todo_tracker.zig` (the paired hook)
/// reads this tool's output back out of message history to keep the model
/// aware of the list on every later call — this tool itself holds no state,
/// consistent with every other tool in this directory.
pub const Status = enum { pending, in_progress, completed };

pub const TodoItem = struct {
    content: []const u8,
    status: Status,
};

/// The full list, every call: this call *replaces* the previous list
/// wholesale rather than diffing/merging, so the caller (the LLM) must pass
/// every item — completed ones included — not just what changed.
pub const Args = struct {
    todos: []const TodoItem,
};

pub fn name() []const u8 {
    return "todo_write";
}

pub fn description() []const u8 {
    return "Replace the current todo list with the given list. Always pass the FULL " ++
        "list, not just changed items — this call replaces the whole list. Use for " ++
        "multi-step work: write the list before starting, keep exactly one item " ++
        "in_progress at a time, and mark an item completed immediately after " ++
        "finishing it (don't batch completions).";
}

pub fn describe(alloc: std.mem.Allocator, args: Args) anyerror![]const u8 {
    return std.fmt.allocPrint(alloc, "Updating todo list ({d} items)", .{args.todos.len});
}

fn glyphFor(status: Status) []const u8 {
    return switch (status) {
        .completed => "\u{2713}", // ✓
        .in_progress => "\u{25CF}", // ●
        .pending => "\u{25CB}", // ○
    };
}

/// Renders the list as plain text (no ANSI/SGR — this becomes both the
/// persisted `.tool` message content the LLM reads back and the source
/// `todo_tracker.postTool` streams to the TUI, indented). Empty list is a
/// valid, explicit way to clear the checklist once a task is done.
pub fn execute(alloc: std.mem.Allocator, args: Args) anyerror![]const u8 {
    if (args.todos.len == 0) return alloc.dupe(u8, "Todo list is now empty.");

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.print(alloc, "Todo list ({d} items):", .{args.todos.len});
    for (args.todos) |item| {
        try out.print(alloc, "\n{s} {s}", .{ glyphFor(item.status), item.content });
    }
    return out.toOwnedSlice(alloc);
}

const testing = std.testing;

test "execute: renders each item with its status glyph" {
    const result = try execute(testing.allocator, .{ .todos = &.{
        .{ .content = "locate plan-mode code", .status = .completed },
        .{ .content = "trace step execution", .status = .in_progress },
        .{ .content = "write report", .status = .pending },
    } });
    defer testing.allocator.free(result);
    try testing.expectEqualStrings(
        "Todo list (3 items):\n\u{2713} locate plan-mode code\n\u{25CF} trace step execution\n\u{25CB} write report",
        result,
    );
}

test "execute: empty list renders an explicit clear message" {
    const result = try execute(testing.allocator, .{ .todos = &.{} });
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("Todo list is now empty.", result);
}

test "describe: reports item count" {
    const result = try describe(testing.allocator, .{ .todos = &.{
        .{ .content = "a", .status = .pending },
        .{ .content = "b", .status = .pending },
    } });
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("Updating todo list (2 items)", result);
}

test "Args round-trips through std.json (nested array-of-struct, the schema fix this depends on)" {
    const json =
        \\{"todos":[{"content":"a","status":"pending"},{"content":"b","status":"in_progress"}]}
    ;
    var parsed = try std.json.parseFromSlice(Args, testing.allocator, json, .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 2), parsed.value.todos.len);
    try testing.expect(parsed.value.todos[1].status == .in_progress);
}
