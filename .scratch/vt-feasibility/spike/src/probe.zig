const std = @import("std");
const vt = @import("ghostty-vt");

const Handler = vt.TerminalStream.Handler;

var replies: [4096]u8 = undefined;
var replies_len: usize = 0;
var titles: usize = 0;
var pwds: usize = 0;
var bells: usize = 0;

fn writePty(_: *Handler, data: []const u8) void {
    @memcpy(replies[replies_len..][0..data.len], data);
    replies_len += data.len;
}
fn da(_: *Handler) vt.device_attributes.Attributes {
    return .{};
}
fn titleChanged(_: *Handler) void {
    titles += 1;
}
fn pwdChanged(_: *Handler) void {
    pwds += 1;
}
fn bell(_: *Handler) void {
    bells += 1;
}

fn nowNs() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

fn check(ok: bool, what: []const u8) void {
    std.debug.print("{s} {s}\n", .{ if (ok) "PASS" else "FAIL", what });
}

fn cellCp(rs: *const vt.RenderState, x: usize, y: usize) u21 {
    const cells = rs.row_data.items(.cells)[y];
    const raw = cells.items(.raw)[x];
    return switch (raw.content_tag) {
        .codepoint, .codepoint_grapheme => raw.content.codepoint.data,
        else => 0,
    };
}

fn dirtyRows(rs: *const vt.RenderState, buf: []usize) []usize {
    var n: usize = 0;
    for (rs.row_data.items(.dirty), 0..) |d, y| {
        if (d) {
            buf[n] = y;
            n += 1;
        }
    }
    return buf[0..n];
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var t: vt.Terminal = try .init(init.io, gpa, .{ .cols = 20, .rows = 6, .max_scrollback_bytes = 64 * 1024 });
    defer t.deinit(gpa);

    var handler: Handler = .init(&t);
    handler.effects.write_pty = &writePty;
    handler.effects.device_attributes = &da;
    handler.effects.title_changed = &titleChanged;
    handler.effects.pwd_changed = &pwdChanged;
    handler.effects.bell = &bell;
    var stream: vt.TerminalStream = .init(.{ .allocator = gpa, .handler = handler });
    defer stream.deinit();

    // Split SGR, split UTF-8, and a wide CJK char across separate feeds.
    for ([_][]const u8{ "\x1b[3", "1mR", "\x1b[0m", "\xc3", "\xa9", "\xe4\xb8", "\xad", "!" }) |chunk| stream.nextSlice(chunk);

    var rs: vt.RenderState = .empty;
    defer rs.deinit(gpa);
    try rs.update(gpa, &t);

    const cells0 = rs.row_data.items(.cells)[0];
    const st0 = cells0.items(.style)[0];
    check(cellCp(&rs, 0, 0) == 'R', "split CSI then text: R at (0,0)");
    check(cells0.items(.raw)[0].style_id != 0 and st0.fg_color == .palette and st0.fg_color.palette == 1, "split SGR 31 survives feed boundary (fg palette 1)");
    check(cellCp(&rs, 1, 0) == 0xe9, "split 2-byte UTF-8 decoded as U+00E9");
    check(cellCp(&rs, 2, 0) == 0x4e2d and cells0.items(.raw)[2].wide == .wide, "split 3-byte UTF-8 CJK is wide");
    check(cells0.items(.raw)[3].wide == .spacer_tail, "wide char spacer tail at col 3");
    check(cellCp(&rs, 4, 0) == '!', "next char after wide at col 4");
    std.debug.print("     cursor active=({d},{d}) rs.dirty={s}\n", .{ rs.cursor.active.x, rs.cursor.active.y, @tagName(rs.dirty) });

    // Steady state: no change -> no dirty rows.
    rs.clean();
    try rs.update(gpa, &t);
    var dbuf: [256]usize = undefined;
    check(rs.dirty == .false and dirtyRows(&rs, &dbuf).len == 0, "no input -> RenderState not dirty");

    // One-cell update on row 3 -> only row 3 dirty.
    rs.clean();
    stream.nextSlice("\x1b[4;5HX");
    try rs.update(gpa, &t);
    const d1 = dirtyRows(&rs, &dbuf);
    std.debug.print("     after one-cell write: rs.dirty={s} rows={any}\n", .{ @tagName(rs.dirty), d1 });
    check(rs.dirty == .partial and d1.len == 2 and d1[0] == 0 and d1[1] == 3, "cursor jump + one-cell write dirties only the old cursor row and the target row");

    // Spinner-like overwrite at the same cell.
    rs.clean();
    stream.nextSlice("\x1b[4;5H/");
    try rs.update(gpa, &t);
    const d2 = dirtyRows(&rs, &dbuf);
    check(rs.dirty == .partial and d2.len == 1, "spinner overwrite is a single dirty row");

    // Replies routed through write_pty.
    replies_len = 0;
    stream.nextSlice("\x1b[c");
    std.debug.print("     DA1 reply: {any}\n", .{replies[0..replies_len]});
    check(replies_len > 0 and replies[replies_len - 1] == 'c', "DA1 reply delivered via write_pty");
    replies_len = 0;
    stream.nextSlice("\x1b[6n");
    std.debug.print("     DSR6 reply: {s}\n", .{replies[1..replies_len]});
    check(std.mem.eql(u8, replies[0..replies_len], "\x1b[4;6R"), "DSR 6 cursor report = ESC[4;6R");
    replies_len = 0;
    stream.nextSlice("\x1b[?1049$p");
    std.debug.print("     DECRQM 1049 reply: {s}\n", .{replies[1..replies_len]});
    check(replies_len > 0, "DECRQM reply delivered");

    // Title, pwd, bell events.
    stream.nextSlice("\x1b]0;my-title\x07\x1b]7;file://host/tmp/kiwa\x07\x07");
    check(titles == 1 and std.mem.eql(u8, t.getTitle() orelse "", "my-title"), "OSC 0 title event + getTitle");
    check(pwds == 1, "OSC 7 pwd event");
    std.debug.print("     pwd={s}\n", .{t.getPwd() orelse "(null)"});
    check(bells == 1, "BEL event");

    // Alternate screen enter/exit -> full dirty and screen key changes.
    rs.clean();
    stream.nextSlice("\x1b[?1049h\x1b[HALT");
    try rs.update(gpa, &t);
    check(rs.screen == .alternate and rs.dirty == .full and cellCp(&rs, 0, 0) == 'A', "alt screen enter: full redraw, alt content");
    rs.clean();
    stream.nextSlice("\x1b[?1049l");
    try rs.update(gpa, &t);
    check(rs.screen == .primary and cellCp(&rs, 0, 0) == 'R', "alt screen exit restores primary content");

    // Resize.
    rs.clean();
    try t.resize(gpa, .{ .cols = 30, .rows = 8 });
    try rs.update(gpa, &t);
    check(rs.cols == 30 and rs.rows == 8 and rs.dirty == .full, "resize 20x6 -> 30x8, full dirty");

    // Mouse: enable button tracking + SGR, encode a press at cell (2,1).
    stream.nextSlice("\x1b[?1000h\x1b[?1006h");
    const SizeT = @FieldType(vt.input.MouseEncodeOptions, "size");
    const msize: SizeT = .{
        .screen = .{ .width = 30, .height = 8 },
        .cell = .{ .width = 1, .height = 1 },
        .padding = .{},
    };
    var mbuf: [64]u8 = undefined;
    var mw: std.Io.Writer = .fixed(&mbuf);
    try vt.input.encodeMouse(&mw, .{ .action = .press, .button = .left, .pos = .{ .x = 2.5, .y = 1.5 } }, .fromTerminal(&t, msize));
    std.debug.print("     mouse press bytes: {s}\n", .{mw.buffered()[1..]});
    check(std.mem.eql(u8, mw.buffered(), "\x1b[<0;3;2M"), "SGR mouse press encoded per pane mode");

    // Keys: DECCKM on -> arrow up is SS3 A.
    stream.nextSlice("\x1b[?1h");
    var kbuf: [64]u8 = undefined;
    var kw: std.Io.Writer = .fixed(&kbuf);
    try vt.input.encodeKey(&kw, .{ .key = .arrow_up }, .fromTerminal(&t));
    check(std.mem.eql(u8, kw.buffered(), "\x1bOA"), "arrow up under DECCKM encodes ESC O A");

    // Scrollback bound: push lots of lines and confirm memory stays bounded.
    var line: [64]u8 = undefined;
    for (0..20000) |i| {
        const s = try std.fmt.bufPrint(&line, "line {d} xxxxxxxxxxxxxxxxxxxx\r\n", .{i});
        stream.nextSlice(s);
    }
    const total_rows = t.screens.active.pages.total_rows;
    std.debug.print("     after 20000 lines with 64KiB scrollback cap: total_rows={d}\n", .{total_rows});
    check(total_rows < 20000, "scrollback is bounded by max_scrollback_bytes");

    // Microbench: one-cell spinner, parse + RenderState update per frame.
    {
        var st: vt.Terminal = try .init(init.io, gpa, .{ .cols = 100, .rows = 40 });
        defer st.deinit(gpa);
        var ss = st.vtStream();
        defer ss.deinit();
        var srs: vt.RenderState = .empty;
        defer srs.deinit(gpa);
        for (0..39) |_| ss.nextSlice("some shell output line that fills part of the row.......\r\n");
        try srs.update(gpa, &st);
        const frames = [_][]const u8{ "\r|", "\r/", "\r-", "\r\\" };
        const n: usize = 200_000;
        const t0 = nowNs();
        for (0..n) |i| {
            srs.clean();
            ss.nextSlice(frames[i % 4]);
            try srs.update(gpa, &st);
        }
        const dt = nowNs() - t0;
        std.debug.print("     spinner bench 100x40: {d} ns/frame (parse+RenderState.update)\n", .{dt / n});
        std.debug.print("     => at 60 Hz: {d:.4}% of one core\n", .{@as(f64, @floatFromInt(dt / n)) * 60.0 / 1e9 * 100.0});
    }
}
