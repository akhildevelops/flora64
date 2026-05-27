const std = @import("std");
const merge = @import("merge_core");

// Dummy context pointer – wasmWrite ignores it.
var wasm_ctx: u8 = 0;

// Output buffer tracking – written into by wasmWrite.
var output_buf: []u8 = undefined;
var output_pos: usize = 0;

/// Write callback for StreamParser – appends bytes to the pre-allocated output buffer.
fn wasmWrite(_ctx: *anyopaque, bytes: []const u8) !void {
    _ = _ctx;
    if (output_pos + bytes.len > output_buf.len) {
        return error.NoSpaceLeft;
    }
    @memcpy(output_buf[output_pos..][0..bytes.len], bytes);
    output_pos += bytes.len;
}

/// Merge multiple GeoJSON files into a single FeatureCollection.
///
/// All pointers are WASM linear-memory addresses.  The JS caller copies file
/// data and the sizes array into the shared memory before calling this function.
///
/// # Parameters
///
///   `data_ptr`   – concatenated raw bytes of all files.
///   `sizes_ptr`  – array of `count` `usize` values, each being the byte-length
///                   of one file.  Sizes must sum to the total bytes at data_ptr.
///   `count`      – number of files.
///   `output_ptr` – pre-allocated output buffer (must be ≥ sum of inputs).
///   `output_len` – capacity of output_ptr.
///
/// # Returns
///
///   Number of bytes written to output_ptr.  0 on error.
///
export fn merge_geojson(
    data_ptr: [*]const u8,
    sizes_ptr: [*]const usize,
    count: usize,
    output_ptr: [*]u8,
    output_len: usize,
) usize {
    // Arena allocator – backed by page_allocator which uses memory.grow() on WASM.
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Reconstruct Zig slices from raw pointers.
    const sizes = sizes_ptr[0..count];

    var total_data: usize = 0;
    for (sizes) |s| total_data += s;
    const data = data_ptr[0..total_data];

    output_buf = output_ptr[0..output_len];
    output_pos = 0;

    _ = merge.mergeMultipleFiles(data, sizes, wasmWrite, &wasm_ctx, allocator) catch {
        return 0;
    };

    return output_pos;
}
