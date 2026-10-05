//! Decodes the outer terminal's input into events: keys in legacy xterm and
//! kitty encodings, SGR mouse reports, bracketed paste, focus changes, and
//! replies to Kiwa's own probes. Pure; it keeps partial sequences across
//! `feed` calls.

const std = @import("std");

/// Bit order matches the xterm and kitty modifier parameter minus one.
pub const Mods = packed struct(u8) {
    shift: bool = false,
    alt: bool = false,
    ctrl: bool = false,
    super: bool = false,
    hyper: bool = false,
    meta: bool = false,
    caps_lock: bool = false,
    num_lock: bool = false,

    /// The modifiers that key bindings compare; lock keys never count.
    pub fn binding(m: Mods) Mods {
        return .{ .shift = m.shift, .alt = m.alt, .ctrl = m.ctrl, .super = m.super };
    }

    pub fn eql(a: Mods, b: Mods) bool {
        return @as(u8, @bitCast(a)) == @as(u8, @bitCast(b));
    }

    fn fromParam(value: u32) Mods {
        return @bitCast(@as(u8, @truncate(@max(value, 1) - 1)));
    }
};

/// Keys that are not characters. Tag names match ghostty's `input.Key`.
pub const Named = enum {
    escape,
    enter,
    tab,
    backspace,
    insert,
    delete,
    arrow_left,
    arrow_right,
    arrow_up,
    arrow_down,
    page_up,
    page_down,
    home,
    end,
    caps_lock,
    scroll_lock,
    num_lock,
    print_screen,
    pause,
    f1,
    f2,
    f3,
    f4,
    f5,
    f6,
    f7,
    f8,
    f9,
    f10,
    f11,
    f12,
    f13,
    f14,
    f15,
    f16,
    f17,
    f18,
    f19,
    f20,
    f21,
    f22,
    f23,
    f24,
    f25,
    numpad_0,
    numpad_1,
    numpad_2,
    numpad_3,
    numpad_4,
    numpad_5,
    numpad_6,
    numpad_7,
    numpad_8,
    numpad_9,
    numpad_decimal,
    numpad_divide,
    numpad_multiply,
    numpad_subtract,
    numpad_add,
    numpad_enter,
    numpad_equal,
    numpad_separator,
    numpad_left,
    numpad_right,
    numpad_up,
    numpad_down,
    numpad_page_up,
    numpad_page_down,
    numpad_home,
    numpad_end,
    numpad_insert,
    numpad_delete,
    numpad_begin,
    shift_left,
    shift_right,
    control_left,
    control_right,
    meta_left,
    meta_right,
    alt_left,
    alt_right,
};

pub const Key = struct {
    code: Code,
    mods: Mods = .{},
    action: Action = .press,
    /// The character the key typed, when the encoding says so: 'A' for
    /// shift+a, 'a' for a plain `a`. Zero when unknown or none.
    text: u21 = 0,

    pub const Code = union(enum) {
        /// The unshifted character, such as 'a' for shift+a.
        char: u21,
        named: Named,
    };

    pub const Action = enum { press, repeat, release };

    pub fn named(n: Named, mods: Mods) Key {
        return .{ .code = .{ .named = n }, .mods = mods };
    }

    /// A key that types `cp`, such as a plain or shifted letter.
    pub fn typed(cp: u21) Key {
        if (cp >= 'A' and cp <= 'Z') return .{ .code = .{ .char = cp + 32 }, .mods = .{ .shift = true }, .text = cp };
        return .{ .code = .{ .char = cp }, .text = cp };
    }

    pub fn chord(cp: u21, mods: Mods) Key {
        return .{ .code = .{ .char = cp }, .mods = mods };
    }
};

pub const Mouse = struct {
    button: Button,
    action: Action,
    /// Zero-based cell coordinates in the outer terminal.
    x: u16,
    y: u16,
    mods: Mods,

    pub const Button = enum(u4) { left, middle, right, none, wheel_up, wheel_down, wheel_left, wheel_right, b8, b9, b10, b11 };
    pub const Action = enum { press, release, motion };
};

pub const Focus = enum { in, out };

/// A terminal's answer to one of Kiwa's own queries.
pub const Reply = union(enum) {
    /// `CSI ? flags u`: the kitty keyboard flags.
    kitty_flags: u32,
    /// DECRPM, `CSI ? mode ; state $ y`.
    mode: struct { mode: u32, state: u32 },
    /// DA1, `CSI ? ... c`.
    device_attributes,
};

pub const Event = union(enum) {
    key: Key,
    mouse: Mouse,
    /// The text between `CSI 200 ~` and `CSI 201 ~`. Mutable so that paste
    /// encoding can sanitize it in place.
    paste: []u8,
    focus: Focus,
    reply: Reply,
    /// A sequence Kiwa does not understand, to pass to the pane unchanged.
    unknown: []const u8,
};

const paste_end = "\x1b[201~";

pub const Decoder = struct {
    buf: std.ArrayList(u8) = .empty,
    pos: usize = 0,
    mode: enum { keys, paste } = .keys,
    paste: std.ArrayList(u8) = .empty,
    /// Set once the input has gone quiet: a partial sequence at the end is
    /// then taken as complete, so a lone ESC becomes the escape key.
    expired: bool = false,

    pub fn deinit(d: *Decoder, gpa: std.mem.Allocator) void {
        d.buf.deinit(gpa);
        d.paste.deinit(gpa);
    }

    /// Slices in events returned before this call become invalid.
    pub fn feed(d: *Decoder, gpa: std.mem.Allocator, bytes: []const u8) std.mem.Allocator.Error!void {
        d.buf.replaceRangeAssumeCapacity(0, d.pos, &.{});
        d.pos = 0;
        d.expired = false;
        try d.buf.appendSlice(gpa, bytes);
    }

    /// True when a partial sequence waits for more bytes, or for `expire`.
    pub fn pending(d: *const Decoder) bool {
        return d.mode == .keys and d.pos < d.buf.items.len;
    }

    pub fn expire(d: *Decoder) void {
        d.expired = true;
    }

    /// Returns the next complete event, or null when more input is needed.
    pub fn next(d: *Decoder, gpa: std.mem.Allocator) std.mem.Allocator.Error!?Event {
        while (true) {
            const rest = d.buf.items[d.pos..];
            if (rest.len == 0) return null;
            switch (d.mode) {
                .paste => {
                    if (std.mem.indexOf(u8, rest, paste_end)) |end| {
                        try d.paste.appendSlice(gpa, rest[0..end]);
                        d.pos += end + paste_end.len;
                        d.mode = .keys;
                        return .{ .paste = d.paste.items };
                    }
                    const take = rest.len - partialSuffix(rest, paste_end);
                    try d.paste.appendSlice(gpa, rest[0..take]);
                    d.pos += take;
                    return null;
                },
                .keys => {
                    const p = parse(rest, d.expired) orelse return null;
                    d.pos += p.len;
                    switch (p.what) {
                        .event => |ev| return ev,
                        .paste_start => {
                            d.mode = .paste;
                            d.paste.clearRetainingCapacity();
                        },
                    }
                },
            }
        }
    }
};

/// The length of the longest proper prefix of `marker` that ends `bytes`.
fn partialSuffix(bytes: []const u8, marker: []const u8) usize {
    var n = @min(bytes.len, marker.len - 1);
    while (n > 0) : (n -= 1) {
        if (std.mem.eql(u8, bytes[bytes.len - n ..], marker[0..n])) return n;
    }
    return 0;
}

const Parsed = struct {
    what: union(enum) { event: Event, paste_start },
    len: usize,

    fn of(ev: Event, len: usize) Parsed {
        return .{ .what = .{ .event = ev }, .len = len };
    }

    fn key(k: Key, len: usize) Parsed {
        return of(.{ .key = k }, len);
    }

    fn unknown(bytes: []const u8) Parsed {
        return of(.{ .unknown = bytes }, bytes.len);
    }
};

/// Parses the sequence at the start of `bytes`. Returns null when it is
/// incomplete and `final` is false.
fn parse(bytes: []const u8, final: bool) ?Parsed {
    if (bytes[0] != 0x1b) return parsePlain(bytes, final);
    if (bytes.len == 1) return if (final) .key(.named(.escape, .{}), 1) else null;
    return switch (bytes[1]) {
        '[' => parseCsi(bytes, final),
        'O' => {
            if (bytes.len == 2) return if (final) .key(withAlt(.typed('O')), 2) else null;
            if (ss3Key(bytes[2])) |n| return .key(.named(n, .{}), 3);
            if (bytes[2] >= 0x40 and bytes[2] <= 0x7e) return .unknown(bytes[0..3]);
            return .key(withAlt(.typed('O')), 2);
        },
        0x1b => .key(.named(.escape, .{}), 1),
        else => {
            const inner = parsePlain(bytes[1..], final) orelse return null;
            if (inner.what != .event or inner.what.event != .key) return .key(.named(.escape, .{}), 1);
            return .key(withAlt(inner.what.event.key), 1 + inner.len);
        },
    };
}

fn withAlt(k: Key) Key {
    var out = k;
    out.mods.alt = true;
    return out;
}

/// One byte below 0x80 other than ESC, or one UTF-8 character.
fn parsePlain(bytes: []const u8, final: bool) ?Parsed {
    const b = bytes[0];
    if (b < 0x80) return .key(asciiKey(b), 1);
    const len = std.unicode.utf8ByteSequenceLength(b) catch return .unknown(bytes[0..1]);
    if (bytes.len < len) return if (final) .unknown(bytes) else null;
    const cp = std.unicode.utf8Decode(bytes[0..len]) catch return .unknown(bytes[0..1]);
    return .key(.typed(cp), len);
}

fn asciiKey(b: u8) Key {
    const c: Mods = .{ .ctrl = true };
    return switch (b) {
        0x00 => .chord(' ', c),
        '\t' => .named(.tab, .{}),
        '\r' => .named(.enter, .{}),
        0x7f => .named(.backspace, .{}),
        0x01...0x08, 0x0a...0x0c, 0x0e...0x1a => .chord('a' + b - 1, c),
        0x1c...0x1f => .chord("\\]^_"[b - 0x1c], c),
        0x1b => unreachable,
        else => .typed(b),
    };
}

fn ss3Key(final: u8) ?Named {
    return switch (final) {
        'P' => .f1,
        'Q' => .f2,
        'R' => .f3,
        'S' => .f4,
        else => letterKey(final),
    };
}

/// Keys whose CSI and SS3 forms end in a letter.
fn letterKey(final: u8) ?Named {
    return switch (final) {
        'A' => .arrow_up,
        'B' => .arrow_down,
        'C' => .arrow_right,
        'D' => .arrow_left,
        'E' => .numpad_begin,
        'F' => .end,
        'H' => .home,
        else => null,
    };
}

/// `CSI n ~` keys: xterm and kitty numbers, plus rxvt's home, end, and F1 to F4.
fn tildeKey(n: u32) ?Named {
    return switch (n) {
        1, 7 => .home,
        2 => .insert,
        3 => .delete,
        4, 8 => .end,
        5 => .page_up,
        6 => .page_down,
        11 => .f1,
        12 => .f2,
        13 => .f3,
        14 => .f4,
        15 => .f5,
        17 => .f6,
        18 => .f7,
        19 => .f8,
        20 => .f9,
        21 => .f10,
        23 => .f11,
        24 => .f12,
        25 => .f13,
        26 => .f14,
        28 => .f15,
        29 => .f16,
        31 => .f17,
        32 => .f18,
        33 => .f19,
        34 => .f20,
        else => null,
    };
}

/// Kitty `CSI code u` numbers for keys that are not characters.
fn kittyKey(code: u32) ?Named {
    return switch (code) {
        27 => .escape,
        13 => .enter,
        9 => .tab,
        127 => .backspace,
        57358 => .caps_lock,
        57359 => .scroll_lock,
        57360 => .num_lock,
        57361 => .print_screen,
        57362 => .pause,
        57376...57388 => |c| @enumFromInt(@intFromEnum(Named.f13) + (c - 57376)),
        57399...57427 => |c| @enumFromInt(@intFromEnum(Named.numpad_0) + (c - 57399)),
        57441 => .shift_left,
        57442 => .control_left,
        57443 => .alt_left,
        57444 => .meta_left,
        57447 => .shift_right,
        57448 => .control_right,
        57449 => .alt_right,
        57450 => .meta_right,
        else => null,
    };
}

const Csi = struct {
    private: u8 = 0,
    intermediate: u8 = 0,
    final: u8 = 0,
    count: usize = 0,
    /// Parameters, each with up to `max_sub` colon-separated values.
    params: [max_params][max_sub]u32 = @splat(@splat(0)),
    subs: [max_params]usize = @splat(0),

    const max_params = 8;
    const max_sub = 3;

    fn get(c: *const Csi, i: usize, sub: usize, default: u32) u32 {
        if (i >= c.count or sub >= c.subs[i]) return default;
        return c.params[i][sub];
    }

    /// Fills the parameters from the bytes between `CSI` and the final
    /// byte. Returns false for a layout that no key or reply uses.
    fn parseParams(c: *Csi, body: []const u8) bool {
        var rest = body;
        if (rest.len > 0 and rest[0] >= '<' and rest[0] <= '?') {
            c.private = rest[0];
            rest = rest[1..];
        }
        if (rest.len > 0 and rest[rest.len - 1] >= 0x20 and rest[rest.len - 1] <= 0x2f) {
            c.intermediate = rest[rest.len - 1];
            rest = rest[0 .. rest.len - 1];
        }
        if (rest.len == 0) return true;
        var i: usize = 0;
        var sub: usize = 0;
        c.count = 1;
        c.subs[0] = 1;
        for (rest) |b| switch (b) {
            '0'...'9' => if (i < max_params and sub < max_sub) {
                c.params[i][sub] = c.params[i][sub] *| 10 +| (b - '0');
            },
            ';' => {
                i += 1;
                sub = 0;
                if (i < max_params) {
                    c.count = i + 1;
                    c.subs[i] = 1;
                }
            },
            ':' => {
                sub += 1;
                if (i < max_params and sub < max_sub) c.subs[i] = sub + 1;
            },
            else => return false,
        };
        return true;
    }
};

fn parseCsi(bytes: []const u8, final: bool) ?Parsed {
    var i: usize = 2;
    while (i < bytes.len) : (i += 1) {
        const b = bytes[i];
        if (b >= 0x40 and b <= 0x7e) break;
        // A byte that cannot be inside a CSI ends it; the next parse starts there.
        if (b < 0x20 or b > 0x3f) return .unknown(bytes[0..i]);
    } else {
        if (!final) return null;
        if (bytes.len == 2) return .key(withAlt(.typed('[')), 2);
        return .unknown(bytes);
    }
    const raw = bytes[0 .. i + 1];
    var c: Csi = .{ .final = bytes[i] };
    if (!c.parseParams(bytes[2..i])) return .unknown(raw);
    if (c.final == '~' and c.private == 0 and c.intermediate == 0 and c.get(0, 0, 0) == 200) {
        return .{ .what = .paste_start, .len = raw.len };
    }
    const ev = csiEvent(&c) orelse return .unknown(raw);
    return .of(ev, raw.len);
}

fn csiEvent(c: *const Csi) ?Event {
    switch (c.private) {
        '?' => return switch (c.final) {
            'u' => if (c.intermediate == 0) .{ .reply = .{ .kitty_flags = c.get(0, 0, 0) } } else null,
            'c' => if (c.intermediate == 0) .{ .reply = .device_attributes } else null,
            'y' => if (c.intermediate == '$') .{ .reply = .{ .mode = .{ .mode = c.get(0, 0, 0), .state = c.get(1, 0, 0) } } } else null,
            else => null,
        },
        '<' => return if (c.intermediate == 0) mouseEvent(c) else null,
        0 => {},
        else => return null,
    }
    if (c.intermediate != 0) return null;
    if (c.count == 0) switch (c.final) {
        'I' => return .{ .focus = .in },
        'O' => return .{ .focus = .out },
        'Z' => return .{ .key = .named(.tab, .{ .shift = true }) },
        else => {},
    };
    var k: Key = switch (c.final) {
        'u' => kitty: {
            const code = c.get(0, 0, 0);
            if (kittyKey(code)) |n| break :kitty .named(n, .{});
            const cp = std.math.cast(u21, code) orelse return null;
            if (cp == 0 or !std.unicode.utf8ValidCodepoint(cp)) return null;
            break :kitty .{ .code = .{ .char = cp }, .text = std.math.cast(u21, c.get(2, 0, 0)) orelse 0 };
        },
        '~' => switch (c.get(0, 0, 1)) {
            27 => modifyOtherKeys(c) orelse return null,
            else => |n| .named(tildeKey(n) orelse return null, .{}),
        },
        'P', 'Q', 'R', 'S' => .named(ss3Key(c.final).?, .{}),
        else => .named(letterKey(c.final) orelse return null, .{}),
    };
    k.mods = Mods.fromParam(c.get(1, 0, 1));
    k.action = switch (c.get(1, 1, 1)) {
        2 => .repeat,
        3 => .release,
        else => .press,
    };
    return .{ .key = k };
}

/// xterm's `CSI 27 ; mods ; code ~`.
fn modifyOtherKeys(c: *const Csi) ?Key {
    const code = c.get(2, 0, 0);
    if (kittyKey(code)) |n| if (code < 128) return .named(n, .{});
    const cp = std.math.cast(u21, code) orelse return null;
    if (!std.unicode.utf8ValidCodepoint(cp)) return null;
    const k: Key = .typed(cp);
    return .{ .code = k.code, .text = if (k.code.char != cp) cp else 0 };
}

fn mouseEvent(c: *const Csi) ?Event {
    if (c.final != 'M' and c.final != 'm') return null;
    if (c.count != 3) return null;
    const b = c.get(0, 0, 0);
    const index = (b & 3) | (((b >> 6) & 3) << 2);
    if (index > @intFromEnum(Mouse.Button.b11)) return null;
    const x = c.get(1, 0, 1);
    const y = c.get(2, 0, 1);
    if (x == 0 or y == 0) return null;
    return .{ .mouse = .{
        .button = @enumFromInt(index),
        .action = if (c.final == 'm') .release else if (b & 32 != 0) .motion else .press,
        .x = std.math.cast(u16, x - 1) orelse std.math.maxInt(u16),
        .y = std.math.cast(u16, y - 1) orelse std.math.maxInt(u16),
        .mods = .{ .shift = b & 4 != 0, .alt = b & 8 != 0, .ctrl = b & 16 != 0 },
    } };
}

const testing = std.testing;

const Run = struct {
    arena: std.heap.ArenaAllocator,
    events: std.ArrayList(Event) = .empty,
    pending: bool = false,

    fn deinit(r: *Run) void {
        r.arena.deinit();
    }
};

/// Feeds each chunk in turn and collects the events. With `quiet`, the
/// input then goes quiet, as when the server's ESC deadline fires.
fn decode(chunks: []const []const u8, quiet: bool) !Run {
    var r: Run = .{ .arena = .init(testing.allocator) };
    errdefer r.deinit();
    var d: Decoder = .{};
    defer d.deinit(testing.allocator);
    for (chunks) |chunk| {
        try d.feed(testing.allocator, chunk);
        try collect(&d, &r);
    }
    if (quiet) {
        d.expire();
        try collect(&d, &r);
    }
    r.pending = d.pending();
    return r;
}

fn collect(d: *Decoder, r: *Run) !void {
    const a = r.arena.allocator();
    while (try d.next(testing.allocator)) |ev| try r.events.append(a, switch (ev) {
        .paste => |p| .{ .paste = try a.dupe(u8, p) },
        .unknown => |u| .{ .unknown = try a.dupe(u8, u) },
        else => ev,
    });
}

fn expectEvents(chunks: []const []const u8, quiet: bool, expected: []const Event) !void {
    var r = try decode(chunks, quiet);
    defer r.deinit();
    try testing.expectEqualDeep(expected, r.events.items);
    try testing.expect(!r.pending);
}

fn key(k: Key) Event {
    return .{ .key = k };
}

fn named(n: Named, mods: Mods) Event {
    return key(.named(n, mods));
}

fn chord(cp: u21, mods: Mods) Event {
    return key(.chord(cp, mods));
}

fn typed(cp: u21) Event {
    return key(.typed(cp));
}

fn altTyped(cp: u21) Event {
    return key(withAlt(.typed(cp)));
}

const ctrl: Mods = .{ .ctrl = true };
const shift: Mods = .{ .shift = true };
const alt: Mods = .{ .alt = true };

test "printable ASCII and UTF-8 type their characters" {
    try expectEvents(&.{"aZ1 ~\xe4\xb8\xad\xc3\xa9"}, false, &.{
        typed('a'),
        key(.{ .code = .{ .char = 'z' }, .mods = shift, .text = 'Z' }),
        typed('1'),
        typed(' '),
        typed('~'),
        typed(0x4e2d),
        typed(0xe9),
    });
}

test "a UTF-8 character split across feeds waits for its last byte" {
    var r = try decode(&.{ "\xe4", "\xb8" }, false);
    defer r.deinit();
    try testing.expectEqual(0, r.events.items.len);
    try testing.expect(r.pending);
    try expectEvents(&.{ "\xe4", "\xb8", "\xad" }, false, &.{typed(0x4e2d)});
}

test "control bytes decode as ctrl chords and named keys" {
    try expectEvents(&.{"\x01\x02\x03\t\r\x7f\x00\x08\x0a\x1c\x1f"}, false, &.{
        chord('a', ctrl),
        chord('b', ctrl),
        chord('c', ctrl),
        named(.tab, .{}),
        named(.enter, .{}),
        named(.backspace, .{}),
        chord(' ', ctrl),
        chord('h', ctrl),
        chord('j', ctrl),
        chord('\\', ctrl),
        chord('_', ctrl),
    });
}

test "ESC before a key is an alt chord" {
    try expectEvents(&.{"\x1ba\x1bA\x1b\x03\x1b\x7f\x1b\r\x1b\xe4\xb8\xad"}, false, &.{
        altTyped('a'),
        altTyped('A'),
        chord('c', .{ .ctrl = true, .alt = true }),
        named(.backspace, alt),
        named(.enter, alt),
        altTyped(0x4e2d),
    });
}

test "arrows and function keys in CSI form, with and without modifiers" {
    try expectEvents(&.{"\x1b[A\x1b[1;5B\x1b[1;2C\x1b[D\x1b[H\x1b[F\x1b[E\x1b[2~\x1b[3;5~\x1b[5~\x1b[6;3~\x1b[1~\x1b[4~"}, false, &.{
        named(.arrow_up, .{}),
        named(.arrow_down, ctrl),
        named(.arrow_right, shift),
        named(.arrow_left, .{}),
        named(.home, .{}),
        named(.end, .{}),
        named(.numpad_begin, .{}),
        named(.insert, .{}),
        named(.delete, ctrl),
        named(.page_up, .{}),
        named(.page_down, alt),
        named(.home, .{}),
        named(.end, .{}),
    });
    try expectEvents(&.{"\x1b[1;2P\x1b[Q\x1b[1;5R\x1b[13~\x1b[15~\x1b[24;2~\x1b[11~\x1b[34~\x1b[Z"}, false, &.{
        named(.f1, shift),
        named(.f2, .{}),
        named(.f3, ctrl),
        named(.f3, .{}),
        named(.f5, .{}),
        named(.f12, shift),
        named(.f1, .{}),
        named(.f20, .{}),
        named(.tab, shift),
    });
}

test "SS3 arrows and F1 to F4" {
    try expectEvents(&.{"\x1bOA\x1bOB\x1bOC\x1bOD\x1bOH\x1bOF\x1bOP\x1bOQ\x1bOR\x1bOS"}, false, &.{
        named(.arrow_up, .{}),
        named(.arrow_down, .{}),
        named(.arrow_right, .{}),
        named(.arrow_left, .{}),
        named(.home, .{}),
        named(.end, .{}),
        named(.f1, .{}),
        named(.f2, .{}),
        named(.f3, .{}),
        named(.f4, .{}),
    });
}

test "kitty CSI u keys carry modifiers, event types, and text" {
    try expectEvents(&.{"\x1b[98;5u\x1b[13;2u\x1b[27u\x1b[9;5u\x1b[127;3u\x1b[97;6u\x1b[98;69u"}, false, &.{
        chord('b', ctrl),
        named(.enter, shift),
        named(.escape, .{}),
        named(.tab, ctrl),
        named(.backspace, alt),
        chord('a', .{ .ctrl = true, .shift = true }),
        chord('b', .{ .ctrl = true, .caps_lock = true }),
    });
    try expectEvents(&.{"\x1b[97;1:3u\x1b[97;5:2u\x1b[1;5:3A\x1b[57399u\x1b[57414;2u\x1b[57376u\x1b[97;2;65u"}, false, &.{
        key(.{ .code = .{ .char = 'a' }, .action = .release }),
        key(.{ .code = .{ .char = 'a' }, .mods = ctrl, .action = .repeat }),
        key(.{ .code = .{ .named = .arrow_up }, .mods = ctrl, .action = .release }),
        named(.numpad_0, .{}),
        named(.numpad_enter, shift),
        named(.f13, .{}),
        key(.{ .code = .{ .char = 'a' }, .mods = shift, .text = 'A' }),
    });
}

test "xterm modifyOtherKeys keys" {
    try expectEvents(&.{"\x1b[27;2;13~\x1b[27;5;105~\x1b[27;2;65~"}, false, &.{
        named(.enter, shift),
        chord('i', ctrl),
        key(.{ .code = .{ .char = 'a' }, .mods = shift, .text = 'A' }),
    });
}

test "bracketed paste split across feeds keeps its ESC bytes" {
    try expectEvents(&.{ "x\x1b[20", "0~line1\n\x1b[Aline2\x1b[2", "01", "~y" }, false, &.{
        typed('x'),
        .{ .paste = @constCast("line1\n\x1b[Aline2") },
        typed('y'),
    });
    try expectEvents(&.{"\x1b[200~\x1b[201~"}, false, &.{.{ .paste = @constCast("") }});
}

test "an unfinished paste waits without a deadline" {
    var r = try decode(&.{"\x1b[200~abc\x1b"}, true);
    defer r.deinit();
    try testing.expectEqual(0, r.events.items.len);
    try testing.expect(!r.pending);
}

test "focus in and out" {
    try expectEvents(&.{"\x1b[I\x1b[O"}, false, &.{ .{ .focus = .in }, .{ .focus = .out } });
}

test "probe replies: kitty flags, DA1, and DECRPM" {
    try expectEvents(&.{ "\x1b[?1u\x1b[?62;22c\x1b[?2026;2$y\x1b[?0u", "\x1b[?64;1;2;6;9;15;16;17;18;21;22;28c" }, false, &.{
        .{ .reply = .{ .kitty_flags = 1 } },
        .{ .reply = .device_attributes },
        .{ .reply = .{ .mode = .{ .mode = 2026, .state = 2 } } },
        .{ .reply = .{ .kitty_flags = 0 } },
        .{ .reply = .device_attributes },
    });
}

test "SGR mouse reports" {
    try expectEvents(&.{"\x1b[<0;10;5M\x1b[<2;10;5m\x1b[<32;11;5M\x1b[<35;1;1M\x1b[<64;1;1M\x1b[<65;2;3M\x1b[<20;3;4M"}, false, &.{
        .{ .mouse = .{ .button = .left, .action = .press, .x = 9, .y = 4, .mods = .{} } },
        .{ .mouse = .{ .button = .right, .action = .release, .x = 9, .y = 4, .mods = .{} } },
        .{ .mouse = .{ .button = .left, .action = .motion, .x = 10, .y = 4, .mods = .{} } },
        .{ .mouse = .{ .button = .none, .action = .motion, .x = 0, .y = 0, .mods = .{} } },
        .{ .mouse = .{ .button = .wheel_up, .action = .press, .x = 0, .y = 0, .mods = .{} } },
        .{ .mouse = .{ .button = .wheel_down, .action = .press, .x = 1, .y = 2, .mods = .{} } },
        .{ .mouse = .{ .button = .left, .action = .press, .x = 2, .y = 3, .mods = .{ .shift = true, .ctrl = true } } },
    });
}

test "a lone ESC waits, then flushes as the escape key once input goes quiet" {
    var r = try decode(&.{"\x1b"}, false);
    defer r.deinit();
    try testing.expectEqual(0, r.events.items.len);
    try testing.expect(r.pending);
    try expectEvents(&.{"\x1b"}, true, &.{named(.escape, .{})});
    try expectEvents(&.{ "\x1b", "\x1b" }, true, &.{ named(.escape, .{}), named(.escape, .{}) });
    try expectEvents(&.{"\x1b["}, true, &.{altTyped('[')});
    try expectEvents(&.{"\x1bO"}, true, &.{altTyped('O')});
    try expectEvents(&.{ "\x1b", "[A" }, false, &.{named(.arrow_up, .{})});
}

test "a CSI split across feeds decodes once complete" {
    var r = try decode(&.{"\x1b[1;"}, false);
    defer r.deinit();
    try testing.expect(r.pending);
    try expectEvents(&.{ "\x1b[1;", "5A" }, false, &.{named(.arrow_up, ctrl)});
}

test "unknown sequences pass through as their bytes" {
    try expectEvents(&.{"\x1b[5n\x1b[99~\x1b[>1u\x1bOx\x1b[1\x03\xff\x1b[?5h"}, false, &.{
        .{ .unknown = "\x1b[5n" },
        .{ .unknown = "\x1b[99~" },
        .{ .unknown = "\x1b[>1u" },
        .{ .unknown = "\x1bOx" },
        .{ .unknown = "\x1b[1" },
        chord('c', ctrl),
        .{ .unknown = "\xff" },
        .{ .unknown = "\x1b[?5h" },
    });
    try expectEvents(&.{"\x1b[1;"}, true, &.{.{ .unknown = "\x1b[1;" }});
    try expectEvents(&.{"\xe4\xb8"}, true, &.{.{ .unknown = "\xe4\xb8" }});
}
