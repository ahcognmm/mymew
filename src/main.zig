const std = @import("std");
const posix = std.posix;

pub const std_options: std.Options = .{
    .log_level = .warn,
};

const agent_mod = @import("core/agent.zig");
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
const Agent = agent_mod.Agent(Tools, llm.Glm);

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

    // Self-pipe for waking up the poll() in the render loop
    var pipe_fds: [2]posix.fd_t = undefined;
    if (std.c.pipe(&pipe_fds) != 0) return error.PipeFailed;
    defer _ = std.c.close(pipe_fds[0]);
    defer _ = std.c.close(pipe_fds[1]);

    var agent = Agent.init(gpa, io, &glm, &mem, pipe_fds[1]);
    defer agent.deinit();

    const stdin_fd: posix.fd_t = 0;
    const stdout_fd: posix.fd_t = 1;

    // Raw mode
    const orig_termios = try tui_mod.enableRawMode(stdin_fd);
    defer tui_mod.disableRawMode(stdin_fd, orig_termios);

    var ui = try tui_mod.Tui.init(gpa, stdout_fd);
    defer ui.deinit();

    ui.enter();
    defer ui.leave();

    tui_mod.installResizeHandler();

    try agent.spawn();

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

        if (tui_mod.takeResized()) {
            ui.handleResize(agent.state.thinking.load(.acquire));
        }

        // Check if agent finished
        if (agent.state.agent_finished.load(.acquire)) {
            agent.state.agent_finished.store(false, .monotonic);
            // Drain any remaining channel bytes first
            drain_buf.clearRetainingCapacity();
            _ = agent.channel.drain(io, &drain_buf, gpa) catch {};
            if (drain_buf.items.len > 0) ui.appendOutput(drain_buf.items);
            ui.onAgentDone();
        } else {
            // Drain pending tokens from channel
            drain_buf.clearRetainingCapacity();
            _ = agent.channel.drain(io, &drain_buf, gpa) catch {};
            if (drain_buf.items.len > 0) {
                const thinking = agent.state.thinking.load(.acquire);
                ui.appendOutput(drain_buf.items);
                if (thinking) ui.onAgentStart(true);
            }
        }

        // Animate dots while thinking
        const thinking = agent.state.thinking.load(.acquire);
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

            if (key == 27) {
                tui_mod.swallowEscapeSequence(stdin_fd);
            } else {
                const submitted = ui.handleKey(key);
                if (submitted) {
                    const text = ui.takeInput();
                    if (text.len > 0) {
                        ui.onAgentStart(false);
                        agent.submit(text);
                    }
                }
            }
        }
    }

    agent.requestStop();
}
