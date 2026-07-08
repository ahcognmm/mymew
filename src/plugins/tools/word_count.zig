const std = @import("std");

pub const Args = struct {
    text: []const u8,
};

pub fn name() []const u8 {
    return "word_count";
}

pub fn description() []const u8 {
    return "Counts the number of whitespace-separated words in a piece of text.";
}

pub fn execute(alloc: std.mem.Allocator, args: Args) anyerror![]const u8 {
    var count: usize = 0;
    var it = std.mem.tokenizeAny(u8, args.text, " \t\r\n");
    while (it.next()) |_| count += 1;
    return std.fmt.allocPrint(alloc, "{d}", .{count});
}
