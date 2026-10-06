//! Encodes decoded input for a pane with ghostty's encoders, so the pane
//! terminal's modes decide the bytes: DECCKM, keypad mode,
//! modifyOtherKeys, kitty flags, bracketed paste, focus reporting, and
//! mouse tracking.

const std = @import("std");
const vt = @import("ghostty-vt");
const input = @import("input.zig");

pub fn event(w: *std.Io.Writer, t: *const vt.Terminal, ev: input.Event) std.Io.Writer.Error!void {
    switch (ev) {
        .key => |k| {
            var utf8: [4]u8 = undefined;
            try vt.input.encodeKey(w, keyEvent(k, &utf8), keyOptions(t));
        },
        .paste => |p| {
            const parts = vt.input.encodePaste(p.data, .fromTerminal(t));
            if (p.first) try w.writeAll(parts[0]);
            try w.writeAll(parts[1]);
            if (p.last) try w.writeAll(parts[2]);
        },
        .focus => |f| if (t.modes.get(.focus_event)) try vt.input.encodeFocus(w, switch (f) {
            .in => .gained,
            .out => .lost,
        }),
        .unknown => |bytes| try w.writeAll(bytes),
        .mouse, .reply => {},
    }
}

/// The pane terminal's key options. Alt is always alt: the outer
/// terminal already decided what its option key sends, so the macOS
/// default of option producing text would drop alt from decoded chords.
pub fn keyOptions(t: *const vt.Terminal) vt.input.KeyEncodeOptions {
    var opts: vt.input.KeyEncodeOptions = .fromTerminal(t);
    opts.macos_option_as_alt = .true;
    return opts;
}

/// Encodes a mouse report at pane-local cell (`x`, `y`), which lies
/// outside the pane while a drag leaves it. Cells are 1x1 pixels, so
/// ghostty's pixel positions are cell positions.
pub fn mouse(w: *std.Io.Writer, t: *const vt.Terminal, ev: input.Mouse, x: i32, y: i32) std.Io.Writer.Error!void {
    const Size = @FieldType(vt.input.MouseEncodeOptions, "size");
    const size: Size = .{
        .screen = .{ .width = t.cols, .height = t.rows },
        .cell = .{ .width = 1, .height = 1 },
        .padding = .{},
    };
    var opts: vt.input.MouseEncodeOptions = .fromTerminal(t, size);
    opts.any_button_pressed = ev.action != .release and ev.button != .none;
    const button: ?vt.input.MouseButton = switch (ev.button) {
        .left => .left,
        .middle => .middle,
        .right => .right,
        .none => null,
        .wheel_up => .four,
        .wheel_down => .five,
        .wheel_left => .six,
        .wheel_right => .seven,
        .b8 => .eight,
        .b9 => .nine,
        .b10 => .ten,
        .b11 => .eleven,
    };
    try vt.input.encodeMouse(w, .{
        .action = switch (ev.action) {
            .press => .press,
            .release => .release,
            .motion => .motion,
        },
        .button = button,
        .mods = .{ .shift = ev.mods.shift, .alt = ev.mods.alt, .ctrl = ev.mods.ctrl },
        // The cell's center, so that rounding cannot move it to a neighbor.
        .pos = .{ .x = @as(f32, @floatFromInt(x)) + 0.5, .y = @as(f32, @floatFromInt(y)) + 0.5 },
    }, opts);
}

/// ghostty's event for `k`. `utf8` backs the event's text.
pub fn keyEvent(k: input.Key, utf8: *[4]u8) vt.input.KeyEvent {
    var ev: vt.input.KeyEvent = .{
        .action = switch (k.action) {
            .press => .press,
            .repeat => .repeat,
            .release => .release,
        },
        .mods = .{
            .shift = k.mods.shift,
            .ctrl = k.mods.ctrl,
            .alt = k.mods.alt,
            .super = k.mods.super,
            .caps_lock = k.mods.caps_lock,
            .num_lock = k.mods.num_lock,
        },
    };
    switch (k.code) {
        .named => |n| ev.key = switch (n) {
            inline else => |tag| @field(vt.input.Key, @tagName(tag)),
        },
        .char => |c| {
            ev.key = if (std.math.cast(u8, c)) |b| vt.input.Key.fromASCII(b) orelse .unidentified else .unidentified;
            ev.unshifted_codepoint = c;
            const text = if (k.text != 0) k.text else if (k.mods.shift and c >= 'a' and c <= 'z') c - 32 else c;
            ev.utf8 = utf8[0 .. std.unicode.utf8Encode(text, utf8) catch 0];
            if (text != c) ev.consumed_mods.shift = k.mods.shift;
        },
    }
    return ev;
}

const testing = std.testing;
const gpa = testing.allocator;

const Pane = struct {
    t: vt.Terminal,
    stream: vt.TerminalStream,

    fn init(p: *Pane, modes: []const u8) !void {
        p.t = try .init(testing.io, gpa, .{ .cols = 20, .rows = 5 });
        p.stream = p.t.vtStream();
        p.stream.nextSlice(modes);
    }

    fn deinit(p: *Pane) void {
        p.stream.deinit();
        p.t.deinit(gpa);
    }

    fn expect(p: *Pane, expected: []const u8, ev: input.Event) !void {
        var buf: [256]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        try event(&w, &p.t, ev);
        try testing.expectEqualStrings(expected, w.buffered());
    }
};

fn key(k: input.Key) input.Event {
    return .{ .key = k };
}

test "cursor keys follow the pane's DECCKM" {
    var p: Pane = undefined;
    try p.init("");
    defer p.deinit();
    try p.expect("\x1b[A", key(.named(.arrow_up, .{})));
    try p.expect("\x1b[1;5A", key(.named(.arrow_up, .{ .ctrl = true })));
    p.stream.nextSlice("\x1b[?1h");
    try p.expect("\x1bOA", key(.named(.arrow_up, .{})));
}

test "kitty flags the pane pushed decide key bytes" {
    var p: Pane = undefined;
    try p.init("");
    defer p.deinit();
    try p.expect("\r", key(.named(.enter, .{})));
    try p.expect("\x02", key(.chord('b', .{ .ctrl = true })));
    try p.expect("\x1b", key(.named(.escape, .{})));
    try p.expect("\x1bx", key(.{ .code = .{ .char = 'x' }, .mods = .{ .alt = true }, .text = 'x' }));
    p.stream.nextSlice("\x1b[>1u");
    try p.expect("\r", key(.named(.enter, .{})));
    try p.expect("\x1b[13;2u", key(.named(.enter, .{ .shift = true })));
    try p.expect("\x1b[98;5u", key(.chord('b', .{ .ctrl = true })));
    try p.expect("\x1b[27u", key(.named(.escape, .{})));
    try p.expect("\x1b[120;3u", key(.{ .code = .{ .char = 'x' }, .mods = .{ .alt = true }, .text = 'x' }));
    try p.expect("A", key(.typed('A')));
    try p.expect("\xe4\xb8\xad", key(.typed(0x4e2d)));
}

test "paste is bracketed only when the pane enabled it, and is always sanitized" {
    var p: Pane = undefined;
    try p.init("");
    defer p.deinit();
    var data = "a\nb\x1bc".*;
    try p.expect("a\rb c", .{ .paste = .{ .data = &data } });
    p.stream.nextSlice("\x1b[?2004h");
    data = "a\nb\x1bc".*;
    try p.expect("\x1b[200~a\nb c\x1b[201~", .{ .paste = .{ .data = &data } });
}

test "a chunked paste opens the bracket once and closes it once" {
    var p: Pane = undefined;
    try p.init("\x1b[?2004h");
    defer p.deinit();
    var a = "ab\n".*;
    var b = "cd".*;
    var c = "e\x1b".*;
    try p.expect("\x1b[200~ab\n", .{ .paste = .{ .data = &a, .last = false } });
    try p.expect("cd", .{ .paste = .{ .data = &b, .first = false, .last = false } });
    try p.expect("e \x1b[201~", .{ .paste = .{ .data = &c, .first = false } });
}

test "focus reaches only a pane that enabled focus reporting" {
    var p: Pane = undefined;
    try p.init("");
    defer p.deinit();
    try p.expect("", .{ .focus = .in });
    p.stream.nextSlice("\x1b[?1004h");
    try p.expect("\x1b[I", .{ .focus = .in });
    try p.expect("\x1b[O", .{ .focus = .out });
}

test "unknown sequences pass through and replies never do" {
    var p: Pane = undefined;
    try p.init("");
    defer p.deinit();
    try p.expect("\x1b[5n", .{ .unknown = "\x1b[5n" });
    try p.expect("", .{ .reply = .device_attributes });
}

const KeyEvent = vt.input.KeyEvent;
const KeyOptions = vt.input.KeyEncodeOptions;

/// Key presses as ghostty's own frontends describe them.
const presses = [_]KeyEvent{
    .{ .key = .key_a, .utf8 = "a", .unshifted_codepoint = 'a' },
    .{ .key = .key_a, .mods = .{ .shift = true }, .consumed_mods = .{ .shift = true }, .utf8 = "A", .unshifted_codepoint = 'a' },
    .{ .key = .key_c, .mods = .{ .ctrl = true }, .utf8 = "c", .unshifted_codepoint = 'c' },
    .{ .key = .key_b, .mods = .{ .ctrl = true }, .utf8 = "b", .unshifted_codepoint = 'b' },
    .{ .key = .key_x, .mods = .{ .alt = true }, .utf8 = "x", .unshifted_codepoint = 'x' },
    .{ .key = .key_c, .mods = .{ .ctrl = true, .alt = true }, .utf8 = "c", .unshifted_codepoint = 'c' },
    .{ .key = .key_a, .mods = .{ .ctrl = true, .shift = true }, .utf8 = "A", .unshifted_codepoint = 'a' },
    .{ .key = .key_i, .mods = .{ .ctrl = true }, .utf8 = "i", .unshifted_codepoint = 'i' },
    .{ .key = .space, .utf8 = " ", .unshifted_codepoint = ' ' },
    .{ .key = .space, .mods = .{ .ctrl = true }, .utf8 = " ", .unshifted_codepoint = ' ' },
    .{ .key = .digit_1, .mods = .{ .shift = true }, .consumed_mods = .{ .shift = true }, .utf8 = "!", .unshifted_codepoint = '1' },
    .{ .key = .unidentified, .utf8 = "\u{4e2d}", .unshifted_codepoint = 0x4e2d },
    .{ .key = .enter },
    .{ .key = .enter, .mods = .{ .shift = true } },
    .{ .key = .enter, .mods = .{ .alt = true } },
    .{ .key = .tab },
    .{ .key = .tab, .mods = .{ .shift = true } },
    .{ .key = .backspace },
    .{ .key = .backspace, .mods = .{ .alt = true } },
    .{ .key = .escape },
    .{ .key = .arrow_up },
    .{ .key = .arrow_left, .mods = .{ .ctrl = true } },
    .{ .key = .arrow_right, .mods = .{ .shift = true, .alt = true } },
    .{ .key = .home },
    .{ .key = .end, .mods = .{ .ctrl = true } },
    .{ .key = .page_down },
    .{ .key = .delete },
    .{ .key = .insert, .mods = .{ .shift = true } },
    .{ .key = .f1 },
    .{ .key = .f3 },
    .{ .key = .f4, .mods = .{ .shift = true } },
    .{ .key = .f5 },
    .{ .key = .f12, .mods = .{ .ctrl = true } },
};

fn encodeWith(ev: KeyEvent, opts: KeyOptions, buf: []u8) ![]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    try vt.input.encodeKey(&w, ev, opts);
    return w.buffered();
}

test "every press decodes from either outer encoding and re-encodes as the pane would see it directly" {
    const legacy: KeyOptions = .{ .alt_esc_prefix = true, .macos_option_as_alt = .true };
    const kitty: KeyOptions = .{ .alt_esc_prefix = true, .macos_option_as_alt = .true, .kitty_flags = .{ .disambiguate = true } };
    const outers = [_]KeyOptions{ legacy, kitty };
    var panes = [_]Pane{ undefined, undefined, undefined };
    try panes[0].init("");
    defer panes[0].deinit();
    try panes[1].init("\x1b[?1h");
    defer panes[1].deinit();
    try panes[2].init("\x1b[>1u");
    defer panes[2].deinit();

    for (presses) |press| for (outers) |outer| for (&panes) |*pane| {
        var outer_buf: [64]u8 = undefined;
        const outer_bytes = try encodeWith(press, outer, &outer_buf);
        var direct_buf: [64]u8 = undefined;
        const direct = try encodeWith(press, keyOptions(&pane.t), &direct_buf);

        var d: input.Decoder = .{};
        defer d.deinit(gpa);
        try d.feed(gpa, outer_bytes);
        d.expire();
        var via_buf: [64]u8 = undefined;
        var w: std.Io.Writer = .fixed(&via_buf);
        while (try d.next(gpa)) |ev| try event(&w, &pane.t, ev);
        testing.expectEqualStrings(direct, w.buffered()) catch |e| {
            std.debug.print("press {any}\nouter bytes {any}\n", .{ press, outer_bytes });
            return e;
        };
    };
}

fn expectMouse(p: *Pane, expected: []const u8, ev: input.Mouse, x: i32, y: i32) !void {
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try mouse(&w, &p.t, ev, x, y);
    try testing.expectEqualStrings(expected, w.buffered());
}

fn report(button: input.Mouse.Button, action: input.Mouse.Action) input.Mouse {
    return .{ .button = button, .action = action, .x = 0, .y = 0, .mods = .{} };
}

test "mouse reports follow the pane's tracking mode and format, in pane-local cells" {
    var p: Pane = undefined;
    try p.init("");
    defer p.deinit();
    try expectMouse(&p, "", report(.left, .press), 3, 2);
    p.stream.nextSlice("\x1b[?1000h\x1b[?1006h");
    try expectMouse(&p, "\x1b[<0;4;3M", report(.left, .press), 3, 2);
    try expectMouse(&p, "\x1b[<0;4;3m", report(.left, .release), 3, 2);
    try expectMouse(&p, "", report(.left, .motion), 4, 2);
    try expectMouse(&p, "\x1b[<64;1;1M", report(.wheel_up, .press), 0, 0);
    try expectMouse(&p, "\x1b[<18;20;5M", .{ .button = .right, .action = .press, .x = 0, .y = 0, .mods = .{ .ctrl = true } }, 19, 4);
    p.stream.nextSlice("\x1b[?1002h");
    try expectMouse(&p, "\x1b[<32;5;3M", report(.left, .motion), 4, 2);
    try expectMouse(&p, "\x1b[<32;1;3M", report(.left, .motion), -3, 2);
    p.stream.nextSlice("\x1b[?1006l");
    try expectMouse(&p, "\x1b[M #\"", report(.left, .press), 2, 1);
}
