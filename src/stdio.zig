const fs = @import("std").fs;

var stderr_buf: [4096]u8 = undefined;
var stderr_writer: fs.File.Writer = .init(.stderr(), &stderr_buf);
pub const stderr = &stderr_writer.interface;

var stdout_buf: [4096]u8 = undefined;
var stdout_writer: fs.File.Writer = .init(.stdout(), &stdout_buf);
pub const stdout = &stdout_writer.interface;

pub fn flush() void {
    stderr.flush() catch {};
    stdout.flush() catch {};
}
