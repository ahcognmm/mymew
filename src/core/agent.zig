const std = @import("std");
const posix = std.posix;
const Io = std.Io;
const engine = @import("engine.zig");
const memory = @import("memory.zig");
const io_bus = @import("io_bus.zig");

/// SGR markers bracketing an error/diagnostic span in the token stream —
/// escalation reports and turn-level errors. Dim red is both a sane visible
/// fallback for a plain consumer of the stream AND the sequence
/// `tui/app.zig` recognizes to draw its red error gutter (same convention
/// as `llm.zig`'s `\x1b[2;3;36m` thinking markers; the literals are duplicated
/// there, never imported, to keep `app.zig` free of `core/*`).
const error_start_sgr = "\x1b[2;31m";
const error_end_sgr = "\x1b[0m";

/// Owns the ReAct `Engine` plus the background-thread lifecycle that runs it
/// (design doc §5.2, "Background Thread: Runs the ReAct Orchestrator").
///
/// The render thread talks to this through `state`/`channel`: it calls
/// `submit()` to hand off a prompt and drains `channel` for streamed tokens.
///
/// `Hooks` is forwarded to the inner `Engine` untouched (never hardcoded
/// to `.{}` here) so the TUI path can register interceptor hooks — see
/// `core/hook.zig` and design doc §3.7.
pub fn Agent(comptime Tools: anytype, comptime Provider: type, comptime Hooks: anytype) type {
    return struct {
        const Self = @This();
        pub const EngineT = engine.Engine(Tools, Provider, Hooks);

        gpa: std.mem.Allocator,
        io: Io,
        eng: EngineT,

        state: io_bus.AgentState = .{},
        channel: io_bus.Channel,
        wakeup_write: posix.fd_t,

        pub fn init(
            gpa: std.mem.Allocator,
            io: Io,
            provider: *Provider,
            mem: *memory.Memory,
            wakeup_write: posix.fd_t,
        ) Self {
            return .{
                .gpa = gpa,
                .io = io,
                .eng = EngineT.init(gpa, io, provider, mem),
                .channel = io_bus.Channel.init(gpa),
                .wakeup_write = wakeup_write,
            };
        }

        pub fn deinit(self: *Self) void {
            self.channel.deinit();
        }

        /// Spawns the background loop and detaches it; call `requestStop()`
        /// to signal shutdown before the process exits. Also registers this
        /// agent as the engine's human-in-the-loop approver (design doc
        /// §3.9) — `self` must be at its final address by now, which spawn
        /// (unlike init) can rely on.
        pub fn spawn(self: *Self) !void {
            self.eng.setApprover(.{ .ptr = self, .requestFn = approverRequest });
            const thread = try std.Thread.spawn(.{}, run, .{self});
            thread.detach();
        }

        /// Blocking approval request, called on the orchestrator thread via
        /// the `hook.Approver` bridge: parks the question in `state`, pings
        /// the wakeup fd so the render loop notices immediately, then waits
        /// until the frontend answers or the turn is cancelled (§3.4 —
        /// cancel counts as a deny, so the engine can reach its next cancel
        /// checkpoint instead of dangling here forever).
        fn requestApproval(self: *Self, question: []const u8) bool {
            const io = self.io;
            self.state.mutex.lockUncancelable(io);
            self.state.approval_question = question;
            self.state.approval_answer = null;
            self.state.mutex.unlock(io);
            self.state.approval_pending.store(true, .release);
            _ = std.c.write(self.wakeup_write, &[_]u8{1}, 1);

            self.state.mutex.lockUncancelable(io);
            while (self.state.approval_answer == null and
                !self.eng.cancel_requested.load(.acquire))
            {
                self.state.cond.waitUncancelable(io, &self.state.mutex);
            }
            const answer = self.state.approval_answer orelse false;
            self.state.approval_question = null;
            self.state.approval_answer = null;
            self.state.mutex.unlock(io);
            self.state.approval_pending.store(false, .release);
            _ = std.c.write(self.wakeup_write, &[_]u8{1}, 1);
            return answer;
        }

        fn approverRequest(ptr: *anyopaque, question: []const u8) bool {
            const self: *Self = @ptrCast(@alignCast(ptr));
            return self.requestApproval(question);
        }

        /// Frontend poll: true while the orchestrator thread is blocked in
        /// `requestApproval` waiting for a yes/no.
        pub fn approvalPending(self: *Self) bool {
            return self.state.approval_pending.load(.acquire);
        }

        /// Frontend: gpa-owned copy of the pending question (caller frees),
        /// or null if the request already resolved between the poll and
        /// this call.
        pub fn copyApprovalQuestion(self: *Self, gpa: std.mem.Allocator) ?[]u8 {
            self.state.mutex.lockUncancelable(self.io);
            defer self.state.mutex.unlock(self.io);
            const q = self.state.approval_question orelse return null;
            return gpa.dupe(u8, q) catch null;
        }

        /// Frontend: answers the pending approval (no-op if none) and wakes
        /// the blocked orchestrator thread.
        pub fn answerApproval(self: *Self, approved: bool) void {
            self.state.mutex.lockUncancelable(self.io);
            if (self.state.approval_question != null) self.state.approval_answer = approved;
            self.state.mutex.unlock(self.io);
            self.state.cond.signal(self.io);
        }

        /// Hands a user prompt to the background loop. `text` must be an
        /// allocator-owned slice; the agent frees it once processed.
        pub fn submit(self: *Self, text: []const u8) void {
            self.state.mutex.lockUncancelable(self.io);
            self.state.pending_text = text;
            self.state.mutex.unlock(self.io);
            self.state.cond.signal(self.io);
        }

        pub fn requestStop(self: *Self) void {
            self.state.mutex.lockUncancelable(self.io);
            self.state.should_exit = true;
            self.state.mutex.unlock(self.io);
            self.state.cond.signal(self.io);
        }

        /// Asks the currently running turn (if any) to stop at its next
        /// loop boundary (design doc §3.4). Thread-safe — meant to be
        /// called directly from the render thread, same convention as
        /// `eng.setStyle`. Also wakes a `requestApproval` wait, which
        /// treats the cancel as a deny (§3.9).
        pub fn requestCancel(self: *Self) void {
            self.eng.requestCancel();
            self.state.cond.signal(self.io);
        }

        fn run(self: *Self) void {
            const io = self.io;
            var cw_buf: [0]u8 = undefined;
            var cw = io_bus.ChannelWriter.init(io, &self.channel, self.wakeup_write, &cw_buf);
            const token_writer = &cw.writer;

            while (true) {
                // Wait for work
                self.state.mutex.lockUncancelable(io);
                while (self.state.pending_text == null and !self.state.should_exit) {
                    self.state.cond.waitUncancelable(io, &self.state.mutex);
                }
                if (self.state.should_exit) {
                    self.state.mutex.unlock(io);
                    return;
                }
                const text: []const u8 = self.state.pending_text.?;
                self.state.pending_text = null;
                self.state.mutex.unlock(io);

                self.state.thinking.store(true, .release);
                self.state.agent_finished.store(false, .release);

                // Send a wakeup so the render loop picks up thinking=true immediately
                _ = std.c.write(self.wakeup_write, &[_]u8{1}, 1);

                if (self.eng.step(text, token_writer)) |outcome| {
                    // `.final` was already streamed via `token_writer` as it
                    // was generated; `.escalated`'s report string is
                    // gpa-owned and ours to free (see `Engine.Outcome`) —
                    // but first it gets streamed to the UI inside an error
                    // span (§3.3, "Transparent Escalation": the report must
                    // reach the user, not just the return value).
                    if (outcome == .escalated) {
                        const msg = std.fmt.allocPrint(
                            self.gpa,
                            "\n" ++ error_start_sgr ++ "{s}" ++ error_end_sgr ++ "\n",
                            .{outcome.escalated},
                        ) catch "";
                        if (msg.len > 0) {
                            self.channel.push(io, msg) catch {};
                            self.gpa.free(msg);
                        }
                        self.gpa.free(outcome.escalated);
                    }
                } else |err| {
                    const msg = std.fmt.allocPrint(
                        self.gpa,
                        "\n" ++ error_start_sgr ++ "[error: {s}]" ++ error_end_sgr ++ "\n",
                        .{@errorName(err)},
                    ) catch "";
                    self.channel.push(io, msg) catch {};
                    self.gpa.free(msg);
                }

                if (text.len > 0) self.gpa.free(text);
                self.state.thinking.store(false, .release);
                self.state.agent_finished.store(true, .release);
                _ = std.c.write(self.wakeup_write, &[_]u8{1}, 1);
            }
        }
    };
}
