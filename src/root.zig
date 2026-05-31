//! Text archive parser and formatter, modeled after Go's golang.org/x/tools/txtar.
//!
//! A txtar archive is comment text followed by zero or more file entries. Each
//! entry starts with a marker line of the form `-- filename --` and continues
//! until the next marker line.

const std = @import("std");
const testing = std.testing;
const mem = std.mem;
const fs = std.fs;
const Io = std.Io;
const Allocator = mem.Allocator;

const marker = "-- ";
const marker_end = " --";
const marker_candidate_max = fs.max_path_bytes + marker.len + marker_end.len;

/// A complete txtar archive owned by the caller.
pub const Archive = struct {
    comment: []const u8,
    files: []const File,

    pub const empty: Archive = .{
        .comment = "",
        .files = &.{},
    };

    pub fn deinit(self: *Archive, gpa: Allocator) void {
        gpa.free(self.comment);
        for (self.files) |file| file.deinit(gpa);
        gpa.free(self.files);
        self.* = undefined;
    }
};

/// A single file in an owned txtar archive.
pub const File = struct {
    name: []const u8,
    data: []const u8,

    pub fn deinit(self: File, gpa: Allocator) void {
        gpa.free(self.name);
        gpa.free(self.data);
    }
};

/// Parses a complete txtar archive into owned memory.
pub fn parse(gpa: Allocator, input: []const u8) !Archive {
    var input_reader: Io.Reader = .fixed(input);
    var reader: Reader = .init(&input_reader);

    var comment_writer: Io.Writer.Allocating = .init(gpa);
    defer comment_writer.deinit();
    try reader.writeCommentTo(&comment_writer.writer);

    var files: std.ArrayList(File) = .empty;
    defer {
        for (files.items) |file| file.deinit(gpa);
        files.deinit(gpa);
    }

    while (try reader.next()) |entry| {
        const name = try gpa.dupe(u8, entry.name);
        errdefer gpa.free(name);

        var data_writer: Io.Writer.Allocating = .init(gpa);
        defer data_writer.deinit();
        try entry.writeTo(&data_writer.writer);

        const data = try data_writer.toOwnedSlice();
        errdefer gpa.free(data);

        try files.append(gpa, .{ .name = name, .data = data });
    }

    const comment = try comment_writer.toOwnedSlice();
    errdefer gpa.free(comment);

    const owned_files = try files.toOwnedSlice(gpa);

    return .{ .comment = comment, .files = owned_files };
}

/// Formats a complete txtar archive into owned memory.
pub fn format(gpa: Allocator, archive: Archive) ![]u8 {
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var writer: Writer = .init(&out.writer);
    try writer.writeComment(archive.comment);
    for (archive.files) |file| {
        var entry = try writer.beginEntry(file.name);
        try entry.writeAll(file.data);
        try entry.finish();
    }

    return out.toOwnedSlice();
}

/// Writes a txtar archive incrementally.
pub const Writer = struct {
    writer: *Io.Writer,
    entry_open: bool = false,

    pub fn init(writer: *Io.Writer) Writer {
        return .{ .writer = writer };
    }

    pub fn writeComment(self: *Writer, comment: []const u8) !void {
        if (self.entry_open) return error.EntryOpen;
        try writeFixedNl(self.writer, comment);
    }

    pub fn beginEntry(self: *Writer, name: []const u8) !EntryWriter {
        if (self.entry_open) return error.EntryOpen;
        try self.writer.print(marker ++ "{s}" ++ marker_end ++ "\n", .{name});
        self.entry_open = true;
        return .{ .archive = self };
    }
};

pub const EntryWriter = struct {
    archive: *Writer,
    last_byte: ?u8 = null,
    finished: bool = false,

    pub fn writeAll(self: *EntryWriter, bytes: []const u8) !void {
        if (self.finished) return error.EntryClosed;
        try self.archive.writer.writeAll(bytes);
        if (bytes.len > 0) self.last_byte = bytes[bytes.len - 1];
    }

    pub fn writeByte(self: *EntryWriter, byte: u8) !void {
        if (self.finished) return error.EntryClosed;
        try self.archive.writer.writeByte(byte);
        self.last_byte = byte;
    }

    pub fn writeFrom(self: *EntryWriter, reader: *Io.Reader) !void {
        while (true) {
            const bytes = reader.peekGreedy(1) catch |err| switch (err) {
                error.EndOfStream => return,
                else => return err,
            };
            try self.writeAll(bytes);
            reader.toss(bytes.len);
        }
    }

    pub fn finish(self: *EntryWriter) !void {
        if (self.finished) return;
        if (self.last_byte) |byte| {
            if (byte != '\n') try self.archive.writer.writeByte('\n');
        }
        self.finished = true;
        self.archive.entry_open = false;
    }
};

/// Iterates over file entries in a txtar archive read from an `Io.Reader`.
///
/// This is streaming: `next` returns the next file name, and `writeEntry` pumps
/// that file's data to a writer until the next marker line.
pub const Reader = struct {
    reader: *Io.Reader,
    pending_name_buf: [fs.max_path_bytes]u8 = undefined,
    pending_name: ?[]const u8 = null,
    comment_written: bool = false,
    entry_open: bool = false,

    pub fn init(reader: *Io.Reader) Reader {
        return .{ .reader = reader };
    }

    pub fn writeCommentTo(self: *Reader, writer: *Io.Writer) !void {
        if (self.comment_written) return error.CommentAlreadyWritten;
        self.comment_written = true;
        try self.findNextMarker(writer);
    }

    pub fn next(self: *Reader) !?Entry {
        if (!self.comment_written) {
            var discard: Io.Writer.Discarding = .init(&.{});
            try self.writeCommentTo(&discard.writer);
        }

        if (self.entry_open) return error.EntryNotConsumed;
        const name = self.pending_name orelse return null;
        self.pending_name = null;
        self.entry_open = true;
        return .{ .name = name, .iterator = self };
    }

    fn writeEntry(self: *Reader, writer: *Io.Writer) !void {
        if (!self.entry_open) return error.NoOpenEntry;
        self.entry_open = false;
        self.pending_name = null;
        try self.streamUntilMarker(writer);
    }

    fn findNextMarker(self: *Reader, comment_writer: *Io.Writer) !void {
        try self.streamUntilMarker(comment_writer);
    }

    fn streamUntilMarker(self: *Reader, writer: *Io.Writer) !void {
        var at_line_start = true;
        var last_byte: ?u8 = null;
        while (true) {
            if (at_line_start and try self.consumeMarkerCandidate(writer, &last_byte)) return;

            const bytes = self.reader.peekGreedy(marker.len + 1) catch |err| switch (err) {
                error.EndOfStream => {
                    const remaining = self.reader.buffer[self.reader.seek..self.reader.end];
                    try writeAndNote(writer, &last_byte, remaining);
                    self.reader.toss(remaining.len);
                    if (last_byte) |byte| {
                        if (byte != '\n') try writer.writeByte('\n');
                    }
                    return;
                },
                else => return err,
            };

            if (mem.indexOf(u8, bytes, "\n" ++ marker)) |index| {
                const len = index + 1;
                try writeAndNote(writer, &last_byte, bytes[0..len]);
                self.reader.toss(len);
                at_line_start = true;
                continue;
            }

            const keep = @min(bytes.len, marker.len);
            const len = bytes.len - keep;
            if (len == 0) {
                const byte = try self.reader.takeByte();
                try writeByteAndNote(writer, &last_byte, byte);
                at_line_start = false;
            } else {
                try writeAndNote(writer, &last_byte, bytes[0..len]);
                self.reader.toss(len);
                at_line_start = false;
            }
        }
    }

    fn writeAndNote(writer: *Io.Writer, last_byte: *?u8, bytes: []const u8) !void {
        try writer.writeAll(bytes);
        if (bytes.len > 0) last_byte.* = bytes[bytes.len - 1];
    }

    fn writeByteAndNote(writer: *Io.Writer, last_byte: *?u8, byte: u8) !void {
        try writer.writeByte(byte);
        last_byte.* = byte;
    }

    fn consumeMarkerCandidate(self: *Reader, writer: *Io.Writer, last_byte: *?u8) !bool {
        const prefix = self.reader.peek(marker.len) catch |err| switch (err) {
            error.EndOfStream => return false,
            else => return err,
        };
        if (!mem.eql(u8, prefix, marker)) return false;

        var line_buf: [marker_candidate_max]u8 = undefined;
        var line_len: usize = 0;

        while (true) {
            const byte = self.reader.takeByte() catch |err| switch (err) {
                error.EndOfStream => {
                    if (markerName(line_buf[0..line_len])) |name| {
                        try self.setPendingName(name);
                        return true;
                    }
                    try writeAndNote(writer, last_byte, line_buf[0..line_len]);
                    return false;
                },
                else => return err,
            };

            if (byte == '\n') {
                if (markerName(line_buf[0..line_len])) |name| {
                    try self.setPendingName(name);
                    return true;
                }
                try writeAndNote(writer, last_byte, line_buf[0..line_len]);
                try writeByteAndNote(writer, last_byte, '\n');
                return false;
            }

            if (line_len == line_buf.len) {
                try writeAndNote(writer, last_byte, line_buf[0..line_len]);
                try writeByteAndNote(writer, last_byte, byte);
                _ = self.reader.streamDelimiter(writer, '\n') catch |err| switch (err) {
                    error.EndOfStream => {
                        try writeByteAndNote(writer, last_byte, '\n');
                        return false;
                    },
                    else => return err,
                };
                try writeByteAndNote(writer, last_byte, '\n');
                return false;
            }

            line_buf[line_len] = byte;
            line_len += 1;
        }
    }

    fn setPendingName(self: *Reader, name: []const u8) !void {
        if (name.len > self.pending_name_buf.len) return error.NameTooLong;
        @memcpy(self.pending_name_buf[0..name.len], name);
        self.pending_name = self.pending_name_buf[0..name.len];
    }
};

pub const Entry = struct {
    /// Valid until this entry is consumed.
    name: []const u8,
    iterator: *Reader,

    pub fn writeTo(self: Entry, writer: *Io.Writer) !void {
        try self.iterator.writeEntry(writer);
    }
};

fn markerName(line_data: []const u8) ?[]const u8 {
    var line = mem.trimEnd(u8, line_data, "\r\n");

    if (!mem.startsWith(u8, line, marker)) return null;
    if (line.len < marker.len + marker_end.len) return null;
    if (!mem.endsWith(u8, line, marker_end)) return null;

    const raw_name = line[marker.len .. line.len - marker_end.len];
    const name = mem.trim(u8, raw_name, &std.ascii.whitespace);
    if (name.len == 0) return null;

    return name;
}

fn writeFixedNl(writer: *Io.Writer, data: []const u8) !void {
    try writer.writeAll(data);
    if (data.len > 0 and !mem.endsWith(u8, data, "\n")) try writer.writeByte('\n');
}

test "parse empty archive" {
    var archive = try parse(testing.allocator, "");
    defer archive.deinit(testing.allocator);

    try testing.expectEqualStrings("", archive.comment);
    try testing.expectEqual(@as(usize, 0), archive.files.len);
}

test "parse returns owned archive" {
    var archive = try parse(testing.allocator, "comment\n-- a.txt --\nhello\n-- b.txt --\nworld");
    defer archive.deinit(testing.allocator);

    try testing.expectEqualStrings("comment\n", archive.comment);
    try testing.expectEqual(@as(usize, 2), archive.files.len);
    try testing.expectEqualStrings("a.txt", archive.files[0].name);
    try testing.expectEqualStrings("hello\n", archive.files[0].data);
    try testing.expectEqualStrings("b.txt", archive.files[1].name);
    try testing.expectEqualStrings("world\n", archive.files[1].data);
}

test "format does not invent an empty comment line" {
    const archive: Archive = .{
        .comment = "",
        .files = &.{.{ .name = "a.txt", .data = "hello\n" }},
    };

    const out = try format(testing.allocator, archive);
    defer testing.allocator.free(out);

    try testing.expectEqualStrings("-- a.txt --\nhello\n", out);
}

test "format writes owned archive" {
    const archive: Archive = .{
        .comment = "comment\n",
        .files = &.{
            .{ .name = "a.txt", .data = "hello" },
            .{ .name = "b.txt", .data = "world\n" },
        },
    };

    const out = try format(testing.allocator, archive);
    defer testing.allocator.free(out);

    try testing.expectEqualStrings(
        "comment\n-- a.txt --\nhello\n-- b.txt --\nworld\n",
        out,
    );
}

test "Writer writes comments and entries" {
    const expected = "comment\n-- a.txt --\nhello\n-- b.txt --\nworld\n";

    var buf: [1024]u8 = undefined;
    var writer: Io.Writer = .fixed(&buf);
    var archive: Writer = .init(&writer);

    try archive.writeComment("comment");

    var first = try archive.beginEntry("a.txt");
    var first_reader: Io.Reader = .fixed("hello");
    try first.writeFrom(&first_reader);
    try first.finish();

    var second = try archive.beginEntry("b.txt");
    try second.writeAll("world\n");
    try second.finish();

    try testing.expectEqualStrings(expected, buf[0..writer.end]);
}

test "Reader streams entries from a reader" {
    var reader: Io.Reader = .fixed("comment\n-- a.txt --\nhello\n-- b.txt --\nworld\n");

    var entries: Reader = .init(&reader);

    const first = (try entries.next()).?;
    try testing.expectEqualStrings("a.txt", first.name);
    var first_buf: [128]u8 = undefined;
    var first_out: Io.Writer = .fixed(&first_buf);
    try first.writeTo(&first_out);
    try testing.expectEqualStrings("hello\n", first_buf[0..first_out.end]);

    const second = (try entries.next()).?;
    try testing.expectEqualStrings("b.txt", second.name);
    var second_buf: [128]u8 = undefined;
    var second_out: Io.Writer = .fixed(&second_buf);
    try second.writeTo(&second_out);
    try testing.expectEqualStrings("world\n", second_buf[0..second_out.end]);

    try testing.expect(try entries.next() == null);
}

test "marker names are trimmed and crlf is accepted" {
    var reader: Io.Reader = .fixed("-- \t a.txt  --\r\nbody\r\n");
    var entries: Reader = .init(&reader);

    const entry = (try entries.next()).?;
    try testing.expectEqualStrings("a.txt", entry.name);

    var buf: [128]u8 = undefined;
    var writer: Io.Writer = .fixed(&buf);
    try entry.writeTo(&writer);
    try testing.expectEqualStrings("body\r\n", buf[0..writer.end]);
}

test "marker must start a line" {
    var reader: Io.Reader = .fixed("not -- a.txt --\ncomment");
    var buf: [128]u8 = undefined;
    var comment_writer: Io.Writer = .fixed(&buf);

    var entries: Reader = .init(&reader);
    try entries.writeCommentTo(&comment_writer);

    try testing.expectEqualStrings("not -- a.txt --\ncomment\n", buf[0..comment_writer.end]);
    try testing.expect(try entries.next() == null);
}

test "Reader exposes archive comment" {
    var reader: Io.Reader = .fixed("comment\n-- a.txt --\nbody\n");
    var entries: Reader = .init(&reader);

    var comment_buf: [128]u8 = undefined;
    var comment_writer: Io.Writer = .fixed(&comment_buf);
    try entries.writeCommentTo(&comment_writer);
    try testing.expectEqualStrings("comment\n", comment_buf[0..comment_writer.end]);

    const entry = (try entries.next()).?;
    try testing.expectEqualStrings("a.txt", entry.name);
}

test "empty file entry" {
    var reader: Io.Reader = .fixed("-- empty.txt --\n-- next.txt --\ndata\n");
    var entries: Reader = .init(&reader);

    const empty = (try entries.next()).?;
    try testing.expectEqualStrings("empty.txt", empty.name);
    var empty_buf: [16]u8 = undefined;
    var empty_writer: Io.Writer = .fixed(&empty_buf);
    try empty.writeTo(&empty_writer);
    try testing.expectEqualStrings("", empty_buf[0..empty_writer.end]);

    const next = (try entries.next()).?;
    try testing.expectEqualStrings("next.txt", next.name);
}

test "long content line is not limited by max path bytes" {
    const long = "x" ** (fs.max_path_bytes + 128);
    var reader: Io.Reader = .fixed("-- long.txt --\n" ++ long ++ "\n");
    var entries: Reader = .init(&reader);

    const entry = (try entries.next()).?;
    try testing.expectEqualStrings("long.txt", entry.name);

    var out_buf: [long.len + 1]u8 = undefined;
    var out: Io.Writer = .fixed(&out_buf);
    try entry.writeTo(&out);
    try testing.expectEqualStrings(long ++ "\n", out_buf[0..out.end]);
}

test "false marker candidates remain content" {
    var reader: Io.Reader = .fixed(
        "-- a.txt --\n" ++
            "-- not a marker\n" ++
            "-- also-not-empty-name -- nope\n" ++
            "-- b.txt --\n" ++
            "body\n",
    );
    var entries: Reader = .init(&reader);

    const first = (try entries.next()).?;
    try testing.expectEqualStrings("a.txt", first.name);

    var out_buf: [128]u8 = undefined;
    var out: Io.Writer = .fixed(&out_buf);
    try first.writeTo(&out);
    try testing.expectEqualStrings(
        "-- not a marker\n" ++
            "-- also-not-empty-name -- nope\n",
        out_buf[0..out.end],
    );

    const second = (try entries.next()).?;
    try testing.expectEqualStrings("b.txt", second.name);
}

test "marker split across reader buffer boundary" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "split.txtar",
        .data = "comment\n-- a.txt --\nbody\n-- b.txt --\nnext\n",
        .flags = .{},
    });

    const file = try tmp.dir.openFile("split.txtar", .{});
    defer file.close();

    var reader_buf: [5]u8 = undefined;
    var file_reader = file.reader(&reader_buf);
    var entries: Reader = .init(&file_reader.interface);

    var comment_buf: [32]u8 = undefined;
    var comment_writer: Io.Writer = .fixed(&comment_buf);
    try entries.writeCommentTo(&comment_writer);
    try testing.expectEqualStrings("comment\n", comment_buf[0..comment_writer.end]);

    const first = (try entries.next()).?;
    try testing.expectEqualStrings("a.txt", first.name);
    var first_buf: [32]u8 = undefined;
    var first_writer: Io.Writer = .fixed(&first_buf);
    try first.writeTo(&first_writer);
    try testing.expectEqualStrings("body\n", first_buf[0..first_writer.end]);

    const second = (try entries.next()).?;
    try testing.expectEqualStrings("b.txt", second.name);
}
