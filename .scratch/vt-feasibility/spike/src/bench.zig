const std = @import("std");
const vt = @import("ghostty-vt");

fn nowNs() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.next();
    const which = args.next() orelse "init";
    const sb: usize = try std.fmt.parseInt(usize, args.next() orelse "0", 10);
    const lines: usize = try std.fmt.parseInt(usize, args.next() orelse "30000", 10);
    const gpa: std.mem.Allocator = if (std.mem.eql(u8, which, "c")) std.heap.c_allocator else if (std.mem.eql(u8, which, "smp")) std.heap.smp_allocator else if (std.mem.eql(u8, which, "page")) std.heap.page_allocator else init.gpa;
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(gpa);
    var line: [32]u8 = undefined;
    for (1..lines + 1) |i| try data.appendSlice(gpa, try std.fmt.bufPrint(&line, "{d}\r\n", .{i}));
    var t: vt.Terminal = try .init(init.io, gpa, .{ .cols = 100, .rows = 40, .max_scrollback_bytes = sb });
    defer t.deinit(gpa);
    var s = t.vtStream();
    defer s.deinit();
    const t0 = nowNs();
    var off: usize = 0;
    while (off < data.items.len) : (off += 16384) s.nextSlice(data.items[off..@min(off + 16384, data.items.len)]);
    const dt = nowNs() - t0;
    std.debug.print("alloc={s} scrollback={d} bytes={d} time={d} ms => {d:.2} MB/s rows={d}\n", .{ which, sb, data.items.len, dt / 1_000_000, @as(f64, @floatFromInt(data.items.len)) / @as(f64, @floatFromInt(dt)) * 1000.0, t.screens.active.pages.total_rows });
}
