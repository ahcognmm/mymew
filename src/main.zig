const std = @import("std");
const engine = @import("core/engine.zig");
const llm = @import("core/llm.zig");
const memory = @import("core/memory.zig");
const calculator = @import("plugins/tools/calculator.zig");
const word_count = @import("plugins/tools/word_count.zig");

const Tools = .{ calculator, word_count };

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
    const stdout = &stdout_writer.interface;

    var glm = llm.Glm.fromEnv(init.environ_map) catch {
        try stdout.writeAll(
            "Set GLM_API_KEY (or ZAI_API_KEY) to your z.ai / Zhipu GLM API key to start chatting.\n" ++
                "Optional: GLM_MODEL, GLM_BASE_URL, MYMEW_MEMORY_PATH.\n",
        );
        try stdout.flush();
        return;
    };

    const memory_path = init.environ_map.get("MYMEW_MEMORY_PATH") orelse "mymew_memory.jsonl";
    var mem = try memory.Memory.init(gpa, io, memory_path);
    defer mem.deinit();

    var eng = engine.Engine(Tools, llm.Glm).init(gpa, io, &glm, &mem);

    var stdin_buf: [4096]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().readerStreaming(io, &stdin_buf);
    const stdin = &stdin_reader.interface;

    try stdout.print("mymew agent ready (model: {s}). Type 'exit' to quit.\n", .{glm.model});
    try stdout.flush();

    while (true) {
        try stdout.writeAll("> ");
        try stdout.flush();

        const line = (stdin.takeDelimiter('\n') catch |err| switch (err) {
            error.StreamTooLong => {
                try stdout.writeAll("input line too long, ignoring\n");
                continue;
            },
            error.ReadFailed => return err,
        }) orelse break;

        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) continue;
        if (std.mem.eql(u8, trimmed, "exit") or std.mem.eql(u8, trimmed, "quit")) break;

        const outcome = eng.step(trimmed) catch |err| {
            try stdout.print("error: {s}\n", .{@errorName(err)});
            try stdout.flush();
            continue;
        };
        switch (outcome) {
            .final => |text| try stdout.print("{s}\n", .{text}),
            .escalated => |report| try stdout.print("[agent escalated]\n{s}\n", .{report}),
        }
        try stdout.flush();
    }
}
