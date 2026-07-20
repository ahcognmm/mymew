//! Interceptor hook (design doc §3.7/§3.9) gating `execute_command` behind
//! human approval when the command matches a destructive pattern. Fails
//! closed: with no approver attached (headless), a matched command is vetoed
//! outright instead of silently running. A veto is not a self-healing
//! failure — it flows back to the LLM as the tool result so the model can
//! ask the user how to proceed instead of retrying.

const std = @import("std");
const hook = @import("../../core/hook.zig");

pub fn name() []const u8 {
    return "command_guard";
}

/// Two-word (or longer) phrases where a plain substring match can't
/// realistically false-positive. Checked anywhere in the command.
const phrases = [_][]const u8{
    "kubectl delete",
    "kubectl drain",
    "terraform destroy",
    "terraform apply",
    "helm uninstall",
    "helm delete",
    "docker rm",
    "docker rmi",
    "docker system prune",
    "docker volume rm",
    "git push --force",
    "git push -f",
    "git reset --hard",
    "git clean",
    "git branch -D",
    "systemctl stop",
    "systemctl disable",
    "systemctl mask",
    "chmod -R",
    "chown -R",
    "DROP TABLE",
    "DROP DATABASE",
    "TRUNCATE TABLE",
};

/// Single words dangerous on their own — matched only in command position
/// (the first token of a shell segment), so `echo rm` or a filename
/// containing "dd" never trips them.
const leader_words = [_][]const u8{
    "rm",   "rmdir",    "dd",       "shred",
    "shutdown", "reboot", "halt",   "poweroff",
    "kill", "killall",  "pkill",    "truncate",
    "sudo", "doas",
};

/// Returns the matched pattern when `command` looks destructive, else null.
/// Public so the classification is unit-testable without an engine.
pub fn classify(command: []const u8) ?[]const u8 {
    for (phrases) |p| {
        if (std.mem.indexOf(u8, command, p) != null) return p;
    }
    // First real token of every shell segment (split on ; | & newline,
    // subshells and backticks), skipping FOO=bar environment prefixes.
    var seg_it = std.mem.splitAny(u8, command, ";|&\n()`");
    while (seg_it.next()) |seg| {
        var tok_it = std.mem.tokenizeAny(u8, seg, " \t");
        while (tok_it.next()) |tok| {
            if (std.mem.indexOfScalar(u8, tok, '=') != null) continue;
            if (std.mem.startsWith(u8, tok, "mkfs")) return "mkfs";
            for (leader_words) |w| {
                if (std.mem.eql(u8, tok, w)) return w;
            }
            break; // only the command-position token matters per segment
        }
    }
    return null;
}

pub fn preTool(ctx: hook.Ctx, tool_name: []const u8, args_json: *[]const u8) anyerror!hook.PreToolAction {
    if (!std.mem.eql(u8, tool_name, "execute_command")) return .proceed;

    // Malformed JSON is the self-healing loop's job (§3.2), not this
    // hook's — proceed and let dispatch produce the real diagnostic.
    const parsed = std.json.parseFromSlice(
        struct { command: []const u8 = "" },
        ctx.scratch,
        args_json.*,
        .{ .ignore_unknown_fields = true },
    ) catch return .proceed;
    const cmd = parsed.value.command;

    const label = classify(cmd) orelse return .proceed;

    const approver = ctx.approver orelse return .{ .veto = try std.fmt.allocPrint(
        ctx.scratch,
        "Execution blocked by command_guard: the command matched destructive pattern \"{s}\" and no interactive approval is available in this mode. Do not retry it. Ask the user to run it themselves or to re-run you interactively.",
        .{label},
    ) };

    const question = try std.fmt.allocPrint(ctx.scratch, "[{s}] {s}", .{ label, cmd });
    if (approver.request(question)) return .proceed;

    return .{ .veto = try std.fmt.allocPrint(
        ctx.scratch,
        "User DENIED execution of: {s}\nDo not retry this command. Ask the user how they want to proceed.",
        .{cmd},
    ) };
}

const testing = std.testing;

test "classify flags destructive commands in command position only" {
    try testing.expectEqualStrings("rm", classify("rm -rf /tmp/x").?);
    try testing.expectEqualStrings("rm", classify("ls && rm foo").?);
    try testing.expectEqualStrings("sudo", classify("FOO=1 sudo systemctl restart nginx").?);
    try testing.expectEqualStrings("mkfs", classify("mkfs.ext4 /dev/sdb1").?);
    try testing.expectEqualStrings("terraform destroy", classify("cd infra && terraform destroy -auto-approve").?);
    try testing.expectEqualStrings("git push -f", classify("git push -f origin main").?);

    // No false positives from words that merely contain or mention a pattern.
    try testing.expect(classify("echo confirm rm is dangerous") == null);
    try testing.expect(classify("git status") == null);
    try testing.expect(classify("kubectl get pods") == null);
    try testing.expect(classify("grep -r 'shutdown' src/") == null);
}

fn testCtx(scratch: std.mem.Allocator, approver: ?hook.Approver) hook.Ctx {
    return .{
        .gpa = testing.allocator,
        .scratch = scratch,
        .writer = null,
        .approver = approver,
    };
}

test "preTool vetoes a destructive command when no approver is attached (fail closed)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var args: []const u8 = "{\"command\":\"rm -rf /var/lib/data\"}";
    const action = try preTool(testCtx(arena.allocator(), null), "execute_command", &args);
    try testing.expect(action == .veto);
    try testing.expect(std.mem.indexOf(u8, action.veto, "no interactive approval") != null);
}

test "preTool consults the approver: approve proceeds, deny vetoes" {
    const Answer = struct {
        var approve: bool = false;
        fn request(ptr: *anyopaque, question: []const u8) bool {
            _ = ptr;
            _ = question;
            return approve;
        }
    };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var dummy: u8 = 0;
    const approver: hook.Approver = .{ .ptr = &dummy, .requestFn = Answer.request };

    var args: []const u8 = "{\"command\":\"terraform apply\"}";
    Answer.approve = true;
    try testing.expect((try preTool(testCtx(arena.allocator(), approver), "execute_command", &args)) == .proceed);
    Answer.approve = false;
    const denied = try preTool(testCtx(arena.allocator(), approver), "execute_command", &args);
    try testing.expect(denied == .veto);
    try testing.expect(std.mem.indexOf(u8, denied.veto, "DENIED") != null);
}

test "preTool ignores non-destructive commands and other tools" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var safe: []const u8 = "{\"command\":\"kubectl get pods -A\"}";
    try testing.expect((try preTool(testCtx(arena.allocator(), null), "execute_command", &safe)) == .proceed);
    var other: []const u8 = "{\"path\":\"/etc/hosts\"}";
    try testing.expect((try preTool(testCtx(arena.allocator(), null), "read_file", &other)) == .proceed);
}
