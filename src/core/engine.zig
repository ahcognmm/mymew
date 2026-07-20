const std = @import("std");
const Io = std.Io;
const message = @import("message.zig");
const tool = @import("tool.zig");
const memory = @import("memory.zig");
const hook = @import("hook.zig");
const Message = message.Message;
const assert = std.debug.assert;

/// Circuit breaker for the self-healing loop (design doc §3.3).
pub const max_retries: usize = 3;

/// Result of one `Engine.step` call.
pub const Outcome = union(enum) {
    /// The LLM produced a final text answer (no further tool calls).
    final: []const u8,
    /// `max_retries` was exceeded; this is the human-readable failure
    /// report to surface to the UI. The context has already been pruned.
    escalated: []const u8,
    /// The user cancelled the turn (`requestCancel`) and the engine bailed
    /// at the next loop boundary. Whatever the turn produced up to that
    /// point stays in memory, followed by a system note recording the
    /// cancellation — no pruning, a cancel is not a failure (§3.4).
    cancelled,
};

/// Re-exported from `hook.zig` (its canonical home — see that file's doc
/// comment) so existing `engine.Style` references throughout this codebase
/// keep working unchanged.
pub const Style = hook.Style;

/// Byte-length-identical (12 bytes: `ESC [ NN m` + a 3-byte UTF-8 glyph +
/// `ESC [ 0 m`) SGR-wrapped status markers for the tool-call line
/// (design doc §3.6). Same length is deliberate: `tui/app.zig` locates the
/// pending dot's bytes once (when it first sees `tool_pending_sgr`, the
/// 5-byte color-set prefix that's also the first 5 bytes of this 12-byte
/// unit) and later overwrites them *in place* with one of the other three
/// — never re-emits the surrounding `[name: action]` text, so a tool call
/// still reads as exactly one line after its dot settles. The finals are
/// `✓`/`✗` rather than green/red dots so success and failure stay
/// distinguishable without color (monochrome terminals, red-green CVD);
/// both are 3-byte UTF-8 like `●`, keeping the 12-byte patch invariant.
/// Pending is plain yellow (not blink-attribute yellow): the TUI does the
/// actual blinking itself, by toggling these bytes on a timer (`Tui.
/// tickDots`), rather than relying on terminal-native SGR blink support,
/// which many terminals ignore.
pub const tool_dot_pending = "\x1b[33m\u{25CF}\x1b[0m";
pub const tool_dot_pending_dim = "\x1b[90m\u{25CF}\x1b[0m";
pub const tool_dot_ok = "\x1b[32m\u{2713}\x1b[0m";
pub const tool_dot_fail = "\x1b[31m\u{2717}\x1b[0m";
/// The color-set prefix of `tool_dot_pending` — what `tui/app.zig`'s
/// `wrapLogicalLine` actually matches against to record the dot's offset.
const tool_pending_sgr_full = tool_dot_pending;
/// Zero-width, carries no visible content of its own (never wraps a text
/// span the way `thinking_start_sgr`/`_end_sgr` do) — an undefined SGR
/// sub-code (unused by the real ANSI/SGR spec) that compliant terminals
/// silently ignore if any of it ever leaks through unstripped, meaning
/// `tui/app.zig` must intercept and act on it, not just pass it through.
const tool_done_ok_sgr = "\x1b[900m";
const tool_done_fail_sgr = "\x1b[901m";

/// Collapses newlines/tabs/carriage-returns in `s` into single spaces, so a
/// tool-call marker line (design doc §3.6) always renders as exactly one
/// line even when the underlying arguments span multiple lines (e.g. a
/// multi-line shell command).
fn oneLine(alloc: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var in_space = false;
    for (s) |c| {
        if (c == '\n' or c == '\r' or c == '\t') {
            if (!in_space) {
                try out.append(alloc, ' ');
                in_space = true;
            }
        } else {
            try out.append(alloc, c);
            in_space = false;
        }
    }
    return out.toOwnedSlice(alloc);
}

/// Builds a ReAct orchestrator (§3) over a fixed, comptime-known set of
/// tools and a duck-typed LLM `Provider`. `Tools` is
/// a tuple of tool types (see `core/tool.zig` for the contract); `Provider`
/// is any type exposing:
///
///     pub fn chat(self: *Provider, gpa, io, messages: []const Message, tools: []const tool.Descriptor) anyerror!Message
///
/// `Hooks` is a tuple of interceptor hook types (see `core/hook.zig` for
/// the sparse contract, design doc §3.7/§9) that observe, mutate, or veto
/// the orchestration steps; pass `.{}` for no hooks. Hooks fire in tuple
/// order at every hook point, mutations chain, and the first `preTool`
/// veto short-circuits the remaining hooks for that call.
///
/// Tool dispatch is a compile-time-unrolled series of string comparisons
/// (design doc §2, "Static Routing") rather than a runtime vtable; hook
/// dispatch is the same pattern via `inline for` + `@hasDecl`.
pub fn Engine(comptime Tools: anytype, comptime Provider: type, comptime Hooks: anytype) type {
    const tool_count = @typeInfo(@TypeOf(Tools)).@"struct".fields.len;

    comptime {
        for (Hooks) |H| hook.assertContract(H);
    }

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
        /// Shared by pointer across the render thread and the background
        /// orchestrator thread (see `core/agent.zig`'s `eng` field, which
        /// the render thread is expected to call `setStyle` on directly) —
        /// must stay atomic, same convention as `io_bus.AgentState.thinking`.
        style: std.atomic.Value(Style) = .init(.react),
        /// Cooperative cancellation flag (§3.4), set from another thread
        /// via `requestCancel` while a turn is running. Checked only at the
        /// top of `runToolLoop`'s loop — before each provider call — never
        /// mid-HTTP-stream, so a cancel takes effect at the next boundary
        /// rather than instantly. Cleared at the start of every `step()` so
        /// a cancel that lands after a turn already finished can't kill the
        /// next one.
        cancel_requested: std.atomic.Value(bool) = .init(false),

        pub fn init(gpa: std.mem.Allocator, io: Io, provider: *Provider, mem: *memory.Memory) Self {
            return .{ .provider = provider, .mem = mem, .gpa = gpa, .io = io };
        }

        pub fn setStyle(self: *Self, s: Style) void {
            self.style.store(s, .release);
        }

        /// Asks the running turn to stop at its next loop boundary (§3.4).
        /// Safe to call from any thread; a no-op when nothing is running
        /// (the flag is cleared when the next turn starts).
        pub fn requestCancel(self: *Self) void {
            self.cancel_requested.store(true, .release);
        }

        /// True (and consumes nothing — the flag stays set so every later
        /// boundary in the same turn also bails) when the current turn
        /// should stop. Persists a system note the first time the caller
        /// acts on it via `finishCancelled`.
        fn cancelPending(self: *Self) bool {
            return self.cancel_requested.load(.acquire);
        }

        /// Shared cancel epilogue: records the cancellation in persistent
        /// memory (so the next turn's LLM knows the previous one was cut
        /// short rather than silently truncated) and emits the `[cancelled]`
        /// stream marker.
        fn finishCancelled(self: *Self, writer: ?*Io.Writer) !Outcome {
            try self.mem.append(Message.system(
                "Turn cancelled by the user before completion.",
            ));
            if (writer) |w| {
                try w.writeAll("\n[cancelled]\n");
                try w.flush();
            }
            return .cancelled;
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

        /// Comptime-dispatched (mirrors `dispatch`'s `inline for`) human
        /// description of a tool call, for the single-line `[● name: ...]`
        /// marker (see `runToolLoop`) — always allocator-owned and never
        /// containing an embedded newline, so one tool call always renders
        /// as exactly one marker line regardless of what its raw arguments
        /// (e.g. a multi-line shell command) contain.
        fn describeToolCall(self: *Self, tool_name: []const u8, args_json: []const u8) ![]const u8 {
            const raw = raw: {
                inline for (Tools) |T| {
                    if (std.mem.eql(u8, tool_name, T.name())) {
                        break :raw try tool.describeArgs(T, self.gpa, args_json);
                    }
                }
                break :raw try self.gpa.dupe(u8, tool_name);
            };
            defer self.gpa.free(raw);
            return oneLine(self.gpa, raw);
        }

        /// Runs one user turn (ReAct, §3.1-3.3). `writer`, if non-null,
        /// receives streaming content tokens from the provider and
        /// tool-dispatch progress lines as they happen.
        ///
        /// The `onTurnStart`/`onTurnEnd` hooks fire exactly once per
        /// user-facing turn. The turn arena exists because these two hooks
        /// need a `Ctx.scratch`, and `runToolLoop`'s `loop_arena` doesn't
        /// exist yet at turn start and is already gone by turn end.
        pub fn step(self: *Self, user_text: ?[]const u8, writer: ?*Io.Writer) !Outcome {
            self.cancel_requested.store(false, .monotonic);
            var turn_arena = std.heap.ArenaAllocator.init(self.gpa);
            defer turn_arena.deinit();
            const ctx: hook.Ctx = .{
                .gpa = self.gpa,
                .scratch = turn_arena.allocator(),
                .writer = writer,
                .style = self.style.load(.acquire),
            };

            var text = user_text;
            // Address-of keeps the Hooks == .{} instantiation compiling:
            // only hooks reference/mutate these, and Zig prunes the
            // `inline for` bodies away entirely for an empty tuple.
            _ = &ctx;
            _ = &text;
            inline for (Hooks) |H| {
                if (@hasDecl(H, "onTurnStart")) try H.onTurnStart(ctx, &text);
            }

            const mem_count_turn_start = self.mem.items().len;
            const outcome = try self.stepReact(text, writer);
            // Paired prune-semantics invariants (§3.3): a completed turn
            // only ever grows memory; an escalated turn prunes back to at
            // most [user_message, system_note] past the turn boundary. A
            // cancelled turn (§3.4) grows memory too (partial work + the
            // cancellation note stay), so the `.final` bound covers it.
            if (outcome == .final or outcome == .cancelled) assert(self.mem.items().len > mem_count_turn_start);
            if (outcome == .escalated) assert(self.mem.items().len <= mem_count_turn_start + 2);
            // Callers own `.escalated`; if an onTurnEnd hook errors out
            // below, free it here or nobody will.
            errdefer if (outcome == .escalated) self.gpa.free(outcome.escalated);

            inline for (Hooks) |H| {
                if (@hasDecl(H, "onTurnEnd")) try H.onTurnEnd(ctx, &outcome);
            }
            return outcome;
        }

        /// The ReAct loop (design doc §3.1-3.3) for one user turn: appends
        /// `user_text` (if given) to memory, then runs `runToolLoop` once.
        fn stepReact(self: *Self, user_text: ?[]const u8, writer: ?*Io.Writer) !Outcome {
            // `Memory.append` deep-copies into its own arena, so `t` only
            // needs to stay valid for the duration of this call — no need
            // for our own throwaway dupe here.
            if (user_text) |t| try self.mem.append(Message.user(t));

            // Known-good boundary: if we have to escalate, everything from
            // here onward (this turn's malformed attempts) gets pruned.
            const turn_start = self.mem.items().len;
            return self.runToolLoop(turn_start, writer);
        }

        /// Runs one provider-call/tool-dispatch/self-healing cycle to
        /// completion — either a final text answer or an escalation. Called
        /// once per turn by `stepReact`, against `self.mem.items()` as it
        /// stood at `turn_start`.
        fn runToolLoop(self: *Self, turn_start: usize, writer: ?*Io.Writer) !Outcome {
            assert(turn_start <= self.mem.items().len);
            var retries: usize = 0;

            // Grows as tool calls happen within this loop, seeded from
            // `self.mem`, so the model keeps seeing its own tool calls and
            // their results across iterations.
            var loop_arena = std.heap.ArenaAllocator.init(self.gpa);
            defer loop_arena.deinit();
            const scratch = loop_arena.allocator();
            var view: std.ArrayList(Message) = .empty;
            try view.appendSlice(scratch, self.mem.items());

            const ctx: hook.Ctx = .{
                .gpa = self.gpa,
                .scratch = scratch,
                .writer = writer,
                .style = self.style.load(.acquire),
            };

            while (true) {
                // §3.4: bail before the next provider call — the one long,
                // uninterruptible pole — never mid-stream.
                if (self.cancelPending()) return self.finishCancelled(writer);

                // Fires every iteration against the same accumulating
                // `view` — hooks must be idempotent about what they inject
                // (docs/feat/hooks.MD, "Documented limitations").
                inline for (Hooks) |H| {
                    if (@hasDecl(H, "preLlm")) try H.preLlm(ctx, &view);
                }

                const reply = try self.provider.chat(self.gpa, self.io, view.items, &descriptors, writer);

                // Content-only override: `reply` itself is never touched,
                // so `freeReply` below stays in sync with what the
                // provider allocated. Cannot un-stream tokens the provider
                // already wrote live to `writer`.
                var content_override: ?[]const u8 = null;
                _ = &content_override;
                inline for (Hooks) |H| {
                    if (@hasDecl(H, "postLlm")) try H.postLlm(ctx, &reply, &content_override);
                }
                var persisted = reply;
                if (content_override) |c| persisted.content = c;

                if (reply.tool_calls.len == 0) {
                    try self.mem.append(persisted);
                    // Return the arena-owned copy Memory just made, not
                    // `persisted.content` itself — the override is
                    // scratch-owned and `reply.content` is freed below.
                    const stored_content = self.mem.items()[self.mem.items().len - 1].content;
                    freeReply(self.gpa, reply);
                    if (writer) |w| {
                        try w.writeAll("\n");
                        try w.flush();
                    }
                    return .{ .final = stored_content };
                }

                try self.mem.append(persisted);
                try view.append(scratch, self.mem.items()[self.mem.items().len - 1]);

                var last_failure: ?tool.InvokeResult = null;
                for (reply.tool_calls) |*tc| {
                    const failure = try self.runToolLoopDispatchCall(ctx, &view, tc, writer);
                    if (failure) |f| last_failure = f;
                }

                if (last_failure) |f| {
                    retries += 1;
                    // The circuit breaker (§3.3) bounds this otherwise
                    // unbounded provider/tool event loop on the failure
                    // path.
                    assert(retries <= max_retries + 1);
                    if (retries > max_retries) {
                        if (writer) |w| {
                            try w.print("[escalating after {d} retries]\n", .{max_retries});
                            try w.flush();
                        }
                        // escalate() copies what it needs out of `f`
                        // (which aliases reply.tool_calls) before we free.
                        const outcome = try self.escalate(turn_start, f.invalid_args, ctx);
                        freeReply(self.gpa, reply);
                        return outcome;
                    }
                }
                freeReply(self.gpa, reply);
            }
        }

        /// Handles one tool call end-to-end for `runToolLoop`: fires the
        /// `preTool` hooks (before the marker write, so hook output lands
        /// on its own line and the marker describes the args actually
        /// dispatched), writes the `[<dot> name: action]` marker, then
        /// either honors a veto or dispatches. Returns the failure (if
        /// any) for the caller's self-healing retry accounting; a veto is
        /// not a failure.
        ///
        /// Marker mechanics: the dot starts pending-yellow
        /// (`tool_pending_sgr_full`) — tui/app.zig watches for that exact
        /// escape sequence to record where this dot's bytes live, then
        /// blinks it in place (tick-based, see Tui.tickDots) and, once
        /// dispatch resolves, patches it green/red using the done-signal
        /// written below. Nothing about this line's text ever changes
        /// after this write — only the dot's 12-byte color sequence gets
        /// overwritten in place, so the whole call still reads as exactly
        /// one line.
        fn runToolLoopDispatchCall(
            self: *Self,
            ctx: hook.Ctx,
            view: *std.ArrayList(Message),
            tc: *const message.ToolCall,
            writer: ?*Io.Writer,
        ) !?tool.InvokeResult {
            // First veto wins: later hooks' preTool methods don't fire for
            // this call (docs/feat/hooks.MD, "Composition").
            var args_json: []const u8 = tc.arguments_json;
            var veto: ?[]const u8 = null;
            _ = &args_json;
            _ = &veto;
            inline for (Hooks) |H| {
                if (@hasDecl(H, "preTool")) {
                    if (veto == null) {
                        switch (try H.preTool(ctx, tc.name, &args_json)) {
                            .proceed => {},
                            .veto => |m| veto = m,
                        }
                    }
                }
            }

            const action = try self.describeToolCall(tc.name, args_json);
            defer self.gpa.free(action);
            if (writer) |w| {
                try w.print("\n[{s} {s}: {s}]", .{ tool_pending_sgr_full, tc.name, action });
                try w.flush();
            }

            if (veto) |veto_message| {
                // Red dot — the tool did not run — but the veto message
                // still flows the success path back to the LLM below, and
                // never counts as a self-healing retry.
                if (writer) |w| {
                    try w.writeAll(tool_done_fail_sgr ++ "\n");
                    try w.flush();
                }
                try self.appendToolResult(ctx, view, tc, veto_message, .scratch);
                return null;
            }

            const result = self.dispatch(tc.name, args_json);
            switch (result) {
                .ok => |s| {
                    if (writer) |w| {
                        try w.writeAll(tool_done_ok_sgr ++ "\n");
                        try w.flush();
                    }
                    try self.appendToolResult(ctx, view, tc, s, .gpa);
                    return null;
                },
                .invalid_args => |e| {
                    // Self-healing diagnostics bypass postTool on purpose:
                    // a hook rewriting one would corrupt the retry loop's
                    // feedback (docs/feat/hooks.MD, "postTool firing
                    // scope").
                    if (writer) |w| {
                        try w.writeAll(tool_done_fail_sgr ++ "\n");
                        try w.flush();
                    }
                    const mem_count_before = self.mem.items().len;
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
                    try view.append(ctx.scratch, self.mem.items()[self.mem.items().len - 1]);
                    self.gpa.free(diag);
                    // Exactly one tool message per call, same postcondition
                    // the success path asserts in appendToolResult.
                    assert(self.mem.items().len == mem_count_before + 1);
                    return result;
                },
            }
        }

        /// Runs the `postTool` hooks over a successful (or vetoed) tool
        /// result, persists whatever they left in place, and grows the
        /// outbound view. `text_owner` says who owns `text`: `.gpa` is the
        /// dispatcher's allocation — always freed here, even when a hook
        /// swapped the persisted value to scratch memory — while
        /// `.scratch` (a veto or hook replacement) is the loop arena's and
        /// must never be freed piecemeal.
        fn appendToolResult(
            self: *Self,
            ctx: hook.Ctx,
            view: *std.ArrayList(Message),
            tc: *const message.ToolCall,
            text: []const u8,
            text_owner: enum { gpa, scratch },
        ) !void {
            const mem_count_before = self.mem.items().len;
            const view_count_before = view.items.len;

            var result_text: []const u8 = text;
            _ = &result_text;
            inline for (Hooks) |H| {
                if (@hasDecl(H, "postTool")) try H.postTool(ctx, tc.name, &result_text);
            }
            try self.mem.append(.{
                .role = .tool,
                .tool_call_id = tc.id,
                .name = tc.name,
                .content = result_text,
            });
            try view.append(ctx.scratch, self.mem.items()[self.mem.items().len - 1]);
            // Every tool's execute() allocates its result via the
            // passed-in gpa (checked at each call site); the sole
            // exception is tool.invoke's own innermost OOM fallback
            // literal, which would already be a lost cause before reaching
            // here.
            if (text_owner == .gpa) self.gpa.free(text);

            assert(self.mem.items().len == mem_count_before + 1);
            assert(view.items.len == view_count_before + 1);
        }

        /// Frees the gpa-owned string data a `Provider.chat` reply carries
        /// (content + each tool call's fields), once `Memory.append` has
        /// taken its own independent copy and any tool-dispatch loop that
        /// reads `reply.tool_calls` has finished. Does not touch
        /// `tool_call_id`/`name` — providers never populate those with
        /// allocated memory on a reply.
        fn freeReply(gpa: std.mem.Allocator, msg: Message) void {
            if (msg.content.len > 0) gpa.free(msg.content);
            for (msg.tool_calls) |tc| {
                if (tc.id.len > 0) gpa.free(tc.id);
                if (tc.name.len > 0) gpa.free(tc.name);
                if (tc.arguments_json.len > 0) gpa.free(tc.arguments_json);
            }
            if (msg.tool_calls.len > 0) gpa.free(msg.tool_calls);
        }

        /// "Graceful Escalation & Context Pruning" (design doc §3.3): stops
        /// talking to the LLM, prunes the failed turn from memory down to a
        /// single system note, and returns a diagnostic report for the UI.
        /// `onEscalate` hooks may replace the report (scratch-owned); the
        /// final value is normalized back to a fresh gpa allocation because
        /// callers unconditionally `gpa.free` the escalated report.
        fn escalate(
            self: *Self,
            turn_start: usize,
            failure: @TypeOf(@as(tool.InvokeResult, undefined).invalid_args),
            ctx: hook.Ctx,
        ) !Outcome {
            assert(turn_start <= self.mem.items().len);

            const final_report = blk: {
                const original_report = try std.fmt.allocPrint(
                    self.gpa,
                    "Tool \"{s}\" failed after {d} retries and was escalated.\nLast raw arguments: {s}\nDiagnostic: {s}",
                    .{ failure.tool_name, max_retries, failure.raw_args_json, failure.diagnostic },
                );
                // Scoped to this block: covers a failing hook or dupe, and
                // expires before the block breaks so the paths below can't
                // double-free.
                errdefer self.gpa.free(original_report);

                var report: []const u8 = original_report;
                _ = &report;
                inline for (Hooks) |H| {
                    if (@hasDecl(H, "onEscalate")) {
                        try H.onEscalate(
                            ctx,
                            failure.tool_name,
                            failure.diagnostic,
                            failure.raw_args_json,
                            &report,
                        );
                    }
                }
                // Same-ptr-same-len means no hook touched it; anything
                // else (including a subslice of the original) gets duped
                // first so the exact original allocation can be freed.
                const report_untouched =
                    report.ptr == original_report.ptr and
                    report.len == original_report.len;
                if (report_untouched) break :blk original_report;
                const owned = try self.gpa.dupe(u8, report);
                self.gpa.free(original_report);
                break :blk owned;
            };
            errdefer self.gpa.free(final_report);

            var kept: std.ArrayList(Message) = .empty;
            defer kept.deinit(self.gpa);
            try kept.appendSlice(self.gpa, self.mem.items()[0..turn_start]);
            try kept.append(self.gpa, Message.system(
                "User was notified that the tool failed due to syntax errors.",
            ));
            try self.mem.prune(kept.items);
            assert(self.mem.items().len == turn_start + 1);

            return .{ .escalated = final_report };
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

    var eng = Engine(TestTools, llm.Mock, .{}).init(testing.allocator, io, &mock, &mem);
    const outcome = try eng.step("what is 2 + 3?", null);

    try testing.expect(outcome == .final);
    try testing.expectEqualStrings("The answer is 5.", outcome.final);
    try testing.expectEqual(@as(usize, 4), mem.items().len);
}

test "step: tool-call marker is one line — dot, name, action, then a done-signal, no result preview" {
    var mock: llm.Mock = .{ .script = &.{
        .{ .role = .assistant, .tool_calls = &.{
            .{ .id = "call_1", .name = "calculator", .arguments_json = "{\"op\":\"add\",\"a\":2,\"b\":3}" },
        } },
        .{ .role = .assistant, .content = "The answer is 5." },
    } };

    const path = "/tmp/mymew_test_marker.jsonl";
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    std.Io.Dir.cwd().deleteFile(io, path) catch {};

    var mem = try memory.Memory.init(testing.allocator, io, path);
    defer mem.deinit();

    var eng = Engine(TestTools, llm.Mock, .{}).init(testing.allocator, io, &mock, &mem);

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();

    const outcome = try eng.step("what is 2 + 3?", &out.writer);
    try testing.expect(outcome == .final);

    const bytes = out.writer.buffer[0..out.writer.end];
    // The whole marker — pending dot, name, action, closing bracket, then
    // the (invisible) success done-signal — appears as one contiguous run:
    // nothing about the line's text gets re-emitted after dispatch resolves.
    try testing.expect(std.mem.indexOf(
        u8,
        bytes,
        "[" ++ tool_dot_pending ++ " calculator: add 2 and 3]" ++ tool_done_ok_sgr,
    ) != null);
    // No trace of the old two-line "[-> tool]" / "[<- result]" format.
    try testing.expect(std.mem.indexOf(u8, bytes, "[->") == null);
    try testing.expect(std.mem.indexOf(u8, bytes, "[<-") == null);
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

    var eng = Engine(TestTools, llm.Mock, .{}).init(testing.allocator, io, &mock, &mem);
    const outcome = try eng.step("compute something that will keep failing", null);
    defer testing.allocator.free(outcome.escalated);

    try testing.expect(outcome == .escalated);
    try testing.expectEqual(@as(usize, 2), mem.items().len);
    try testing.expectEqual(message.Role.user, mem.items()[0].role);
    try testing.expectEqual(message.Role.system, mem.items()[1].role);
}

test "step: requestCancel stops the turn at the next loop boundary and records a note" {
    // A provider wrapper that requests cancellation right after its first
    // reply — simulating the user pressing Esc while the tool then runs.
    const CancellingProvider = struct {
        inner: llm.Mock,
        flag: ?*std.atomic.Value(bool) = null,
        pub fn chat(
            self: *@This(),
            gpa: std.mem.Allocator,
            io: Io,
            messages: []const Message,
            tools: []const tool.Descriptor,
            token_writer: ?*Io.Writer,
        ) anyerror!Message {
            const reply = try self.inner.chat(gpa, io, messages, tools, token_writer);
            if (self.flag) |f| f.store(true, .release);
            return reply;
        }
    };

    var prov: CancellingProvider = .{ .inner = .{ .script = &.{
        .{ .role = .assistant, .tool_calls = &.{
            .{ .id = "call_1", .name = "calculator", .arguments_json = "{\"op\":\"add\",\"a\":2,\"b\":3}" },
        } },
        // Never reached: the loop must bail before this provider call.
        .{ .role = .assistant, .content = "should not appear" },
    } } };

    const path = "/tmp/mymew_test_cancel.jsonl";
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    std.Io.Dir.cwd().deleteFile(io, path) catch {};

    var mem = try memory.Memory.init(testing.allocator, io, path);
    defer mem.deinit();

    var eng = Engine(TestTools, CancellingProvider, .{}).init(testing.allocator, io, &prov, &mem);
    prov.flag = &eng.cancel_requested;

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();

    const outcome = try eng.step("what is 2 + 3?", &out.writer);
    try testing.expect(outcome == .cancelled);

    // The partial work stays (no pruning): user, assistant tool-call, tool
    // result — then the cancellation note.
    try testing.expectEqual(@as(usize, 4), mem.items().len);
    try testing.expectEqual(message.Role.system, mem.items()[3].role);
    try testing.expectEqualStrings("Turn cancelled by the user before completion.", mem.items()[3].content);
    // The stream saw the marker, and the second scripted reply never ran.
    const bytes = out.writer.buffer[0..out.writer.end];
    try testing.expect(std.mem.indexOf(u8, bytes, "[cancelled]") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "should not appear") == null);
}

test "hooks: preTool veto skips dispatch and feeds the veto back as the tool result" {
    const VetoHook = struct {
        pub fn name() []const u8 {
            return "veto_hook";
        }
        pub fn preTool(ctx: hook.Ctx, tool_name: []const u8, args_json: *[]const u8) anyerror!hook.PreToolAction {
            _ = tool_name;
            _ = args_json;
            return .{ .veto = try ctx.scratch.dupe(u8, "vetoed: policy says no") };
        }
    };

    var mock: llm.Mock = .{ .script = &.{
        .{ .role = .assistant, .tool_calls = &.{
            .{ .id = "call_1", .name = "calculator", .arguments_json = "{\"op\":\"add\",\"a\":2,\"b\":3}" },
        } },
        .{ .role = .assistant, .content = "Understood, not computing that." },
    } };

    const path = "/tmp/mymew_test_hook_veto.jsonl";
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    std.Io.Dir.cwd().deleteFile(io, path) catch {};

    var mem = try memory.Memory.init(testing.allocator, io, path);
    defer mem.deinit();

    var eng = Engine(TestTools, llm.Mock, .{VetoHook}).init(testing.allocator, io, &mock, &mem);
    const outcome = try eng.step("what is 2 + 3?", null);

    try testing.expect(outcome == .final);
    // A veto is not a self-healing failure: the turn completed normally
    // with the veto text standing in as the tool result.
    try testing.expectEqual(@as(usize, 4), mem.items().len);
    try testing.expectEqual(message.Role.tool, mem.items()[2].role);
    try testing.expectEqualStrings("vetoed: policy says no", mem.items()[2].content);
}

test "hooks: preTool arg mutation dispatches the rewritten arguments" {
    const RewriteHook = struct {
        pub fn name() []const u8 {
            return "rewrite_hook";
        }
        pub fn preTool(ctx: hook.Ctx, tool_name: []const u8, args_json: *[]const u8) anyerror!hook.PreToolAction {
            _ = tool_name;
            args_json.* = try ctx.scratch.dupe(u8, "{\"op\":\"add\",\"a\":40,\"b\":2}");
            return .proceed;
        }
    };

    var mock: llm.Mock = .{ .script = &.{
        .{ .role = .assistant, .tool_calls = &.{
            .{ .id = "call_1", .name = "calculator", .arguments_json = "{\"op\":\"add\",\"a\":2,\"b\":3}" },
        } },
        .{ .role = .assistant, .content = "done" },
    } };

    const path = "/tmp/mymew_test_hook_rewrite.jsonl";
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    std.Io.Dir.cwd().deleteFile(io, path) catch {};

    var mem = try memory.Memory.init(testing.allocator, io, path);
    defer mem.deinit();

    var eng = Engine(TestTools, llm.Mock, .{RewriteHook}).init(testing.allocator, io, &mock, &mem);
    const outcome = try eng.step("what is 2 + 3?", null);

    try testing.expect(outcome == .final);
    // 40 + 2, not the LLM's original 2 + 3: the hook's args were dispatched.
    try testing.expectEqualStrings("42", mem.items()[2].content);
    // Documented limitation: the persisted assistant message still carries
    // the ORIGINAL args the LLM wrote, not the hook's rewrite.
    try testing.expectEqualStrings(
        "{\"op\":\"add\",\"a\":2,\"b\":3}",
        mem.items()[1].tool_calls[0].arguments_json,
    );
}

test "hooks: postTool replaces the persisted tool result without leaking the original" {
    const RedactHook = struct {
        pub fn name() []const u8 {
            return "redact_hook";
        }
        pub fn postTool(ctx: hook.Ctx, tool_name: []const u8, result: *[]const u8) anyerror!void {
            _ = tool_name;
            result.* = try ctx.scratch.dupe(u8, "[redacted]");
        }
    };

    var mock: llm.Mock = .{ .script = &.{
        .{ .role = .assistant, .tool_calls = &.{
            .{ .id = "call_1", .name = "calculator", .arguments_json = "{\"op\":\"add\",\"a\":2,\"b\":3}" },
        } },
        .{ .role = .assistant, .content = "done" },
    } };

    const path = "/tmp/mymew_test_hook_redact.jsonl";
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    std.Io.Dir.cwd().deleteFile(io, path) catch {};

    var mem = try memory.Memory.init(testing.allocator, io, path);
    defer mem.deinit();

    // testing.allocator fails the test if the swapped-out original gpa
    // result ("5") leaks — that's the ownership invariant under test.
    var eng = Engine(TestTools, llm.Mock, .{RedactHook}).init(testing.allocator, io, &mock, &mem);
    const outcome = try eng.step("what is 2 + 3?", null);

    try testing.expect(outcome == .final);
    try testing.expectEqualStrings("[redacted]", mem.items()[2].content);
}

test "hooks: postLlm content override changes what is persisted and returned" {
    const OverrideHook = struct {
        pub fn name() []const u8 {
            return "override_hook";
        }
        pub fn postLlm(ctx: hook.Ctx, reply: *const Message, content_override: *?[]const u8) anyerror!void {
            _ = reply;
            content_override.* = try ctx.scratch.dupe(u8, "overridden answer");
        }
    };

    var mock: llm.Mock = .{ .script = &.{
        .{ .role = .assistant, .content = "original answer" },
    } };

    const path = "/tmp/mymew_test_hook_override.jsonl";
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    std.Io.Dir.cwd().deleteFile(io, path) catch {};

    var mem = try memory.Memory.init(testing.allocator, io, path);
    defer mem.deinit();

    var eng = Engine(TestTools, llm.Mock, .{OverrideHook}).init(testing.allocator, io, &mock, &mem);
    const outcome = try eng.step("say something", null);

    try testing.expect(outcome == .final);
    try testing.expectEqualStrings("overridden answer", outcome.final);
    try testing.expectEqualStrings("overridden answer", mem.items()[1].content);
}

test "hooks: preLlm can inject a message into the outbound view without touching memory" {
    const InjectHook = struct {
        pub fn name() []const u8 {
            return "inject_hook";
        }
        pub fn preLlm(ctx: hook.Ctx, messages: *std.ArrayList(Message)) anyerror!void {
            try messages.append(ctx.scratch, Message.system("INJECTED"));
        }
    };

    var counts: std.ArrayList(usize) = .empty;
    defer counts.deinit(testing.allocator);
    var mock: llm.Mock = .{ .call_message_counts = &counts, .script = &.{
        .{ .role = .assistant, .content = "ok" },
    } };

    const path = "/tmp/mymew_test_hook_inject.jsonl";
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    std.Io.Dir.cwd().deleteFile(io, path) catch {};

    var mem = try memory.Memory.init(testing.allocator, io, path);
    defer mem.deinit();

    var eng = Engine(TestTools, llm.Mock, .{InjectHook}).init(testing.allocator, io, &mock, &mem);
    const outcome = try eng.step("hello", null);

    try testing.expect(outcome == .final);
    // The provider saw user + injected system message...
    try testing.expectEqualSlices(usize, &.{2}, counts.items);
    // ...but the injection was never persisted: user + assistant only.
    try testing.expectEqual(@as(usize, 2), mem.items().len);
    try testing.expectEqual(message.Role.user, mem.items()[0].role);
    try testing.expectEqual(message.Role.assistant, mem.items()[1].role);
}

test "hooks: tool_audit_log writes framed audit lines without breaking the one-line marker" {
    const tool_audit_log = @import("../plugins/hooks/tool_audit_log.zig");

    var mock: llm.Mock = .{ .script = &.{
        .{ .role = .assistant, .tool_calls = &.{
            .{ .id = "call_1", .name = "calculator", .arguments_json = "{\"op\":\"add\",\"a\":2,\"b\":3}" },
        } },
        .{ .role = .assistant, .content = "The answer is 5." },
    } };

    const path = "/tmp/mymew_test_hook_audit.jsonl";
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    std.Io.Dir.cwd().deleteFile(io, path) catch {};

    var mem = try memory.Memory.init(testing.allocator, io, path);
    defer mem.deinit();

    var eng = Engine(TestTools, llm.Mock, .{tool_audit_log}).init(testing.allocator, io, &mock, &mem);

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();

    const outcome = try eng.step("what is 2 + 3?", &out.writer);
    try testing.expect(outcome == .final);

    const bytes = out.writer.buffer[0..out.writer.end];
    // preTool audit line lands on its own line BEFORE the marker; the
    // marker's leading "\n" terminates it.
    const audit_pre = std.mem.indexOf(u8, bytes, "\n[hook] calling calculator with {\"op\":\"add\",\"a\":2,\"b\":3}").?;
    // The §3.6 invariant is untouched: pending dot, name, action, and the
    // invisible done-signal are still one contiguous run.
    const marker = std.mem.indexOf(
        u8,
        bytes,
        "[" ++ tool_dot_pending ++ " calculator: add 2 and 3]" ++ tool_done_ok_sgr ++ "\n",
    ).?;
    // postTool audit line comes after the terminated marker line.
    const audit_post = std.mem.indexOf(u8, bytes, "[hook] calculator returned 1 bytes: 5\n").?;
    try testing.expect(audit_pre < marker);
    try testing.expect(marker < audit_post);
}

test "hooks: onTurnStart rewrites the user text before it reaches memory" {
    const GreetHook = struct {
        pub fn name() []const u8 {
            return "greet_hook";
        }
        pub fn onTurnStart(ctx: hook.Ctx, user_text: *?[]const u8) anyerror!void {
            user_text.* = try ctx.scratch.dupe(u8, "replaced text");
        }
    };

    var mock: llm.Mock = .{ .script = &.{
        .{ .role = .assistant, .content = "ok" },
    } };

    const path = "/tmp/mymew_test_hook_turnstart.jsonl";
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    std.Io.Dir.cwd().deleteFile(io, path) catch {};

    var mem = try memory.Memory.init(testing.allocator, io, path);
    defer mem.deinit();

    var eng = Engine(TestTools, llm.Mock, .{GreetHook}).init(testing.allocator, io, &mock, &mem);
    const outcome = try eng.step("original text", null);

    try testing.expect(outcome == .final);
    try testing.expectEqualStrings("replaced text", mem.items()[0].content);
}

test "hooks: onTurnEnd observes the outcome and onEscalate can replace the report" {
    const ObserverHook = struct {
        var saw_escalated: bool = false;
        pub fn name() []const u8 {
            return "observer_hook";
        }
        pub fn onEscalate(ctx: hook.Ctx, tool_name: []const u8, diagnostic: []const u8, raw_args_json: []const u8, report: *[]const u8) anyerror!void {
            _ = tool_name;
            _ = diagnostic;
            _ = raw_args_json;
            report.* = try ctx.scratch.dupe(u8, "hook-rewritten escalation report");
        }
        pub fn onTurnEnd(ctx: hook.Ctx, outcome: *const Outcome) anyerror!void {
            _ = ctx;
            if (outcome.* == .escalated) saw_escalated = true;
        }
    };

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

    const path = "/tmp/mymew_test_hook_escalate.jsonl";
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    std.Io.Dir.cwd().deleteFile(io, path) catch {};

    var mem = try memory.Memory.init(testing.allocator, io, path);
    defer mem.deinit();

    var eng = Engine(TestTools, llm.Mock, .{ObserverHook}).init(testing.allocator, io, &mock, &mem);
    const outcome = try eng.step("keep failing", null);
    // Freeing with testing.allocator proves the engine normalized the
    // hook's scratch-owned replacement back to a fresh gpa allocation.
    defer testing.allocator.free(outcome.escalated);

    try testing.expect(outcome == .escalated);
    try testing.expectEqualStrings("hook-rewritten escalation report", outcome.escalated);
    try testing.expect(ObserverHook.saw_escalated);
}

