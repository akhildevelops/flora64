const std = @import("std");
pub const OwnedString = struct {
    string: []const u8,
    pub fn deinit(self: @This(), allocator: std.mem.Allocator) void {
        allocator.free(self.string);
    }
};

pub fn Vec(T: type) type {
    return struct {
        inner: []T,
        index: 0,
    };
}
pub fn Iterator(T: type) type {
    return struct {
        context: *anyopaque,
        _next: *const fn (*anyopaque) ?T,
        _deinit: *const fn (*anyopaque, allocator: std.mem.Allocator) void = struct {
            pub fn _de(_: *anyopaque, _: std.mem.Allocator) void {}
        }._de,
        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            self._deinit(self.context, allocator);
        }
        pub fn next(self: *@This()) ?T {
            return self._next(self.context);
        }
        pub fn mut(self: *const @This()) *@This() {
            return @constCast(self);
        }
        pub fn map(self: *@This(), U: type, Context: type, context: Context, transform: *const fn (Context, T) U, allocator: std.mem.Allocator) error{OutOfMemory}!Iterator(U) {
            const MapContext = struct {
                parent: *Iterator(T),
                context: Context,
                transform: *const fn (Context, T) U,
            };
            const map_ctx = try allocator.create(MapContext);
            map_ctx.* = .{
                .parent = self,
                .context = context,
                .transform = transform,
            };
            return .{
                .context = map_ctx,
                ._next = struct {
                    pub fn _next(_context: *anyopaque) ?U {
                        const map_c: *MapContext = @ptrCast(@alignCast(_context));
                        const value = map_c.parent.next() orelse return null;
                        return map_c.transform(map_c.context, value);
                    }
                }._next,
                ._deinit = struct {
                    pub fn _de(_context: *anyopaque, _allocator: std.mem.Allocator) void {
                        const map_c: *MapContext = @ptrCast(@alignCast(_context));
                        map_c.parent.deinit(_allocator);
                        _allocator.destroy(map_c);
                    }
                }._de,
            };
        }
    };
}
