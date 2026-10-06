//! The end-to-end harness's Linux side, which reads `/proc`.

const std = @import("std");
const sys = @import("kiwa_sys");
const e2e = @import("../e2e.zig");

/// Every process in `/proc`.
pub const Processes = struct {
    io: std.Io,
    proc: std.Io.Dir,
    it: std.Io.Dir.Iterator,

    pub fn init(gpa: std.mem.Allocator, io: std.Io) !Processes {
        _ = gpa;
        const proc = try std.Io.Dir.openDirAbsolute(io, "/proc", .{ .iterate = true });
        return .{ .io = io, .proc = proc, .it = proc.iterate() };
    }

    pub fn deinit(ps: *Processes) void {
        ps.proc.close(ps.io);
    }

    /// The next process, read into `buf`. Its environment is empty when
    /// it cannot be read.
    pub fn next(ps: *Processes, buf: []u8) !?e2e.Process {
        while (try ps.it.next(ps.io)) |entry| {
            const pid = std.fmt.parseInt(sys.pid_t, entry.name, 10) catch continue;
            var path: [64]u8 = undefined;
            const half = buf.len / 2;
            const argv = ps.proc.readFile(ps.io, try std.fmt.bufPrint(&path, "{d}/cmdline", .{pid}), buf[0..half]) catch continue;
            const env = ps.proc.readFile(ps.io, try std.fmt.bufPrint(&path, "{d}/environ", .{pid}), buf[half..]) catch "";
            return .{ .pid = pid, .argv = argv, .env = env };
        }
        return null;
    }
};

pub fn sample(io: std.Io, pid: sys.pid_t) !e2e.Sample {
    var path: [64]u8 = undefined;
    var buf: [4096]u8 = undefined;
    var s: e2e.Sample = .{ .switches = 0, .ticks = 0 };
    const status = try std.Io.Dir.cwd().readFile(io, try std.fmt.bufPrint(&path, "/proc/{d}/status", .{pid}), &buf);
    var lines = std.mem.splitScalar(u8, status, '\n');
    while (lines.next()) |line| {
        inline for (.{ "voluntary_ctxt_switches:", "nonvoluntary_ctxt_switches:" }) |key| {
            if (std.mem.startsWith(u8, line, key)) {
                s.switches += try std.fmt.parseInt(u64, std.mem.trim(u8, line[key.len..], " \t"), 10);
            }
        }
    }
    const stat = try std.Io.Dir.cwd().readFile(io, try std.fmt.bufPrint(&path, "/proc/{d}/stat", .{pid}), &buf);
    // Fields after the parenthesized command: state is field 3, utime 14, stime 15.
    var fields = std.mem.tokenizeScalar(u8, stat[std.mem.lastIndexOfScalar(u8, stat, ')').? + 2 ..], ' ');
    var i: usize = 3;
    while (fields.next()) |f| : (i += 1) {
        if (i == 14 or i == 15) s.ticks += try std.fmt.parseInt(u64, f, 10);
    }
    return s;
}

/// Whether the process has exited. The server is a child of init, so it
/// may linger as a zombie, which has released everything; only its
/// parent's wait is left.
pub fn exited(io: std.Io, pid: sys.pid_t) bool {
    var path: [32]u8 = undefined;
    const p = std.fmt.bufPrint(&path, "/proc/{d}/stat", .{pid}) catch unreachable;
    var buf: [512]u8 = undefined;
    const stat = std.Io.Dir.cwd().readFile(io, p, &buf) catch return true;
    return std.mem.indexOf(u8, stat, ") Z ") != null;
}
