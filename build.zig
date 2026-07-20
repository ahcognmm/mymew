const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "mymew",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the agent");
    const run_cmd = b.addRunArtifact(exe);
    // Default `.auto` injects NO_COLOR=1 into the child's env whenever the
    // build runner's own stderr isn't a tty (e.g. `zig build run 2> log`)
    // — nothing to do with whether the *agent's* actual output stream is a
    // terminal. `.manual` leaves NO_COLOR/CLICOLOR_FORCE untouched so the
    // TUI's own detection (main.zig, off of the invoking shell's real env)
    // is what decides.
    run_cmd.color = .manual;
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    run_step.dependOn(&run_cmd.step);

    const test_step = b.step("test", "Run unit tests");
    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    test_step.dependOn(&run_exe_tests.step);
}
