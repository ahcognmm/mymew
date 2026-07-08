const std = @import("std");
const Io = std.Io;
const message = @import("message.zig");
pub const Message = message.Message;

/// Persistent append-only .jsonl memory, per the design doc's ".jsonl instead
/// of a database" decision. Hydrates the active context from disk on
/// `init`, appends new messages instantly, and rewrites the whole file only
/// when the orchestrator prunes the context after a self-healing failure.
pub const Memory = struct {
    arena: std.heap.ArenaAllocator,
    io: Io,
    dir: Io.Dir,
    path: []const u8,
    messages: std.ArrayList(Message) = .empty,

    pub fn init(child_alloc: std.mem.Allocator, io: Io, path: []const u8) !Memory {
        var self: Memory = .{
            .arena = std.heap.ArenaAllocator.init(child_alloc),
            .io = io,
            .dir = .cwd(),
            .path = path,
        };
        try self.hydrate();
        return self;
    }

    pub fn deinit(self: *Memory) void {
        self.arena.deinit();
    }

    fn hydrate(self: *Memory) !void {
        const bytes = self.dir.readFileAlloc(self.io, self.path, self.arena.allocator(), .limited(64 * 1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        var lines = std.mem.tokenizeScalar(u8, bytes, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            const msg = try std.json.parseFromSliceLeaky(Message, self.arena.allocator(), line, .{
                .ignore_unknown_fields = true,
            });
            try self.messages.append(self.arena.allocator(), msg);
        }
    }

    pub fn items(self: *const Memory) []const Message {
        return self.messages.items;
    }

    /// Instant append: adds to the active context and writes one new line
    /// to the physical file without touching what's already there.
    pub fn append(self: *Memory, msg: Message) !void {
        try self.messages.append(self.arena.allocator(), msg);
        try self.appendLine(msg);
    }

    fn appendLine(self: *Memory, msg: Message) !void {
        const scratch = self.arena.allocator();
        const line = try std.json.Stringify.valueAlloc(scratch, msg, .{});

        var file = try self.dir.createFile(self.io, self.path, .{ .truncate = false });
        defer file.close(self.io);
        const offset = try file.length(self.io);
        try file.writePositionalAll(self.io, line, offset);
        try file.writePositionalAll(self.io, "\n", offset + line.len);
    }

    /// "Context Cleanup": replaces the active context outright and rewrites
    /// the physical .jsonl file from scratch to match.
    pub fn prune(self: *Memory, new_messages: []const Message) !void {
        self.messages.clearRetainingCapacity();
        for (new_messages) |m| try self.messages.append(self.arena.allocator(), m);
        try self.rewrite();
    }

    fn rewrite(self: *Memory) !void {
        const scratch = self.arena.allocator();
        var buf: std.ArrayList(u8) = .empty;
        for (self.messages.items) |m| {
            const line = try std.json.Stringify.valueAlloc(scratch, m, .{});
            try buf.appendSlice(scratch, line);
            try buf.append(scratch, '\n');
        }
        try self.dir.writeFile(self.io, .{ .sub_path = self.path, .data = buf.items });
    }
};
