const std = @import("std");

// ---------------------------------------------------------------------------
// Streaming JSON navigator state machine
// ---------------------------------------------------------------------------

const Nav = enum {
    root,          // navigating root object keys
    skip_value,    // skipping a non-features value's content
    features_arr,  // found "features" key, waiting for '['
    features,      // inside the features array
    feature,       // inside a feature object (tracking brace depth)
    done,          // finished processing
};

// Generic write function signature used by StreamParser.
// The context pointer carries either an Io.Writer or a raw buffer.
pub const WriteFn = *const fn (ctx: *anyopaque, bytes: []const u8) anyerror!void;

/// Streaming JSON parser that extracts features from a GeoJSON FeatureCollection.
///
/// States gracefully handle chunk boundaries – pass data incrementally via `feed()`.
/// Each complete feature triggers an immediate callback so no file-sized buffer is needed.
///
/// Memory usage (per parser instance):
///   - key_buf:      size of the longest object key (typically < 100 B)
///   - feature_buf:  size of the largest single feature
pub const StreamParser = struct {
    nav: Nav = .root,
    in_string: bool = false,
    escaped: bool = false,
    sv_depth: usize = 0,       // nesting depth while skipping a value
    f_depth: usize = 0,        // brace depth inside current feature
    key_buf: std.ArrayList(u8),
    feature_buf: std.ArrayList(u8),
    first_feature: bool,
    feature_count: usize,
    allocator: std.mem.Allocator,
    write_fn: WriteFn,
    write_ctx: *anyopaque,

    pub fn init(
        allocator: std.mem.Allocator,
        write_fn: WriteFn,
        write_ctx: *anyopaque,
    ) StreamParser {
        return .{
            .key_buf = std.ArrayList(u8).initCapacity(allocator, 64) catch @panic("OOM"),
            .feature_buf = std.ArrayList(u8).initCapacity(allocator, 1024) catch @panic("OOM"),
            .first_feature = true,
            .feature_count = 0,
            .allocator = allocator,
            .write_fn = write_fn,
            .write_ctx = write_ctx,
        };
    }

    pub fn deinit(self: *StreamParser) void {
        self.key_buf.deinit(self.allocator);
        self.feature_buf.deinit(self.allocator);
    }

    /// Reset parser state for processing a new file.
    pub fn reset(self: *StreamParser) void {
        self.nav = .root;
        self.in_string = false;
        self.escaped = false;
        self.sv_depth = 0;
        self.f_depth = 0;
        self.key_buf.clearRetainingCapacity();
        self.feature_buf.clearRetainingCapacity();
    }

    fn write(self: *StreamParser, bytes: []const u8) !void {
        try self.write_fn(self.write_ctx, bytes);
    }

    /// Feed a chunk of raw JSON bytes through the state machine.
    /// Features are written to the output callback as they are found.
    pub fn feed(self: *StreamParser, bytes: []const u8) !void {
        var i: usize = 0;
        while (i < bytes.len) {
            if (self.nav == .done) break;

            const c = bytes[i];

            // --- String handling (shared across all states) ---
            if (self.in_string) {
                if (self.escaped) {
                    self.escaped = false;
                } else if (c == '\\') {
                    self.escaped = true;
                } else if (c == '"') {
                    self.in_string = false;
                    if (self.nav == .root) {
                        const is_features = std.mem.eql(u8, self.key_buf.items, "features");
                        self.key_buf.clearRetainingCapacity();
                        if (is_features) {
                            self.nav = .features_arr;
                        } else {
                            self.nav = .skip_value;
                            self.sv_depth = 0;
                        }
                    }
                }
                if (self.nav == .feature) {
                    try self.feature_buf.append(self.allocator, c);
                } else if (self.nav == .root) {
                    try self.key_buf.append(self.allocator, c);
                }
                i += 1;
                continue;
            }

            // --- Non-string character handling ---
            switch (c) {
                '"' => {
                    self.in_string = true;
                    self.escaped = false;
                    if (self.nav == .feature) try self.feature_buf.append(self.allocator, '"');
                },
                ':' => {
                    if (self.nav == .feature) try self.feature_buf.append(self.allocator, ':');
                },
                ',' => {
                    if (self.nav == .skip_value and self.sv_depth == 0) {
                        self.nav = .root;
                        i += 1;
                        continue;
                    }
                    if (self.nav == .feature) try self.feature_buf.append(self.allocator, ',');
                },
                '{' => {
                    switch (self.nav) {
                        .skip_value => self.sv_depth += 1,
                        .features => {
                            self.nav = .feature;
                            self.f_depth = 1;
                            self.feature_buf.clearRetainingCapacity();
                            try self.feature_buf.append(self.allocator, '{');
                        },
                        .feature => {
                            self.f_depth += 1;
                            try self.feature_buf.append(self.allocator, '{');
                        },
                        else => {},
                    }
                },
                '}' => {
                    if (self.nav == .skip_value) {
                        if (self.sv_depth == 0) {
                            self.nav = .root;
                            i += 1;
                            continue;
                        } else {
                            self.sv_depth -= 1;
                        }
                    } else if (self.nav == .feature) {
                        self.f_depth -= 1;
                        try self.feature_buf.append(self.allocator, '}');
                        if (self.f_depth == 0) {
                            // Complete feature – write it out
                            if (!self.first_feature) try self.write(",\n");
                            self.first_feature = false;
                            try self.write(self.feature_buf.items);
                            self.feature_count += 1;
                            self.nav = .features;
                        }
                    } else if (self.nav == .root) {
                        self.nav = .done;
                    }
                },
                '[' => {
                    switch (self.nav) {
                        .skip_value => self.sv_depth += 1,
                        .features_arr => self.nav = .features,
                        .feature => try self.feature_buf.append(self.allocator, '['),
                        else => {},
                    }
                },
                ']' => {
                    if (self.nav == .skip_value) {
                        if (self.sv_depth == 0) {
                            self.nav = .root;
                            i += 1;
                            continue;
                        } else {
                            self.sv_depth -= 1;
                        }
                    } else if (self.nav == .feature) {
                        try self.feature_buf.append(self.allocator, ']');
                    } else if (self.nav == .features) {
                        self.nav = .root;
                    }
                },
                else => {
                    if (self.nav == .feature) try self.feature_buf.append(self.allocator, c);
                },
            }

            i += 1;
        }
    }
};

// ---------------------------------------------------------------------------
// High-level merge helpers
// ---------------------------------------------------------------------------

pub fn writeHeader(write_fn: WriteFn, write_ctx: *anyopaque) !void {
    try write_fn(write_ctx, "{\"type\":\"FeatureCollection\",\"features\":[\n");
}

pub fn writeFooter(write_fn: WriteFn, write_ctx: *anyopaque) !void {
    try write_fn(write_ctx, "]}\n");
}

/// Process a single GeoJSON file (raw bytes) through the parser.
/// Extracts and writes all features to the output.
pub fn processFileBytes(data: []const u8, parser: *StreamParser) !void {
    try parser.feed(data);
}

/// Merge multiple GeoJSON files into one FeatureCollection.
///
/// `data`  – concatenated raw bytes of all files.
/// `sizes` – byte length of each file (must sum to `data.len`).
///
/// Returns the total number of features written.
pub fn mergeMultipleFiles(
    data: []const u8,
    sizes: []const usize,
    write_fn: WriteFn,
    write_ctx: *anyopaque,
    allocator: std.mem.Allocator,
) !usize {
    try writeHeader(write_fn, write_ctx);

    var parser = StreamParser.init(allocator, write_fn, write_ctx);
    defer parser.deinit();

    var offset: usize = 0;
    for (sizes) |size| {
        parser.reset();
        const file_data = data[offset..][0..size];
        offset += size;
        try processFileBytes(file_data, &parser);
    }

    try writeFooter(write_fn, write_ctx);

    return parser.feature_count;
}
