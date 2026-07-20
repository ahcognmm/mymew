//! Interceptor hook (design doc §3.7) that pins a system prompt at the top
//! of every outbound provider view. The engine itself has no system-prompt
//! concept — persisted memory starts at the first user message — so this
//! hook supplies one the same way `todo_tracker` supplies its reminder:
//! view-only, never persisted, re-checked on every provider call.
//!
//! The prompt text is compiled in via `@embedFile` — edit
//! `prompts/devops.md` and rebuild to change it, the same clone-and-strip
//! workflow as every other plugin (drop this hook from `main.zig`'s tuple
//! to run promptless).

const std = @import("std");
const hook = @import("../../core/hook.zig");
const message = @import("../../core/message.zig");
const Message = message.Message;

pub const prompt: []const u8 = @embedFile("prompts/devops.md");

pub fn name() []const u8 {
    return "system_prompt";
}

/// Inserts the prompt at index 0 unless it is already there. Idempotence
/// across `runToolLoop` iterations (docs/feat/hooks.MD) is by pointer
/// identity: the hook only ever inserts this one comptime constant, so
/// "already there" is exact, and a hydrated transcript that happens to
/// start with some other system message still gets the prompt above it.
pub fn preLlm(ctx: hook.Ctx, messages: *std.ArrayList(Message)) anyerror!void {
    if (messages.items.len > 0 and
        messages.items[0].role == .system and
        messages.items[0].content.ptr == prompt.ptr) return;
    try messages.insert(ctx.scratch, 0, Message.system(prompt));
}

const testing = std.testing;

test "preLlm inserts the prompt at view position 0 exactly once" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const ctx: hook.Ctx = .{ .gpa = testing.allocator, .scratch = scratch, .writer = null };

    var view: std.ArrayList(Message) = .empty;
    try view.append(scratch, Message.user("check disk usage"));

    try preLlm(ctx, &view);
    try testing.expectEqual(@as(usize, 2), view.items.len);
    try testing.expectEqual(message.Role.system, view.items[0].role);
    try testing.expectEqualStrings(prompt, view.items[0].content);

    // Second loop iteration: nothing added, nothing moved.
    try preLlm(ctx, &view);
    try testing.expectEqual(@as(usize, 2), view.items.len);
    try testing.expectEqual(message.Role.user, view.items[1].role);
}
