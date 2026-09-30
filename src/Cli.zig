//! Command-line creation and extraction of text archives.

const std = @import("std");
const mem = std.mem;
const fmt = std.fmt;
const testing = std.testing;
const process = std.process;
const Io = std.Io;
const Dir = Io.Dir;
const ArgIterator = process.Args.Iterator;
const Cli = @This();

const txtar = @import("txtar");

io: Io,
stderr: *Io.Writer,
stdout: *Io.Writer,

const program = "txtar";

const Mode = enum { create, extract };

const Options = struct {
    mode: ?Mode = null,
    archive_path: ?[]const u8 = null,
    directory: []const u8 = ".",
    first_path: ?[]const u8 = null,
    verbose: bool = false,
};

pub fn run(cli: *const Cli, args: *ArgIterator) !void {
    const options = try parseOptions(args);

    switch (options.mode orelse return error.Usage) {
        .create => try cli.create(options, args),
        .extract => {
            if (args.next() != null) return error.Usage;
            try cli.extract(options);
        },
    }
}

fn parseOptions(args: *ArgIterator) !Options {
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

fn parseShortOptions(options: *Options, args: *ArgIterator, flags: []const u8) !void {
    var i: u32 = 0;
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

fn optionValue(args: *ArgIterator, rest: []const u8) ?[]const u8 {
    if (rest.len > 0) return rest;
    return args.next();
}

pub fn usage(cli: *const Cli) void {
    cli.stderr.print(
        \\usage:
        \\  {s} -c [-v] [-f ARCHIVE.txtar] [-C DIR] FILE...
        \\  {s} -x [-v] -f ARCHIVE.txtar [-C DIR]
        \\
    ,
        .{ program, program },
    ) catch return;
}

fn extract(cli: *const Cli, options: Options) !void {
    const archive_path = options.archive_path orelse return error.Usage;

    const archive_file = try Dir.cwd().openFile(cli.io, archive_path, .{});
    defer archive_file.close(cli.io);

    var reader_buf: [4096]u8 = undefined;
    var archive_reader = archive_file.reader(cli.io, &reader_buf);

    var archive: txtar.Reader = .init(&archive_reader.interface);

    const out_dir = try Dir.cwd().createDirPathOpen(cli.io, options.directory, .{});
    defer out_dir.close(cli.io);

    var writer_buf: [4096]u8 = undefined;

    while (try archive.next()) |entry| {
        if (!safeRelativePath(entry.name)) return error.UnsafePath;

        if (Dir.path.dirname(entry.name)) |parent| {
            try out_dir.createDirPath(cli.io, parent);
        }

        if (options.verbose) try cli.stderr.print("x {s}\n", .{entry.name});

        const out_file = try out_dir.createFile(cli.io, entry.name, .{});
        defer out_file.close(cli.io);

        var file_writer = out_file.writer(cli.io, &writer_buf);
        try entry.writeTo(&file_writer.interface);
        try file_writer.interface.flush();
    }
}

fn create(cli: *const Cli, options: Options, args: *ArgIterator) !void {
    const in_dir = try Dir.cwd().openDir(cli.io, options.directory, .{});
    defer in_dir.close(cli.io);

    if (options.archive_path) |archive_path| {
        const archive_file = try Dir.cwd().createFile(cli.io, archive_path, .{});
        defer archive_file.close(cli.io);

        var writer_buf: [4096]u8 = undefined;
        var file_writer = archive_file.writer(cli.io, &writer_buf);
        const writer = &file_writer.interface;

        var archive: txtar.Writer = .init(writer);
        try cli.createArchive(in_dir, &archive, options.first_path, args, options.verbose);
        try writer.flush();
    } else {
        var archive: txtar.Writer = .init(cli.stdout);
        try cli.createArchive(in_dir, &archive, options.first_path, args, options.verbose);
    }
}

fn createArchive(
    cli: *const Cli,
    in_dir: Dir,
    archive: *txtar.Writer,
    first_path: ?[]const u8,
    args: *ArgIterator,
    verbose: bool,
) !void {
    var wrote_file = false;
    if (first_path) |path| {
        try cli.appendPath(in_dir, archive, path, verbose);
        wrote_file = true;
    }
    while (args.next()) |path| {
        try cli.appendPath(in_dir, archive, path, verbose);
        wrote_file = true;
    }

    if (!wrote_file) return error.Usage;
}

fn appendPath(cli: *const Cli, dir: Dir, archive: *txtar.Writer, path: []const u8, verbose: bool) !void {
    if (!safeRelativePath(path)) return error.UnsafePath;

    const archive_path = mem.trimEnd(u8, path, "/");
    if (archive_path.len == 0) return error.UnsafePath;

    const stat = try dir.statFile(cli.io, archive_path, .{});
    return switch (stat.kind) {
        .file => cli.appendFile(dir, archive, archive_path, verbose),
        .directory => cli.appendDir(dir, archive, archive_path, verbose),
        else => error.UnsupportedFileKind,
    };
}

fn appendDir(cli: *const Cli, parent: Dir, archive: *txtar.Writer, path: []const u8, verbose: bool) !void {
    const dir = try parent.openDir(cli.io, path, .{ .iterate = true });
    defer dir.close(cli.io);

    var path_buf: [Dir.max_path_bytes]u8 = undefined;

    var entries = dir.iterate();
    while (try entries.next(cli.io)) |entry| {
        const child_path = try fmt.bufPrint(&path_buf, "{s}/{s}", .{ path, entry.name });

        try switch (entry.kind) {
            .file => cli.appendFile(parent, archive, child_path, verbose),
            .directory => cli.appendDir(parent, archive, child_path, verbose),
            else => {},
        };
    }
}

fn appendFile(cli: *const Cli, dir: Dir, archive: *txtar.Writer, path: []const u8, verbose: bool) !void {
    const file = try dir.openFile(cli.io, path, .{});
    defer file.close(cli.io);

    if (verbose) try cli.stderr.print("a {s}\n", .{path});

    var entry = try archive.beginEntry(path);
    defer entry.finish() catch {};

    var buf: [4096]u8 = undefined;
    var reader = file.reader(cli.io, &buf);
    try entry.writeFrom(&reader.interface);
    try entry.finish();
}

fn safeRelativePath(path: []const u8) bool {
    if (path.len == 0 or Dir.path.isAbsolute(path)) return false;

    var parts = mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (mem.eql(u8, part, "..")) return false;
    }

    return true;
}

fn runArgs(cli: *const Cli, argv: []const [*:0]const u8) !void {
    const args: process.Args = .{ .vector = argv };
    var iterator = args.iterate();
    try cli.run(&iterator);
}

test "options accept combined flags and inline values" {
    const args: process.Args = .{ .vector = &.{ "txtar", "-cvfarchive.txtar", "-Cout", "a.txt" } };
    var iterator = args.iterate();
    const options = try parseOptions(&iterator);

    try testing.expectEqual(Mode.create, options.mode.?);
    try testing.expect(options.verbose);
    try testing.expectEqualStrings("archive.txtar", options.archive_path.?);
    try testing.expectEqualStrings("out", options.directory);
    try testing.expectEqualStrings("a.txt", options.first_path.?);
    try testing.expect(iterator.next() == null);
}

test "options stop at the separator" {
    const args: process.Args = .{ .vector = &.{ "txtar", "-c", "--", "-file.txt" } };
    var iterator = args.iterate();
    const options = try parseOptions(&iterator);

    try testing.expectEqual(Mode.create, options.mode.?);
    try testing.expect(options.first_path == null);
    try testing.expectEqualStrings("-file.txt", iterator.next().?);
}

test "options reject conflicting modes and missing values" {
    const cases: []const []const [*:0]const u8 = &.{
        &.{ "txtar", "-cx" },
        &.{ "txtar", "-cc" },
        &.{ "txtar", "-z" },
        &.{ "txtar", "-cf" },
        &.{ "txtar", "-xC" },
    };
    for (cases) |argv| {
        const args: process.Args = .{ .vector = argv };
        var iterator = args.iterate();
        try testing.expectError(error.Usage, parseOptions(&iterator));
    }
}

test "CLI creates nested and empty files on stdout" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "nested/deep");
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "nested/deep/hello.txt",
        .data = "hello",
    });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "empty.txt", .data = "" });

    var path_buf: [Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(testing.io, &path_buf);
    const directory = try fmt.allocPrintSentinel(testing.allocator, "{s}", .{path_buf[0..path_len]}, 0);
    defer testing.allocator.free(directory);

    var stdout_buf: [256]u8 = undefined;
    var stdout: Io.Writer = .fixed(&stdout_buf);
    var stderr_buf: [256]u8 = undefined;
    var stderr: Io.Writer = .fixed(&stderr_buf);
    const cli: Cli = .{ .io = testing.io, .stdout = &stdout, .stderr = &stderr };

    try runArgs(&cli, &.{ "txtar", "-cv", "-C", directory, "nested/", "empty.txt" });

    try testing.expectEqualStrings(
        "-- nested/deep/hello.txt --\nhello\n-- empty.txt --\n",
        stdout.buffered(),
    );
    try testing.expectEqualStrings("a nested/deep/hello.txt\na empty.txt\n", stderr.buffered());
}

test "CLI creates and extracts an archive file across buffer boundaries" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data = "x" ** (4096 + 128) ++ "\n";
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "payload.txt", .data = data });

    var path_buf: [Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(testing.io, &path_buf);
    const directory = try fmt.allocPrintSentinel(testing.allocator, "{s}", .{path_buf[0..path_len]}, 0);
    defer testing.allocator.free(directory);
    const archive_path = try fmt.allocPrintSentinel(testing.allocator, "{s}/archive.txtar", .{directory}, 0);
    defer testing.allocator.free(archive_path);
    const output_path = try fmt.allocPrintSentinel(testing.allocator, "{s}/out/deep", .{directory}, 0);
    defer testing.allocator.free(output_path);

    var stdout: Io.Writer.Discarding = .init(&.{});
    var stderr_buf: [256]u8 = undefined;
    var stderr: Io.Writer = .fixed(&stderr_buf);
    const cli: Cli = .{ .io = testing.io, .stdout = &stdout.writer, .stderr = &stderr };

    try runArgs(&cli, &.{ "txtar", "-cvf", archive_path, "-C", directory, "payload.txt" });
    const archive = try tmp.dir.readFileAlloc(testing.io, "archive.txtar", testing.allocator, .limited(8192));
    defer testing.allocator.free(archive);
    try testing.expectEqualStrings("-- payload.txt --\n" ++ data, archive);

    try runArgs(&cli, &.{ "txtar", "-xvf", archive_path, "-C", output_path });
    const extracted = try tmp.dir.readFileAlloc(testing.io, "out/deep/payload.txt", testing.allocator, .limited(8192));
    defer testing.allocator.free(extracted);
    try testing.expectEqualStrings(data, extracted);
    try testing.expectEqualStrings("a payload.txt\nx payload.txt\n", stderr.buffered());
}

test "CLI rejects unsafe archive entry names" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(testing.io, &path_buf);
    const directory = path_buf[0..path_len];
    const archive_path = try fmt.allocPrintSentinel(testing.allocator, "{s}/archive.txtar", .{directory}, 0);
    defer testing.allocator.free(archive_path);
    const output_path = try fmt.allocPrintSentinel(testing.allocator, "{s}/out", .{directory}, 0);
    defer testing.allocator.free(output_path);

    var discard: Io.Writer.Discarding = .init(&.{});
    const cli: Cli = .{ .io = testing.io, .stdout = &discard.writer, .stderr = &discard.writer };
    for ([_][]const u8{ "../escape.txt", "nested/../../escape.txt", "/absolute.txt" }) |name| {
        var archive: Io.Writer.Allocating = .init(testing.allocator);
        defer archive.deinit();
        try archive.writer.print("-- {s} --\nunsafe\n", .{name});
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "archive.txtar", .data = archive.written() });
        try testing.expectError(error.UnsafePath, runArgs(&cli, &.{ "txtar", "-xf", archive_path, "-C", output_path }));
    }
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(testing.io, "escape.txt", .{}));
}
