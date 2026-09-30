//! Process entry point for the text archive CLI.

const std = @import("std");
const process = std.process;
const Io = std.Io;
const Cli = @import("Cli.zig");

pub fn main(init: process.Init) u8 {
    var stderr_buf: [4096]u8 = undefined;
    var stderr_writer: Io.File.Writer = .initStreaming(.stderr(), init.io, &stderr_buf);
    defer stderr_writer.interface.flush() catch {};

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer: Io.File.Writer = .initStreaming(.stdout(), init.io, &stdout_buf);

    const cli: Cli = .{
        .io = init.io,
        .stderr = &stderr_writer.interface,
        .stdout = &stdout_writer.interface,
    };
    var args = init.minimal.args.iterate();

    cli.run(&args) catch |err| {
        switch (err) {
            error.Usage => cli.usage(),
            else => cli.stderr.print("{t}\n", .{err}) catch return 1,
        }
        cli.stdout.flush() catch return 1;
        return 1;
    };
    cli.stdout.flush() catch |err| {
        cli.stderr.print("{t}\n", .{err}) catch return 1;
        return 1;
    };
    return 0;
}

test {
    std.testing.refAllDecls(@This());
}
