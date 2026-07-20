const std = @import("std");
const posix = std.posix;

pub const std_options: std.Options = .{
    .log_level = .warn,
};

/// Root panic handler: restore the terminal (leave alt screen, re-enable
/// the cursor, undo raw mode) BEFORE the default handler prints the trace.
/// Zig panics don't run `defer`s, so without this a panic would exit with
/// raw mode + alt screen still active — terminal unusable, trace invisible.
/// `emergencyRestore` is a no-op unless `runInteractive` registered state.
pub const panic = std.debug.FullPanic(panicImpl);

fn panicImpl(msg: []const u8, first_trace_addr: ?usize) noreturn {
    tui_mod.emergencyRestore();
    std.debug.defaultPanic(msg, first_trace_addr);
}

const agent_mod = @import("core/agent.zig");
const engine = @import("core/engine.zig");
const llm = @import("core/llm.zig");
const memory = @import("core/memory.zig");
const calculator = @import("plugins/tools/calculator.zig");
const word_count = @import("plugins/tools/word_count.zig");
const read_file = @import("plugins/tools/read_file.zig");
const write_file = @import("plugins/tools/write_file.zig");
const list_files = @import("plugins/tools/list_files.zig");
const execute_command = @import("plugins/tools/execute_command.zig");
const todo_write = @import("plugins/tools/todo_write.zig");
const tool_audit_log = @import("plugins/hooks/tool_audit_log.zig");
const todo_tracker = @import("plugins/hooks/todo_tracker.zig");
const tui_mod = @import("tui/app.zig");

const Tools = .{ calculator, word_count, read_file, write_file, list_files, execute_command, todo_write };
// Interceptor hooks (core/hook.zig, design doc §3.7) fire in tuple order.
// `tool_audit_log` is the observe-only sample hook the design shipped
// with; drop it from this tuple to silence the audit lines. `todo_tracker`
// pairs with the `todo_write` tool above (design doc §3.8).
const Hooks = .{ tool_audit_log, todo_tracker };
const Agent = agent_mod.Agent(Tools, llm.Glm, Hooks);

// `zig build test` walks the whole `@import` graph for source, but Zig
// 0.16 only *registers* a file's `test` blocks once that file's container
// is fully resolved — which merely calling one of its functions doesn't
// force. Without this, `zig build test` silently reports "0 tests passed"
// as success. One `refAllDecls` per module that has its own `test` blocks;
// add a line here whenever a new such module is introduced.
test {
    std.testing.refAllDecls(@import("core/engine.zig"));
    std.testing.refAllDecls(@import("core/hook.zig"));
    std.testing.refAllDecls(@import("core/tool.zig"));
    std.testing.refAllDecls(@import("plugins/tools/todo_write.zig"));
    std.testing.refAllDecls(@import("plugins/hooks/tool_audit_log.zig"));
    std.testing.refAllDecls(@import("plugins/hooks/todo_tracker.zig"));
    std.testing.refAllDecls(@import("tui/app.zig"));
}

const Cli = struct {
    prompt: ?[]const u8 = null,
    session: ?[]const u8 = null,
    style: engine.Style = .react,
};

fn parseCli(args: std.process.Args) !Cli {
    var cli: Cli = .{};
    var it = args.iterate();
    _ = it.next(); // argv[0]
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--prompt")) {
            cli.prompt = it.next() orelse return error.MissingPromptValue;
        } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--session")) {
            cli.session = it.next() orelse return error.MissingSessionValue;
        } else if (std.mem.eql(u8, arg, "-m") or std.mem.eql(u8, arg, "--style")) {
            const v = it.next() orelse return error.MissingStyleValue;
            if (std.mem.eql(u8, v, "react")) {
                cli.style = .react;
            } else if (std.mem.eql(u8, v, "todo")) {
                cli.style = .todo;
            } else {
                return error.InvalidStyleValue;
            }
        }
    }
    return cli;
}

// ─── main ─────────────────────────────────────────────────────────────────────

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    const cli = parseCli(init.minimal.args) catch {
        const stderr = std.Io.File.stderr();
        var buf: [256]u8 = undefined;
        var w = stderr.writerStreaming(io, &buf);
        try w.interface.writeAll("Usage: mymew [-p <prompt>] [-s <session-id>] [-m react|todo]\n");
        try w.interface.flush();
        return;
    };

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

    const memory_path = if (cli.session) |s|
        try std.fmt.allocPrint(init.arena.allocator(), "mymew_session_{s}.jsonl", .{s})
    else
        init.environ_map.get("MYMEW_MEMORY_PATH") orelse "mymew_memory.jsonl";

    var mem = try memory.Memory.init(gpa, io, memory_path);
    defer mem.deinit();

    if (cli.prompt) |prompt| {
        return runHeadless(gpa, io, &glm, &mem, prompt, cli.style);
    }

    // NO_COLOR (no-color.org: any non-empty value) and TERM=dumb both get
    // the monochrome theme — chrome uncolored, streamed SGR stripped at
    // render time.
    const no_color = blk: {
        if (init.environ_map.get("NO_COLOR")) |v| {
            if (v.len > 0) break :blk true;
        }
        if (init.environ_map.get("TERM")) |t| {
            if (std.mem.eql(u8, t, "dumb")) break :blk true;
        }
        break :blk false;
    };
    const session_label = cli.session orelse "default";
    return runInteractive(gpa, io, &glm, &mem, cli.style, .{
        .theme = tui_mod.Theme.init(!no_color),
        .model_label = glm.model,
        .session_label = session_label,
    });
}

/// One-shot, non-interactive turn: run the same orchestrator as the TUI, but
/// print streamed tokens straight to stdout and exit — no raw mode, no
/// threads, no render loop. Lets the agent be driven as a plain CLI tool
/// (e.g. scripted, piped) instead of only through the TUI frontend.
fn runHeadless(gpa: std.mem.Allocator, io: std.Io, glm: *llm.Glm, mem: *memory.Memory, prompt: []const u8, style: engine.Style) !void {
    var eng = Agent.EngineT.init(gpa, io, glm, mem);
    eng.setStyle(style);

    const stdout = std.Io.File.stdout();
    var buf: [4096]u8 = undefined;
    var w = stdout.writerStreaming(io, &buf);

    if (eng.step(prompt, &w.interface)) |outcome| {
        // `.final` was already streamed to stdout as it was generated.
        // `.escalated`'s report is gpa-owned and ours to free — after
        // printing it (§3.3: the failure report must reach the user).
        if (outcome == .escalated) {
            try w.interface.print("\n{s}\n", .{outcome.escalated});
            gpa.free(outcome.escalated);
        }
    } else |err| {
        try w.interface.print("[error: {s}]\n", .{@errorName(err)});
    }
    try w.interface.flush();
}

const InteractiveOpts = struct {
    theme: tui_mod.Theme,
    model_label: []const u8,
    session_label: []const u8,
};

fn runInteractive(gpa: std.mem.Allocator, io: std.Io, glm: *llm.Glm, mem: *memory.Memory, style: engine.Style, opts: InteractiveOpts) !void {
    // Self-pipe for waking up the poll() in the render loop
    var pipe_fds: [2]posix.fd_t = undefined;
    if (std.c.pipe(&pipe_fds) != 0) return error.PipeFailed;
    defer _ = std.c.close(pipe_fds[0]);
    defer _ = std.c.close(pipe_fds[1]);

    var agent = Agent.init(gpa, io, glm, mem, pipe_fds[1]);
    defer agent.deinit();
    agent.eng.setStyle(style);

    const stdin_fd: posix.fd_t = 0;
    const stdout_fd: posix.fd_t = 1;

    // Raw mode; register the same state with the panic path so a crash
    // anywhere below still leaves the terminal usable.
    const orig_termios = try tui_mod.enableRawMode(stdin_fd);
    defer tui_mod.disableRawMode(stdin_fd, orig_termios);
    tui_mod.registerPanicRestore(stdin_fd, stdout_fd, orig_termios);

    var ui = try tui_mod.Tui.init(gpa, stdout_fd, opts.theme);
    defer ui.deinit();
    ui.setContext(opts.model_label, opts.session_label);
    ui.todo_mode = style == .todo;

    // Seed prompt history from hydrated memory, so ↑ recalls prompts from
    // previous sessions of this transcript too. Also restore the todo panel
    // from the last persisted `todo_write` result, if any — the list was
    // never stored anywhere but this ordinary tool-result message, so
    // restoring the panel is just reading it back out (design doc §3.8).
    var last_todos: ?[]const u8 = null;
    for (mem.items()) |m| {
        if (m.role == .user) ui.pushHistory(m.content);
        if (m.role == .tool and std.mem.eql(u8, m.name, "todo_write")) last_todos = m.content;
    }
    if (last_todos) |t| ui.setTodos(t);

    ui.enter();
    defer ui.leave();

    tui_mod.installResizeHandler(pipe_fds[1]);

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
        _ = posix.poll(&poll_fds, 400) catch 0; // 400ms for spinner/dot animation

        // Drain wakeup pipe
        if (poll_fds[1].revents & posix.POLL.IN != 0) {
            var discard: [64]u8 = undefined;
            _ = std.c.read(pipe_fds[0], &discard, discard.len);
        }

        if (tui_mod.takeResized()) {
            ui.handleResize();
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
            if (drain_buf.items.len > 0) ui.appendOutput(drain_buf.items);
        }

        ui.setBusy(agent.state.thinking.load(.acquire));
        _ = ui.tickDots();

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

            // Any key (except quit above) dismisses the help overlay.
            // Escape sequences still get read so their bytes don't leak
            // into the composer; wheel events don't dismiss.
            if (ui.help_visible) {
                if (key == 27) {
                    switch (tui_mod.readEscapeSequence(stdin_fd)) {
                        .wheel_up, .wheel_down => continue,
                        else => {},
                    }
                }
                ui.toggleHelp();
                continue;
            }

            switch (key) {
                16 => { // Ctrl+P: toggle todo-nudge style
                    const cur = agent.eng.style.load(.acquire);
                    const next: engine.Style = if (cur == .react) .todo else .react;
                    agent.eng.setStyle(next);
                    ui.setStyle(next == .todo);
                },
                7 => ui.toggleHelp(), // Ctrl+G
                12 => ui.redraw(), // Ctrl+L
                26 => { // Ctrl+Z: suspend properly, resume with a full redraw
                    ui.leave();
                    tui_mod.disableRawMode(stdin_fd, orig_termios);
                    _ = std.c.raise(posix.SIG.TSTP);
                    // ...stopped; resumed here on SIGCONT.
                    _ = tui_mod.enableRawMode(stdin_fd) catch {};
                    ui.enter();
                    ui.handleResize(); // window may have changed while stopped
                },
                27 => switch (tui_mod.readEscapeSequence(stdin_fd)) {
                    // Esc priority chain: cancel a running turn, else jump
                    // a scrolled viewport back to the tail, else clear the
                    // composer.
                    .escape => {
                        if (agent.state.thinking.load(.acquire)) {
                            agent.requestCancel();
                            ui.setCancelling();
                        } else if (ui.scrolled()) {
                            ui.jumpTail();
                        } else {
                            ui.clearComposer();
                        }
                    },
                    .up => ui.composerMove(.up),
                    .down => ui.composerMove(.down),
                    .left => ui.composerMove(.left),
                    .right => ui.composerMove(.right),
                    .home => ui.composerMove(.home),
                    .end_key => ui.composerMove(.end),
                    .delete => ui.composerMove(.delete),
                    .alt_enter => ui.insertNewline(),
                    .page_up => ui.scrollPage(.up),
                    .page_down => ui.scrollPage(.down),
                    .wheel_up => {
                        ui.scrollLine(.up);
                        ui.scrollLine(.up);
                        ui.scrollLine(.up);
                    },
                    .wheel_down => {
                        ui.scrollLine(.down);
                        ui.scrollLine(.down);
                        ui.scrollLine(.down);
                    },
                    .none => {},
                },
                else => {
                    const submitted = ui.handleKey(key);
                    if (submitted) {
                        const text = ui.takeInput();
                        if (text.len > 0) {
                            ui.beginTurn();
                            ui.setBusy(true);
                            agent.submit(text);
                        }
                    }
                },
            }
        }
    }

    agent.requestStop();
}
