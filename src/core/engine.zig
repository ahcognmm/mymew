const std = @import("std");
const Io = std.Io;
const message = @import("message.zig");
const tool = @import("tool.zig");
const memory = @import("memory.zig");
const Message = message.Message;

/// Circuit breaker for the self-healing loop (design doc §3.3).
pub const max_retries: usize = 3;

/// Result of one `Engine.step` call.
pub const Outcome = union(enum) {
    /// The LLM produced a final text answer (no further tool calls).
    final: []const u8,
    /// `max_retries` was exceeded; this is the human-readable failure
    /// report to surface to the UI. The context has already been pruned.
    escalated: []const u8,
};

/// Builds a ReAct orchestrator over a fixed, comptime-known set of tools and
/// a duck-typed LLM `Provider`. `Tools` is a tuple of tool types (see
/// `core/tool.zig` for the contract); `Provider` is any type exposing:
///
///     pub fn chat(self: *Provider, gpa, io, messages: []const Message, tools: []const tool.Descriptor) anyerror!Message
///
/// Tool dispatch is a compile-time-unrolled series of string comparisons
/// (design doc §2, "Static Routing") rather than a runtime vtable.
pub fn Engine(comptime Tools: anytype, comptime Provider: type) type {
    const tool_count = @typeInfo(@TypeOf(Tools)).@"struct".fields.len;

    return struct {
        const Self = @This();

        pub const descriptors: [tool_count]tool.Descriptor = blk: {
            var d: [tool_count]tool.Descriptor = undefined;
            var i: usize = 0;
            for (Tools) |T| {
                d[i] = tool.descriptorOf(T);
                i += 1;
            }
            break :blk d;
        };

        provider: *Provider,
        mem: *memory.Memory,
        gpa: std.mem.Allocator,
        io: Io,

        pub fn init(gpa: std.mem.Allocator, io: Io, provider: *Provider, mem: *memory.Memory) Self {
            return .{ .provider = provider, .mem = mem, .gpa = gpa, .io = io };
        }

        /// Static routing: dispatches to the matching tool via compile-time
        /// unrolled string comparisons. An unrecognized tool name is treated
        /// the same as malformed arguments, feeding back into the
        /// self-healing loop instead of crashing the orchestrator.
        fn dispatch(self: *Self, tool_name: []const u8, args_json: []const u8) tool.InvokeResult {
            inline for (Tools) |T| {
                if (std.mem.eql(u8, tool_name, T.name())) {
                    return tool.invoke(T, self.gpa, args_json);
                }
            }
            return .{ .invalid_args = .{
                .tool_name = tool_name,
                .raw_args_json = args_json,
                .diagnostic = "no such tool is registered",
            } };
        }

        /// Runs the ReAct loop for one user turn: appends `user_text` (if
        /// given) to memory, then repeatedly calls the provider and executes
        /// any requested tools until the LLM returns a final answer, or the
        /// self-healing circuit breaker trips.
        pub fn step(self: *Self, user_text: ?[]const u8) !Outcome {
            if (user_text) |t| try self.mem.append(Message.user(t));

            // Known-good boundary: if we have to escalate, everything from
            // here onward (this turn's malformed attempts) gets pruned.
            const turn_start = self.mem.items().len;
            var retries: usize = 0;

            while (true) {
                const reply = try self.provider.chat(self.gpa, self.io, self.mem.items(), &descriptors);

                if (reply.tool_calls.len == 0) {
                    try self.mem.append(reply);
                    return .{ .final = reply.content };
                }

                try self.mem.append(reply);

                var last_failure: ?tool.InvokeResult = null;
                for (reply.tool_calls) |tc| {
                    const result = self.dispatch(tc.name, tc.arguments_json);
                    switch (result) {
                        .ok => |s| try self.mem.append(.{
                            .role = .tool,
                            .tool_call_id = tc.id,
                            .name = tc.name,
                            .content = s,
                        }),
                        .invalid_args => |e| {
                            last_failure = result;
                            const diag = try std.fmt.allocPrint(
                                self.gpa,
                                "Malformed arguments for tool \"{s}\": {s}\nRaw arguments: {s}\nFix the JSON and call the tool again.",
                                .{ e.tool_name, e.diagnostic, e.raw_args_json },
                            );
                            try self.mem.append(.{
                                .role = .tool,
                                .tool_call_id = tc.id,
                                .name = tc.name,
                                .content = diag,
                            });
                        },
                    }
                }

                if (last_failure) |f| {
                    retries += 1;
                    if (retries > max_retries) {
                        return try self.escalate(turn_start, f.invalid_args);
                    }
                }
            }
        }

        /// "Graceful Escalation & Context Pruning" (design doc §3.3): stops
        /// talking to the LLM, prunes the failed turn from memory down to a
        /// single system note, and returns a diagnostic report for the UI.
        fn escalate(
            self: *Self,
            turn_start: usize,
            failure: @TypeOf(@as(tool.InvokeResult, undefined).invalid_args),
        ) !Outcome {
            const report = try std.fmt.allocPrint(
                self.gpa,
                "Tool \"{s}\" failed after {d} retries and was escalated.\nLast raw arguments: {s}\nDiagnostic: {s}",
                .{ failure.tool_name, max_retries, failure.raw_args_json, failure.diagnostic },
            );

            var kept: std.ArrayList(Message) = .empty;
            defer kept.deinit(self.gpa);
            try kept.appendSlice(self.gpa, self.mem.items()[0..turn_start]);
            try kept.append(self.gpa, Message.system(
                "User was notified that the tool failed due to syntax errors.",
            ));
            try self.mem.prune(kept.items);

            return .{ .escalated = report };
        }
    };
}

const testing = std.testing;
const llm = @import("llm.zig");
const calculator = @import("../plugins/tools/calculator.zig");
const TestTools = .{calculator};

test "step: happy path executes a tool then returns the final answer" {
    var mock: llm.Mock = .{ .script = &.{
        .{ .role = .assistant, .tool_calls = &.{
            .{ .id = "call_1", .name = "calculator", .arguments_json = "{\"op\":\"add\",\"a\":2,\"b\":3}" },
        } },
        .{ .role = .assistant, .content = "The answer is 5." },
    } };

    const path = "/tmp/mymew_test_happy.jsonl";
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    std.Io.Dir.cwd().deleteFile(io, path) catch {};

    var mem = try memory.Memory.init(testing.allocator, io, path);
    defer mem.deinit();

    var eng = Engine(TestTools, llm.Mock).init(testing.allocator, io, &mock, &mem);
    const outcome = try eng.step("what is 2 + 3?");

    try testing.expect(outcome == .final);
    try testing.expectEqualStrings("The answer is 5.", outcome.final);
    try testing.expectEqual(@as(usize, 4), mem.items().len);
}

test "step: escalates and prunes context after max_retries malformed tool calls" {
    const bad_call = message.ToolCall{
        .id = "call_x",
        .name = "calculator",
        .arguments_json = "{\"op\":\"add\",\"a\":\"NOT_A_NUMBER\"}",
    };
    var mock: llm.Mock = .{ .script = &.{
        .{ .role = .assistant, .tool_calls = &.{bad_call} },
        .{ .role = .assistant, .tool_calls = &.{bad_call} },
        .{ .role = .assistant, .tool_calls = &.{bad_call} },
        .{ .role = .assistant, .tool_calls = &.{bad_call} },
    } };

    const path = "/tmp/mymew_test_escalate.jsonl";
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    std.Io.Dir.cwd().deleteFile(io, path) catch {};

    var mem = try memory.Memory.init(testing.allocator, io, path);
    defer mem.deinit();

    var eng = Engine(TestTools, llm.Mock).init(testing.allocator, io, &mock, &mem);
    const outcome = try eng.step("compute something that will keep failing");

    try testing.expect(outcome == .escalated);
    try testing.expectEqual(@as(usize, 2), mem.items().len);
    try testing.expectEqual(message.Role.user, mem.items()[0].role);
    try testing.expectEqual(message.Role.system, mem.items()[1].role);
}
