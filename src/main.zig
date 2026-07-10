const std = @import("std");
const posix = std.posix;

pub const std_options: std.Options = .{
    .log_level = .warn,
};

const engine = @import("core/engine.zig");
const llm = @import("core/llm.zig");
const memory = @import("core/memory.zig");
const calculator = @import("plugins/tools/calculator.zig");
const word_count = @import("plugins/tools/word_count.zig");
const read_file = @import("plugins/tools/read_file.zig");
const write_file = @import("plugins/tools/write_file.zig");
const list_files = @import("plugins/tools/list_files.zig");
const execute_command = @import("plugins/tools/execute_command.zig");
const tui_mod = @import("tui.zig");

const Tools = .{ calculator, word_count, read_file, write_file, list_files, execute_command };

// ─── agent thread ─────────────────────────────────────────────────────────────

const AgentContext = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    eng: *engine.Engine(Tools, llm.Glm),
    state: *tui_mod.AgentState,
    channel: *tui_mod.Channel,
    wakeup_write: posix.fd_t,
};

fn agentThread(ctx: AgentContext) void {
    const io = ctx.io;
    var cw_buf: [0]u8 = undefined;
    var cw = tui_mod.ChannelWriter.init(io, ctx.channel, ctx.wakeup_write, &cw_buf);
    const token_writer = &cw.writer;

    while (true) {
        // Wait for work
        ctx.state.mutex.lockUncancelable(io);
        while (ctx.state.pending_text == null and !ctx.state.should_exit) {
            ctx.state.cond.waitUncancelable(io, &ctx.state.mutex);
        }
        if (ctx.state.should_exit) {
            ctx.state.mutex.unlock(io);
            return;
        }
        const text: []const u8 = ctx.state.pending_text.?;
        ctx.state.pending_text = null;
        ctx.state.mutex.unlock(io);

        ctx.state.thinking.store(true, .release);
        ctx.state.agent_finished.store(false, .release);

        // Send a wakeup so TUI picks up thinking=true immediately
        _ = std.c.write(ctx.wakeup_write, &[_]u8{1}, 1);

        _ = ctx.eng.step(text, token_writer) catch |err| {
            const msg = std.fmt.allocPrint(ctx.gpa, "\r\n[error: {s}]\r\n", .{@errorName(err)}) catch "";
            ctx.channel.push(io, msg) catch {};
            ctx.gpa.free(msg);
        };

        if (text.len > 0) ctx.gpa.free(text);
        ctx.state.thinking.store(false, .release);
        ctx.state.agent_finished.store(true, .release);
        _ = std.c.write(ctx.wakeup_write, &[_]u8{1}, 1);
    }
}

// ─── main ─────────────────────────────────────────────────────────────────────

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var glm = llm.Glm.fromEnv(init.environ_map) catch {
        const stdout = std.Io.File.stdout();
        var buf: [256]u8 = undefined;
        var w = stdout.writerStreaming(io, &buf);
        try w.interface.writeAll(
            "Set GLM_API_KEY (or ZAI_API_KEY) to your z.ai / Zhipu GLM API key.\n" ++
                "Optional: GLM_MODEL, GLM_BASE_URL, MYMEW_MEMORY_PATH.\n",
        );
        try w.interface.flush();
        return;
    };

    const memory_path = init.environ_map.get("MYMEW_MEMORY_PATH") orelse "mymew_memory.jsonl";
    var mem = try memory.Memory.init(gpa, io, memory_path);
    defer mem.deinit();

    var eng = engine.Engine(Tools, llm.Glm).init(gpa, io, &glm, &mem);

    // Self-pipe for waking up the poll() in the render loop
    var pipe_fds: [2]posix.fd_t = undefined;
    if (std.c.pipe(&pipe_fds) != 0) return error.PipeFailed;
    defer _ = std.c.close(pipe_fds[0]);
    defer _ = std.c.close(pipe_fds[1]);

    var channel = tui_mod.Channel.init(gpa);
    defer channel.deinit();

    var agent_state = tui_mod.AgentState{};

    const stdin_fd: posix.fd_t = 0;
    const stdout_fd: posix.fd_t = 1;

    // Raw mode
    const orig_termios = try tui_mod.enableRawMode(stdin_fd);
    defer tui_mod.disableRawMode(stdin_fd, orig_termios);

    var ui = try tui_mod.Tui.init(gpa, stdout_fd);
    defer ui.deinit();

    ui.enter();
    defer ui.leave();

    // Start agent thread
    const agent_ctx = AgentContext{
        .gpa = gpa,
        .io = io,
        .eng = &eng,
        .state = &agent_state,
        .channel = &channel,
        .wakeup_write = pipe_fds[1],
    };
    const agent = try std.Thread.spawn(.{}, agentThread, .{agent_ctx});
    agent.detach();

    // Poll fds: stdin (0) + wakeup pipe read end
    var poll_fds = [_]posix.pollfd{
        .{ .fd = stdin_fd, .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = pipe_fds[0], .events = posix.POLL.IN, .revents = 0 },
    };

    var drain_buf: std.ArrayList(u8) = .empty;
    defer drain_buf.deinit(gpa);

    var running = true;
    while (running) {
        _ = posix.poll(&poll_fds, 400) catch 0; // 400ms for dot animation

        // Drain wakeup pipe
        if (poll_fds[1].revents & posix.POLL.IN != 0) {
            var discard: [64]u8 = undefined;
            _ = std.c.read(pipe_fds[0], &discard, discard.len);
        }

        // Check if agent finished
        if (agent_state.agent_finished.load(.acquire)) {
            agent_state.agent_finished.store(false, .monotonic);
            // Drain any remaining channel bytes first
            drain_buf.clearRetainingCapacity();
            _ = channel.drain(io, &drain_buf, gpa) catch {};
            if (drain_buf.items.len > 0) ui.appendOutput(drain_buf.items);
            ui.onAgentDone();
        } else {
            // Drain pending tokens from channel
            drain_buf.clearRetainingCapacity();
            _ = channel.drain(io, &drain_buf, gpa) catch {};
            if (drain_buf.items.len > 0) {
                const thinking = agent_state.thinking.load(.acquire);
                ui.appendOutput(drain_buf.items);
                if (thinking) ui.onAgentStart(true);
            }
        }

        // Animate dots while thinking
        const thinking = agent_state.thinking.load(.acquire);
        _ = ui.tickDots(thinking);

        // Handle keypress
        if (poll_fds[0].revents & posix.POLL.IN != 0) {
            var key_buf: [1]u8 = undefined;
            const n = std.c.read(stdin_fd, &key_buf, 1);
            if (n <= 0) break;
            const key = key_buf[0];

            if (key == 3 or key == 4) { // Ctrl+C or Ctrl+D
                running = false;
                break;
            }

            const submitted = ui.handleKey(key);
            if (submitted) {
                const text = ui.takeInput();
                if (text.len > 0) {
                    ui.onAgentStart(false);
                    agent_state.mutex.lockUncancelable(io);
                    agent_state.pending_text = text;
                    agent_state.mutex.unlock(io);
                    agent_state.cond.signal(io);
                }
            }
        }
    }

    // Signal agent thread to exit
    agent_state.mutex.lockUncancelable(io);
    agent_state.should_exit = true;
    agent_state.mutex.unlock(io);
    agent_state.cond.signal(io);
}
