const std = @import("std");
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
/// Always returns a plain []const u8 (no sentinel) for uniform deallocation.
fn resolveFilePath(io: std.Io, file: [:0]const u8, allocator: std.mem.Allocator) ![]const u8 {
    if (file[0] == '/') {
        return try std.fmt.allocPrint(allocator, "{s}", .{file});
    } else {
        const path_sentinel = try std.Io.Dir.cwd().realPathFileAlloc(io, file, allocator);
        defer allocator.free(path_sentinel[0..path_sentinel.len + 1]);
        return try std.fmt.allocPrint(allocator, "{s}", .{path_sentinel});
    }
}

/// Streaming JSON navigator state machine.
/// Reads a GeoJSON file chunk-by-chunk, extracting individual features
/// from the "features" array and writing each one to stdout immediately.
/// Memory usage is bounded: read_buffer (64 KB) + largest feature + small overhead.
const Nav = enum {
    root,           // navigating root object keys
    skip_value,     // skipping a non-features value's content
    features_arr,   // found "features" key, waiting for '['
    features,       // inside the features array
    feature,        // inside a feature object (tracking brace depth)
    done,           // finished processing
};

/// Processes a single GeoJSON file from a file_reader in a streaming fashion.
/// Extracts each feature from the "features" array and writes it to stdout.
fn processFile(
    file_reader: *std.Io.File.Reader,
    out: *std.Io.Writer,
    first_feature: *bool,
    total_count: *usize,
    allocator: std.mem.Allocator,
) !void {
    var buf: [65536]u8 = undefined;

    var nav: Nav = .root;
    var in_string = false;
    var escaped = false;
    var sv_depth: usize = 0; // nesting depth when skipping a value
    var f_depth: usize = 0; // brace depth inside current feature

    var key_buf = std.ArrayList(u8).initCapacity(allocator, 0) catch @panic("OOM");
    defer key_buf.deinit(allocator);
    var feature_buf = std.ArrayList(u8).initCapacity(allocator, 0) catch @panic("OOM");
    defer feature_buf.deinit(allocator);

    while (true) {
        const bytes_read = try file_reader.interface.readSliceShort(&buf);
        if (bytes_read == 0) break;

        var i: usize = 0;
        while (i < bytes_read) {
            if (nav == .done) break;

            const c = buf[i];

            // --- String handling (shared across all states) ---
            if (in_string) {
                if (escaped) {
                    escaped = false;
                } else if (c == '\\') {
                    escaped = true;
                } else if (c == '"') {
                    in_string = false;
                    if (nav == .root) {
                        // End of a key — check if it's "features"
                        const is_features = std.mem.eql(u8, key_buf.items, "features");
                        key_buf.clearRetainingCapacity();
                        if (is_features) {
                            nav = .features_arr;
                        } else {
                            nav = .skip_value;
                            sv_depth = 0;
                        }
                    }
                    // For .feature: the '"' is handled in the non-string switch below
                    // because we're exiting in_string here
                }
                if (nav == .feature) {
                    try feature_buf.append(allocator, c);
                } else if (nav == .root) {
                    try key_buf.append(allocator, c);
                }
                i += 1;
                continue;
            }

            // --- Non-string character handling ---
            switch (c) {
                '"' => {
                    in_string = true;
                    escaped = false;
                    if (nav == .feature) try feature_buf.append(allocator, '"');
                },
                ':' => {
                    if (nav == .feature) try feature_buf.append(allocator, ':');
                },
                ',' => {
                    if (nav == .skip_value and sv_depth == 0) {
                        nav = .root;
                        continue; // re-process comma in .root state (ignored)
                    }
                    if (nav == .feature) try feature_buf.append(allocator, ',');
                },
                '{' => {
                    switch (nav) {
                        .skip_value => sv_depth += 1,
                        .features => {
                            nav = .feature;
                            f_depth = 1;
                            feature_buf.clearRetainingCapacity();
                            try feature_buf.append(allocator, '{');
                        },
                        .feature => {
                            f_depth += 1;
                            try feature_buf.append(allocator, '{');
                        },
                        else => {},
                    }
                },
                '}' => {
                    if (nav == .skip_value) {
                        if (sv_depth == 0) {
                            nav = .root;
                            continue; // re-process '}' in .root
                        } else {
                            sv_depth -= 1;
                        }
                    } else if (nav == .feature) {
                        f_depth -= 1;
                        try feature_buf.append(allocator, '}');
                        if (f_depth == 0) {
                            // Complete feature — write to stdout
                            if (!first_feature.*) try out.writeAll(",\n");
                            first_feature.* = false;
                            try out.writeAll(feature_buf.items);
                            total_count.* += 1;
                            nav = .features;
                        }
                    } else if (nav == .root) {
                        nav = .done;
                    }
                },
                '[' => {
                    switch (nav) {
                        .skip_value => sv_depth += 1,
                        .features_arr => nav = .features,
                        .feature => try feature_buf.append(allocator, '['),
                        else => {},
                    }
                },
                ']' => {
                    if (nav == .skip_value) {
                        if (sv_depth == 0) {
                            nav = .root;
                            continue; // re-process ']' in .root (ignored)
                        } else {
                            sv_depth -= 1;
                        }
                    } else if (nav == .feature) {
                        try feature_buf.append(allocator, ']');
                    } else if (nav == .features) {
                        nav = .root; // resume root to handle any keys after features
                    }
                },
                else => {
                    if (nav == .feature) try feature_buf.append(allocator, c);
                },
            }

            i += 1;
        }
    }
}

pub fn main(init_params: std.process.Init) !void {
    const allocator = init_params.gpa;
    const io = init_params.io;
    var file_names = try get_files_from_arg(init_params.minimal.args, allocator);
    defer file_names.deinit(allocator);

    const read_buffer = try allocator.alloc(u8, 65536);
    defer allocator.free(read_buffer);

    // Streaming stdout writer
    var stdout_buf: [8192]u8 = undefined;
    var fw = std.Io.File.stdout().writer(io, &stdout_buf);
    const out = &fw.interface;

    try out.writeAll("{\"type\":\"FeatureCollection\",\"features\":[\n");

    var first_feature = true;
    var total_count: usize = 0;

    while (file_names.next()) |file| {
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
        processFile(&file_reader, out, &first_feature, &total_count, allocator) catch |err| {
            std.debug.print("  Error processing: {}\n", .{err});
            continue;
        };
        const file_count = total_count - before;
        std.debug.print("  Loaded {d} features\n", .{file_count});
    }

    try out.writeAll("]}\n");
    try fw.end();
    std.debug.print("Total: {d} features merged\n", .{total_count});
}
