const std = @import("std");
const merge = @import("merge_core");
const datatypes = @import("data_types");

pub const F = struct { index: usize = 0, file: [][:0]const u8 };

pub fn get_files_from_arg(args: std.process.Args, allocator: std.mem.Allocator) error{OutOfMemory}!datatypes.Iterator([:0]const u8) {
    const files_ptr = try allocator.create(F);
    files_ptr.* = .{ .file = undefined };
    files_ptr.file = try allocator.alloc([:0]const u8, args.vector.len - 1);
    for (args.vector[1..], files_ptr.file) |arg, *file| file.* = std.mem.sliceTo(arg, 0);
    return .{
        .context = files_ptr,
        ._next = struct {
            pub fn next(context: *anyopaque) ?[:0]const u8 {
                const _files_ptr: *F = @ptrCast(@alignCast(context));
                if (_files_ptr.index < _files_ptr.file.len) {
                    const temp = _files_ptr.file[_files_ptr.index];
                    _files_ptr.index += 1;
                    return temp;
                }
                return null;
            }
        }.next,
        ._deinit = struct {
            pub fn _de(context: *anyopaque, _allocator: std.mem.Allocator) void {
                const _files_ptr: *F = @ptrCast(@alignCast(context));
                _allocator.free(_files_ptr.file);
                _allocator.destroy(_files_ptr);
            }
        }._de,
    };
}

/// Resolves a file path to a full absolute path.
fn resolveFilePath(io: std.Io, file: [:0]const u8, allocator: std.mem.Allocator) ![]const u8 {
    if (file[0] == '/') {
        return try std.fmt.allocPrint(allocator, "{s}", .{file});
    } else {
        const path_sentinel = try std.Io.Dir.cwd().realPathFileAlloc(io, file, allocator);
        defer allocator.free(path_sentinel[0 .. path_sentinel.len + 1]);
        return try std.fmt.allocPrint(allocator, "{s}", .{path_sentinel});
    }
}

/// Io.Writer-based write function for StreamParser.
fn writerWriteFn(ctx: *anyopaque, bytes: []const u8) !void {
    const writer: *std.Io.Writer = @alignCast(@ptrCast(ctx));
    try writer.writeAll(bytes);
}

/// Process all files, writing merged GeoJSON to the output writer.
fn processAllFiles(
    files: []const [:0]const u8,
    out: *std.Io.Writer,
    allocator: std.mem.Allocator,
    io: std.Io,
) !void {
    const read_buffer = try allocator.alloc(u8, 65536);
    defer allocator.free(read_buffer);

    try merge.writeHeader(writerWriteFn, @ptrCast(out));

    var parser = merge.StreamParser.init(allocator, writerWriteFn, @ptrCast(out));
    defer parser.deinit();

    var total_count: usize = 0;

    for (files) |file| {
        const file_path = resolveFilePath(io, file, allocator) catch |err| {
            std.debug.print("Error resolving path for '{s}': {}\n", .{ file, err });
            continue;
        };
        defer allocator.free(file_path);

        std.debug.print("Reading: {s}\n", .{file_path});

        const file_obj = std.Io.Dir.openFileAbsolute(io, file_path, .{}) catch |err| {
            std.debug.print("  Error opening: {}\n", .{err});
            continue;
        };
        defer file_obj.close(io);

        var file_reader = file_obj.reader(io, read_buffer);

        const before = total_count;
        var buf: [65536]u8 = undefined;

        parser.reset();
        while (true) {
            const bytes_read = file_reader.interface.readSliceShort(&buf) catch |err| {
                std.debug.print("  Error reading: {}\n", .{err});
                break;
            };
            if (bytes_read == 0) break;
            parser.feed(buf[0..bytes_read]) catch |err| {
                std.debug.print("  Error parsing: {}\n", .{err});
                break;
            };
        }

        const file_count = parser.feature_count - before;
        total_count = parser.feature_count;
        std.debug.print("  Loaded {d} features\n", .{file_count});
    }

    try merge.writeFooter(writerWriteFn, @ptrCast(out));
    std.debug.print("Total: {d} features merged\n", .{total_count});
}

pub fn main(init_params: std.process.Init) !void {
    const allocator = init_params.gpa;
    const io = init_params.io;
    const args = init_params.minimal.args;

    // Parse arguments: -o <output_file> file1 file2 ...
    var output_path: ?[]const u8 = null;
    var file_paths = try std.ArrayList([:0]const u8).initCapacity(allocator, 0);
    defer file_paths.deinit(allocator);

    {
        var i: usize = 1;
        while (i < args.vector.len) : (i += 1) {
            const arg = std.mem.span(args.vector[i]);
            if (std.mem.eql(u8, arg, "-o") and i + 1 < args.vector.len) {
                i += 1;
                output_path = std.mem.span(args.vector[i]);
            } else {
                file_paths.append(allocator, arg) catch @panic("OOM");
            }
        }
    }

    var out_buf: [8192]u8 = undefined;
    if (output_path) |path| {
        var out_file = try std.Io.Dir.createFileAbsolute(io, path, .{});
        defer out_file.close(io);
        var fw = out_file.writer(io, &out_buf);
        try processAllFiles(file_paths.items, &fw.interface, allocator, io);
        try fw.end();
    } else {
        var fw = std.Io.File.stdout().writer(io, &out_buf);
        try processAllFiles(file_paths.items, &fw.interface, allocator, io);
        try fw.end();
    }
}
