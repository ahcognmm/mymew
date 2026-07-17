const std = @import("std");

pub const Op = enum { add, sub, mul, div };

pub const Args = struct {
    op: Op,
    a: f64,
    b: f64,
};

pub fn name() []const u8 {
    return "calculator";
}

pub fn description() []const u8 {
    return "Performs a basic arithmetic operation (add, sub, mul, div) on two numbers.";
}

pub fn describe(alloc: std.mem.Allocator, args: Args) anyerror![]const u8 {
    return std.fmt.allocPrint(alloc, "{s} {d} and {d}", .{ @tagName(args.op), args.a, args.b });
}

pub fn execute(alloc: std.mem.Allocator, args: Args) anyerror![]const u8 {
    const result: f64 = switch (args.op) {
        .add => args.a + args.b,
        .sub => args.a - args.b,
        .mul => args.a * args.b,
        .div => if (args.b == 0) return error.DivisionByZero else args.a / args.b,
    };
    return std.fmt.allocPrint(alloc, "{d}", .{result});
}
