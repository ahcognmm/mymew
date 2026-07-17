const std = @import("std");
const posix = std.posix;
const Io = std.Io;
const engine = @import("engine.zig");
const memory = @import("memory.zig");
const io_bus = @import("io_bus.zig");

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
        /// to signal shutdown before the process exits.
        pub fn spawn(self: *Self) !void {
            const thread = try std.Thread.spawn(.{}, run, .{self});
            thread.detach();
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
                    // gpa-owned and ours to free (see `Engine.Outcome`).
                    if (outcome == .escalated) self.gpa.free(outcome.escalated);
                } else |err| {
                    const msg = std.fmt.allocPrint(self.gpa, "\r\n[error: {s}]\r\n", .{@errorName(err)}) catch "";
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
