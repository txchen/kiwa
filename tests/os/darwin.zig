//! The end-to-end harness's macOS side, which uses libproc and `sysctl`.
//! Declarations match the macOS SDK headers (`libproc.h`,
//! `sys/proc_info.h`, `sys/sysctl.h`).

const std = @import("std");
const sys = @import("kiwa_sys");
const e2e = @import("../e2e.zig");

const CTL_KERN = 1;
const KERN_PROCARGS2 = 49;
const PROC_PIDTASKINFO = 4;

extern "c" fn proc_listallpids(buffer: ?*anyopaque, buffersize: c_int) c_int;
extern "c" fn proc_pidinfo(pid: c_int, flavor: c_int, arg: u64, buffer: ?*anyopaque, buffersize: c_int) c_int;

/// `struct proc_taskinfo`.
const TaskInfo = extern struct {
    virtual_size: u64,
    resident_size: u64,
    total_user: u64,
    total_system: u64,
    threads_user: u64,
    threads_system: u64,
    policy: i32,
    faults: i32,
    pageins: i32,
    cow_faults: i32,
    messages_sent: i32,
    messages_received: i32,
    syscalls_mach: i32,
    syscalls_unix: i32,
    csw: i32,
    threadnum: i32,
    numrunning: i32,
    priority: i32,
};

comptime {
    std.debug.assert(@sizeOf(TaskInfo) == 96);
    std.debug.assert(@offsetOf(TaskInfo, "csw") == 80);
}

/// Every process `proc_listallpids` lists.
pub const Processes = struct {
    gpa: std.mem.Allocator,
    buf: []sys.pid_t,
    pids: []const sys.pid_t,
    i: usize = 0,

    pub fn init(gpa: std.mem.Allocator, io: std.Io) !Processes {
        _ = io;
        const count = proc_listallpids(null, 0);
        if (count <= 0) return error.ProcListFailed;
        // Room for processes that start between the two calls.
        const buf = try gpa.alloc(sys.pid_t, @as(usize, @intCast(count)) + 64);
        errdefer gpa.free(buf);
        const n = proc_listallpids(buf.ptr, @intCast(buf.len * @sizeOf(sys.pid_t)));
        if (n <= 0) return error.ProcListFailed;
        return .{ .gpa = gpa, .buf = buf, .pids = buf[0..@min(@as(usize, @intCast(n)), buf.len)] };
    }

    pub fn deinit(ps: *Processes) void {
        ps.gpa.free(ps.buf);
    }

    /// The next process whose arguments this user may read, read into `buf`.
    pub fn next(ps: *Processes, buf: []u8) !?e2e.Process {
        while (ps.i < ps.pids.len) {
            const pid = ps.pids[ps.i];
            ps.i += 1;
            var mib = [_]c_int{ CTL_KERN, KERN_PROCARGS2, pid };
            var size: usize = buf.len;
            if (std.c.sysctl(&mib, mib.len, buf.ptr, &size, null, 0) != 0) continue;
            return parseProcArgs(pid, buf[0..size]) orelse continue;
        }
        return null;
    }
};

/// Splits `KERN_PROCARGS2` output: `argc`, the executable path, NUL
/// padding, `argc` arguments, then the environment up to an empty string.
fn parseProcArgs(pid: sys.pid_t, data: []const u8) ?e2e.Process {
    if (data.len < @sizeOf(c_int)) return null;
    const argc: usize = @intCast(std.mem.readInt(c_int, data[0..@sizeOf(c_int)], .little));
    var at = std.mem.indexOfScalarPos(u8, data, @sizeOf(c_int), 0) orelse return null;
    while (at < data.len and data[at] == 0) at += 1;
    const argv_start = at;
    for (0..argc) |_| {
        at = (std.mem.indexOfScalarPos(u8, data, at, 0) orelse return null) + 1;
    }
    const env_start = at;
    while (at < data.len and data[at] != 0) {
        at = (std.mem.indexOfScalarPos(u8, data, at, 0) orelse data.len - 1) + 1;
    }
    return .{ .pid = pid, .argv = data[argv_start..env_start], .env = data[env_start..at] };
}

/// Context switches, and user plus system time in nanoseconds as the ticks.
pub fn sample(io: std.Io, pid: sys.pid_t) !e2e.Sample {
    _ = io;
    var ti: TaskInfo = undefined;
    if (proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &ti, @sizeOf(TaskInfo)) != @sizeOf(TaskInfo)) return error.TaskInfoFailed;
    return .{ .switches = @intCast(ti.csw), .ticks = ti.total_user + ti.total_system };
}

/// Whether the process has exited. launchd, the server's parent, reaps it.
pub fn exited(io: std.Io, pid: sys.pid_t) bool {
    _ = io;
    const rc = std.c.kill(pid, @enumFromInt(0));
    return rc != 0 and std.c.errno(rc) == .SRCH;
}
