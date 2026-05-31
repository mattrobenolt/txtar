const std = @import("std");
const mem = std.mem;
const fs = std.fs;
const process = std.process;
const Io = std.Io;

const txtar = @import("txtar");

const stdio = @import("stdio.zig");
const stderr = stdio.stderr;
const stdout = stdio.stdout;

const program = "txtar";

pub fn main() u8 {
    defer stdio.flush();

    run() catch |err| {
        switch (err) {
            error.Usage => usage(),
            else => {
                stderr.print("{}", .{err}) catch {};
            },
        }
        return 1;
    };
    return 0;
}

const Mode = enum { create, extract };

const Options = struct {
    mode: ?Mode = null,
    archive_path: ?[]const u8 = null,
    directory: []const u8 = ".",
    first_path: ?[]const u8 = null,
    verbose: bool = false,
};

fn run() !void {
    var args = process.args();
    const options = try parseOptions(&args);

    switch (options.mode orelse return error.Usage) {
        .create => try create(options, &args),
        .extract => {
            if (args.next() != null) return error.Usage;
            try extract(options);
        },
    }
}

fn parseOptions(args: *process.ArgIterator) !Options {
    _ = args.skip();

    var options: Options = .{};

    while (args.next()) |arg| {
        if (mem.eql(u8, arg, "--")) break;
        if (!mem.startsWith(u8, arg, "-") or mem.eql(u8, arg, "-")) {
            options.first_path = arg;
            break;
        }

        try parseShortOptions(&options, args, arg[1..]);
    }

    return options;
}

fn parseShortOptions(options: *Options, args: *process.ArgIterator, flags: []const u8) !void {
    var i: usize = 0;
    while (i < flags.len) : (i += 1) {
        switch (flags[i]) {
            'c' => {
                if (options.mode != null) return error.Usage;
                options.mode = .create;
            },
            'x' => {
                if (options.mode != null) return error.Usage;
                options.mode = .extract;
            },
            'v' => options.verbose = true,
            'f' => {
                options.archive_path = optionValue(args, flags[i + 1 ..]) orelse return error.Usage;
                return;
            },
            'C' => {
                options.directory = optionValue(args, flags[i + 1 ..]) orelse return error.Usage;
                return;
            },
            else => return error.Usage,
        }
    }
}

fn optionValue(args: *process.ArgIterator, rest: []const u8) ?[]const u8 {
    if (rest.len > 0) return rest;
    return args.next();
}

fn usage() void {
    stderr.print(
        \\usage:
        \\  {s} -c [-v] [-f ARCHIVE.txtar] [-C DIR] FILE...
        \\  {s} -x [-v] -f ARCHIVE.txtar [-C DIR]
        \\
    ,
        .{ program, program },
    ) catch {};
}

fn extract(options: Options) !void {
    const archive_path = options.archive_path orelse return error.Usage;

    const archive_file = try fs.cwd().openFile(archive_path, .{});
    defer archive_file.close();

    var reader_buf: [4096]u8 = undefined;
    var archive_reader = archive_file.reader(&reader_buf);

    var archive: txtar.Reader = .init(&archive_reader.interface);

    var out_dir = try fs.cwd().makeOpenPath(options.directory, .{});
    defer out_dir.close();

    var writer_buf: [4096]u8 = undefined;

    while (try archive.next()) |entry| {
        if (!safeRelativePath(entry.name)) return error.UnsafePath;

        if (fs.path.dirname(entry.name)) |parent| {
            try out_dir.makePath(parent);
        }

        if (options.verbose) try stderr.print("x {s}\n", .{entry.name});

        const out_file = try out_dir.createFile(entry.name, .{});
        defer out_file.close();

        var file_writer = out_file.writer(&writer_buf);
        try entry.writeTo(&file_writer.interface);
        try file_writer.interface.flush();
    }
}

fn create(options: Options, args: *process.ArgIterator) !void {
    var in_dir = try fs.cwd().openDir(options.directory, .{});
    defer in_dir.close();

    if (options.archive_path) |archive_path| {
        const archive_file = try fs.cwd().createFile(archive_path, .{});
        defer archive_file.close();

        var writer_buf: [4096]u8 = undefined;
        var file_writer = archive_file.writer(&writer_buf);
        const writer = &file_writer.interface;

        var archive: txtar.Writer = .init(writer);
        try createArchive(in_dir, &archive, options.first_path, args, options.verbose);
        try writer.flush();
    } else {
        var archive: txtar.Writer = .init(stdout);
        try createArchive(in_dir, &archive, options.first_path, args, options.verbose);
    }
}

fn createArchive(
    in_dir: fs.Dir,
    archive: *txtar.Writer,
    first_path: ?[]const u8,
    args: *process.ArgIterator,
    verbose: bool,
) !void {
    var wrote_file = false;
    if (first_path) |path| {
        try appendPath(in_dir, archive, path, verbose);
        wrote_file = true;
    }
    while (args.next()) |path| {
        try appendPath(in_dir, archive, path, verbose);
        wrote_file = true;
    }

    if (!wrote_file) return error.Usage;
}

fn appendPath(dir: fs.Dir, archive: *txtar.Writer, path: []const u8, verbose: bool) !void {
    if (!safeRelativePath(path)) return error.UnsafePath;

    const archive_path = mem.trimEnd(u8, path, "/");
    if (archive_path.len == 0) return error.UnsafePath;

    const stat = try dir.statFile(archive_path);
    return switch (stat.kind) {
        .file => appendFile(dir, archive, archive_path, verbose),
        .directory => appendDir(dir, archive, archive_path, verbose),
        else => error.UnsupportedFileKind,
    };
}

fn appendDir(parent: fs.Dir, archive: *txtar.Writer, path: []const u8, verbose: bool) !void {
    var dir = try parent.openDir(path, .{ .iterate = true });
    defer dir.close();

    var path_buf: [fs.max_path_bytes]u8 = undefined;

    var entries = dir.iterate();
    while (try entries.next()) |entry| {
        const child_path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ path, entry.name });

        try switch (entry.kind) {
            .file => appendFile(parent, archive, child_path, verbose),
            .directory => appendDir(parent, archive, child_path, verbose),
            else => {},
        };
    }
}

fn appendFile(dir: fs.Dir, archive: *txtar.Writer, path: []const u8, verbose: bool) !void {
    const file = try dir.openFile(path, .{});
    defer file.close();

    if (verbose) try stderr.print("a {s}\n", .{path});

    var entry = try archive.beginEntry(path);
    defer entry.finish() catch {};

    var buf: [4096]u8 = undefined;
    var reader = file.reader(&buf);
    try entry.writeFrom(&reader.interface);
    try entry.finish();
}

fn safeRelativePath(path: []const u8) bool {
    if (path.len == 0 or fs.path.isAbsolute(path)) return false;

    var parts = mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (mem.eql(u8, part, "..")) return false;
    }

    return true;
}
