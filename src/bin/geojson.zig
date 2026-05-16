const flora64 = @import("flora64");
const datatypes = @import("data_types");
const std = @import("std");

pub const F = struct { index: usize = 0, file: [][:0]const u8 };
pub fn get_files_from_arg(args: std.process.Args, allocator: std.mem.Allocator) error{OutOfMemory}!datatypes.Iterator([:0]const u8) {
    const files_ptr = try allocator.create(F);
    files_ptr.* = .{ .file = undefined };
    files_ptr.file = try allocator.alloc([:0]const u8, args.vector.len);
    var arg_iterator = args.iterate();
    _ = arg_iterator.next();
    for (args.vector, files_ptr.file) |arg, *file| file.* = std.mem.sliceTo(arg, 0);
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
const Context = struct { io: std.Io, allocator: std.mem.Allocator };
pub fn main(init_params: std.process.Init) !void {
    const allocator = init_params.gpa;
    const io = init_params.io;
    var files = (try get_files_from_arg(init_params.minimal.args, allocator)).mut().map(
        (std.Io.Dir.RealPathFileAllocError)!datatypes.OwnedString,
        Context,
        .{ .allocator = allocator, .io = io },
        struct {
            pub fn _f(context: Context, file: [:0]const u8) !datatypes.OwnedString {
                if (file[0] == '/') {
                    return .{ .string = try std.fmt.allocPrint(context.allocator, "{s}", .{file}) };
                } else {
                    const path = try std.Io.Dir.cwd().realPathFileAlloc(context.io, file, context.allocator);
                    return .{ .string = path };
                }
            }
        }._f,
    );
    defer files.deinit(allocator);
    while (files.next()) |file| {
        _ = std.debug.print("{s}\n", .{(try file).string});
        (try file).deinit(allocator);
    }
}
