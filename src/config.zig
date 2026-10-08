//! Bounded, strictly validated configuration. Parsing never mutates live state.
const std = @import("std");
const prefix = @import("prefix.zig");
const paths = @import("paths.zig");
const theme_mod = @import("theme.zig");

pub const template = @embedFile("config.example.toml");
pub const guide = @embedFile("config-guide.txt");
pub const Config = struct {
    keys: prefix.Keymap = .{},
    sidebar_width: ?u16 = null,
    pane_style: @import("layout.zig").PaneStyle = .compact,
    scrollback_lines: u32 = 50_000,
    theme: *const theme_mod.Theme = theme_mod.default,
};

pub fn path(gpa: std.mem.Allocator, env: *const std.process.Environ.Map) ![]const u8 {
    if (env.get("XDG_CONFIG_HOME")) |x| if (std.fs.path.isAbsolute(x)) return std.fmt.allocPrint(gpa, "{s}/kiwa/config.toml", .{x});
    const home = env.get("HOME") orelse return error.NoHome;
    if (home.len == 0) return error.NoHome;
    if (!std.fs.path.isAbsolute(home)) return error.HomeMustBeAbsolute;
    return std.fmt.allocPrint(gpa, "{s}/.config/kiwa/config.toml", .{home});
}

/// Exclusive creation preserves existing user files, including empty files.
pub fn ensure(gpa: std.mem.Allocator, io: std.Io, name: []const u8) !void {
    try paths.makePath(gpa, std.fs.path.dirname(name).?);
    const file = std.Io.Dir.cwd().createFile(io, name, .{ .exclusive = true, .permissions = .fromMode(0o600) }) catch |e| switch (e) {
        error.PathAlreadyExists => return,
        else => return e,
    };
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var w = file.writer(io, &buf);
    try w.interface.writeAll(template);
    try w.interface.flush();
}

pub fn load(gpa: std.mem.Allocator, io: std.Io, name: []const u8, line: *usize) !Config {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, name, gpa, .limited(64 * 1024)) catch |e| switch (e) {
        error.FileNotFound => return .{},
        else => return e,
    };
    defer gpa.free(bytes);
    return parse(bytes, line);
}

fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r");
}

/// Configuration intentionally accepts a documented, small TOML subset:
/// tables, single-line literal/basic strings without escapes, decimal integers.
fn quoted(s: []const u8) ![]const u8 {
    if (s.len < 2 or (s[0] != '"' and s[0] != '\'') or s[s.len - 1] != s[0]) return error.ExpectedQuotedString;
    const body = s[1 .. s.len - 1];
    for (body) |c| if (c < 32 or c == s[0] or (s[0] == '"' and c == '\\')) return error.UnsupportedString;
    return body;
}

pub fn parse(bytes: []const u8, line_number: *usize) !Config {
    var out: Config = .{};
    const Section = enum { root, keys, bindings, ui, terminal };
    var section: Section = .root;
    var sections: u8 = 0;
    var seen: u8 = 0;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    line_number.* = 0;
    while (lines.next()) |raw| {
        line_number.* += 1;
        var quote: u8 = 0;
        var end = raw.len;
        var equal: ?usize = null;
        for (raw, 0..) |c, i| {
            if (quote != 0) {
                if (c == quote) quote = 0;
            } else if (c == '"' or c == '\'') {
                quote = c;
            } else if (c == '#') {
                end = i;
                break;
            } else if (c == '=' and equal == null) {
                equal = i;
            }
        }
        const text = trim(raw[0..end]);
        if (text.len == 0) continue;
        if (text[0] == '[') {
            if (text[text.len - 1] != ']') return error.InvalidTable;
            section = std.meta.stringToEnum(Section, trim(text[1 .. text.len - 1])) orelse return error.UnknownTable;
            if (section == .root) return error.UnknownTable;
            const bit = @as(u8, 1) << @as(u3, @intCast(@intFromEnum(section)));
            if (sections & bit != 0) return error.DuplicateTable;
            sections |= bit;
            continue;
        }
        const eq = equal orelse return error.ExpectedAssignment;
        const key = trim(raw[0..eq]);
        const value = trim(raw[eq + 1 .. end]);
        if (section == .bindings) {
            var chord = try quoted(key);
            const prefixed = std.mem.startsWith(u8, chord, "prefix+");
            if (prefixed) chord = chord[7..];
            const trigger = try prefix.parseTrigger(chord);
            for (out.keys.overrides[0..out.keys.len]) |b| if (b.prefixed == prefixed and b.trigger.eql(trigger)) return error.DuplicateBinding;
            const name = try quoted(value);
            const action = if (std.mem.eql(u8, name, "none")) null else prefix.actionNamed(name) orelse return error.UnknownAction;
            if (out.keys.len == out.keys.overrides.len) return error.TooManyBindings;
            out.keys.overrides[out.keys.len] = .{ .trigger = trigger, .prefixed = prefixed, .action = action };
            out.keys.len += 1;
        } else {
            const bit: u8 = if (section == .keys and std.mem.eql(u8, key, "prefix")) 1 else if (section == .ui and std.mem.eql(u8, key, "sidebar_width")) 2 else if (section == .terminal and std.mem.eql(u8, key, "scrollback_lines")) 4 else if (section == .ui and std.mem.eql(u8, key, "pane_style")) 8 else if (section == .ui and std.mem.eql(u8, key, "theme")) 16 else return error.UnknownSetting;
            if (seen & bit != 0) return error.DuplicateSetting;
            seen |= bit;
            switch (bit) {
                1 => out.keys.prefix_key = try prefix.parseTrigger(try quoted(value)),
                8 => out.pane_style = std.meta.stringToEnum(@import("layout.zig").PaneStyle, try quoted(value)) orelse return error.InvalidPaneStyle,
                16 => out.theme = theme_mod.named(try quoted(value)) orelse return error.UnknownTheme,
                2, 4 => {
                    if (value.len == 0) return error.ExpectedInteger;
                    for (value) |c| if (!std.ascii.isDigit(c)) return error.ExpectedInteger;
                    const n = std.fmt.parseInt(u32, value, 10) catch return error.IntegerOutOfRange;
                    if (bit == 2) {
                        if (n < 12 or n > 200) return error.SidebarWidthOutOfRange;
                        out.sidebar_width = @intCast(n);
                    } else {
                        if (n > 1_000_000) return error.ScrollbackOutOfRange;
                        out.scrollback_lines = n;
                    }
                },
                else => unreachable,
            }
        }
    }
    // The prefix always wins; reject unreachable bindings instead of hiding them.
    for (out.keys.overrides[0..out.keys.len]) |b| {
        if (b.action != null and b.trigger.eql(out.keys.prefix_key)) return error.BindingConflictsWithPrefix;
    }
    const k: @import("input.zig").Key = .{ .code = out.keys.prefix_key.code, .mods = out.keys.prefix_key.mods };
    if (out.keys.lookup(k, false) != null) return error.BindingConflictsWithPrefix;
    return out;
}

/// Returns `bytes` with `[ui] theme` set to `name`: the existing setting
/// replaced, or a new one added under `[ui]`, which is added if missing.
/// Every other line is kept as it was.
pub fn withTheme(gpa: std.mem.Allocator, bytes: []const u8, name: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    const setting = try std.fmt.allocPrint(gpa, "theme = \"{s}\"", .{name});
    defer gpa.free(setting);
    var in_ui = false;
    var done = false;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    var first = true;
    while (lines.next()) |raw| {
        if (!first) try out.append(gpa, '\n');
        first = false;
        const text = trim(raw);
        if (text.len > 0 and text[0] == '[') {
            in_ui = std.mem.eql(u8, trim(text[1 .. std.mem.indexOfScalar(u8, text, ']') orelse text.len]), "ui");
            try out.appendSlice(gpa, raw);
            if (in_ui and !done) {
                // Added right under the header; a later `theme` line in the
                // table is replaced below instead, so look ahead first.
                var rest = lines;
                const has = while (rest.next()) |next| {
                    const t = trim(next);
                    if (t.len > 0 and t[0] == '[') break false;
                    if (isThemeLine(t)) break true;
                } else false;
                if (!has) {
                    try out.print(gpa, "\n{s}", .{setting});
                    done = true;
                }
            }
            continue;
        }
        if (in_ui and !done and isThemeLine(text)) {
            try out.appendSlice(gpa, setting);
            done = true;
            continue;
        }
        try out.appendSlice(gpa, raw);
    }
    if (!done) {
        if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') try out.append(gpa, '\n');
        try out.print(gpa, "\n[ui]\n{s}\n", .{setting});
    }
    return out.toOwnedSlice(gpa);
}

/// Whether trimmed line `t` sets `theme`, not just mentions it in a comment.
fn isThemeLine(t: []const u8) bool {
    if (t.len == 0 or t[0] == '#') return false;
    const eq = std.mem.indexOfScalar(u8, t, '=') orelse return false;
    return std.mem.eql(u8, trim(t[0..eq]), "theme");
}

/// Sets `[ui] theme` in the configuration file `name`, creating it from the
/// template when missing. The result must still parse, and it replaces the
/// file atomically.
pub fn saveTheme(gpa: std.mem.Allocator, io: std.Io, name: []const u8, theme: []const u8) !void {
    try ensure(gpa, io, name);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, name, gpa, .limited(64 * 1024));
    defer gpa.free(bytes);
    const edited = try withTheme(gpa, bytes, theme);
    defer gpa.free(edited);
    var line: usize = 0;
    _ = try parse(edited, &line);
    const tmp = try std.fmt.allocPrint(gpa, "{s}.tmp", .{name});
    defer gpa.free(tmp);
    const cwd = std.Io.Dir.cwd();
    cwd.deleteFile(io, tmp) catch |e| switch (e) {
        error.FileNotFound => {},
        else => return e,
    };
    {
        const file = try cwd.createFile(io, tmp, .{ .exclusive = true, .permissions = .fromMode(0o600) });
        defer file.close(io);
        var buf: [4096]u8 = undefined;
        var w = file.writer(io, &buf);
        try w.interface.writeAll(edited);
        try w.interface.flush();
    }
    try cwd.rename(tmp, cwd, name, io);
}

test "setting the theme replaces it in [ui], adds it there, or adds [ui]" {
    const gpa = std.testing.allocator;
    const cases = [_][2][]const u8{
        .{ "[ui]\ntheme = 'nord'\nsidebar_width = 30\n", "[ui]\ntheme = \"dracula\"\nsidebar_width = 30\n" },
        .{ "[keys]\nprefix = 'ctrl+a'\n\n[ui]\n# theme = 'x'\nsidebar_width = 30\n", "[keys]\nprefix = 'ctrl+a'\n\n[ui]\ntheme = \"dracula\"\n# theme = 'x'\nsidebar_width = 30\n" },
        .{ "[keys]\nprefix = 'ctrl+a'", "[keys]\nprefix = 'ctrl+a'\n\n[ui]\ntheme = \"dracula\"\n" },
        .{ "", "\n[ui]\ntheme = \"dracula\"\n" },
        .{ "[ui]\n[terminal]\ntheme_x = 1\n", "[ui]\ntheme = \"dracula\"\n[terminal]\ntheme_x = 1\n" },
    };
    var line: usize = 0;
    for (cases) |c| {
        const got = try withTheme(gpa, c[0], "dracula");
        defer gpa.free(got);
        try std.testing.expectEqualStrings(c[1], got);
    }
    const from_template = try withTheme(gpa, template, "nord");
    defer gpa.free(from_template);
    try std.testing.expectEqualStrings("nord", (try parse(from_template, &line)).theme.name);
    try std.testing.expectError(error.UnknownTheme, parse("[ui]\ntheme = 'nope'", &line));
    try std.testing.expectEqualStrings("tokyo-night", (try parse("[ui]\ntheme = 'tokyo-night'", &line)).theme.name);
}

test "pane styles are typed, optional, unique, and the default toggle can be overridden or disabled" {
    var line: usize = 0;
    const defaults = try parse("", &line);
    try std.testing.expectEqual(.compact, defaults.pane_style);
    try std.testing.expectEqualDeep(prefix.Action.toggle_pane_style, defaults.keys.lookup(.typed('f'), true).?);
    try std.testing.expectEqual(.compact, (try parse("[ui]\npane_style = 'compact'", &line)).pane_style);
    const c = try parse("[ui]\npane_style = 'framed'\n[bindings]\n'prefix+f' = 'new_tab'", &line);
    try std.testing.expectEqual(.framed, c.pane_style);
    const prefix_key: @import("input.zig").Event = .{ .key = .{ .code = .{ .char = 'b' }, .mods = .{ .ctrl = true } } };
    var overridden: prefix.Prefix = .{ .keymap = c.keys };
    _ = overridden.feed(prefix_key);
    try std.testing.expectEqualDeep(prefix.Outcome{ .action = .new_tab }, overridden.feed(.{ .key = .typed('f') }));
    const disabled = try parse("[bindings]\n'prefix+f' = 'none'", &line);
    var unbound: prefix.Prefix = .{ .keymap = disabled.keys };
    _ = unbound.feed(prefix_key);
    try std.testing.expectEqualDeep(prefix.Outcome.none, unbound.feed(.{ .key = .typed('f') }));
    try std.testing.expectError(error.InvalidPaneStyle, parse("[ui]\npane_style = 'Frame'", &line));
    try std.testing.expectError(error.ExpectedQuotedString, parse("[ui]\npane_style = 1", &line));
    try std.testing.expectError(error.DuplicateSetting, parse("[ui]\npane_style = 'framed'\npane_style = 'compact'", &line));
}

test "template keeps built-in defaults" {
    var line: usize = 0;
    const c = try parse(template, &line);
    try std.testing.expectEqual(@as(usize, 0), c.keys.len);
    try std.testing.expect(c.sidebar_width == null);
}

test "configuration validates duplicates, unknown settings, and ranges" {
    var line: usize = 0;
    try std.testing.expectError(error.UnknownSetting, parse("[ui]\nwidht = 30", &line));
    try std.testing.expectEqual(@as(usize, 2), line);
    try std.testing.expectError(error.DuplicateSetting, parse("[ui]\nsidebar_width = 30\nsidebar_width = 40", &line));
    try std.testing.expectError(error.SidebarWidthOutOfRange, parse("[ui]\nsidebar_width = 0", &line));
    try std.testing.expectError(error.UnknownAction, parse("[bindings]\n'prefix+c' = 'typo'", &line));
    try std.testing.expectError(error.BindingConflictsWithPrefix, parse("[keys]\nprefix = 'alt+h'", &line));
    try std.testing.expectError(error.BindingConflictsWithPrefix, parse("[keys]\nprefix = 'alt+h'\n[bindings]\n'alt+h' = 'help'", &line));
    _ = try parse("[keys]\nprefix = 'alt+h'\n[bindings]\n'alt+h' = 'none'", &line);
}

test "custom prefix, binding, unbind, and quoted comment character" {
    var line: usize = 0;
    const c = try parse("[keys]\nprefix = 'ctrl+a'\n[bindings]\n'prefix+#' = 'split_right' # comment\n'alt+h' = 'none'\n[terminal]\nscrollback_lines = 1000\n[ui]\nsidebar_width = 30", &line);
    try std.testing.expectEqual(@as(usize, 2), c.keys.len);
    try std.testing.expectEqual(@as(u32, 1000), c.scrollback_lines);
    try std.testing.expectEqual(@as(?u16, 30), c.sidebar_width);
}

test "punctuation aliases are one binding in legacy and extended keyboards" {
    var line: usize = 0;
    try std.testing.expectError(error.DuplicateBinding, parse("[bindings]\n'prefix+|' = 'none'\n'prefix+shift+\\' = 'help'", &line));
    const c = try parse("[bindings]\n'prefix+|' = 'none'", &line);
    try std.testing.expect(c.keys.lookup(.{ .code = .{ .char = '\\' }, .mods = .{ .shift = true } }, true) == null);
}

test "config path respects XDG and falls back for an empty override" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    var env: std.process.Environ.Map = .init(t.allocator);
    defer env.deinit();
    try env.put("HOME", "/home/example");
    try t.expectEqualStrings("/home/example/.config/kiwa/config.toml", try path(arena.allocator(), &env));
    try env.put("XDG_CONFIG_HOME", "/configs");
    try t.expectEqualStrings("/configs/kiwa/config.toml", try path(arena.allocator(), &env));
    try env.put("XDG_CONFIG_HOME", "relative");
    try t.expectEqualStrings("/home/example/.config/kiwa/config.toml", try path(arena.allocator(), &env));
    try env.put("XDG_CONFIG_HOME", "");
    try t.expectEqualStrings("/home/example/.config/kiwa/config.toml", try path(arena.allocator(), &env));
}

test "unsupported strings and tables fail instead of silently changing meaning" {
    var line: usize = 0;
    try std.testing.expectError(error.UnsupportedString, parse("[keys]\nprefix = \"ctrl+\\u0061\"", &line));
    try std.testing.expectError(error.UnknownTable, parse("[typo]\nprefix = 'ctrl+a'", &line));
    try std.testing.expectError(error.DuplicateTable, parse("[keys]\n[keys]", &line));
    try std.testing.expectError(error.InvalidKey, parse("[keys]\nprefix = 'ctrl+ctrl+a'", &line));
    try std.testing.expectError(error.ScrollbackOutOfRange, parse("[terminal]\nscrollback_lines = 1000001", &line));
}

test "creation is exclusive and missing configuration loads defaults" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", arena.allocator());
    const name = try std.fs.path.join(arena.allocator(), &.{ root, "nested", "config.toml" });
    var line: usize = 0;
    try t.expectEqual(@as(u32, 50_000), (try load(t.allocator, t.io, name, &line)).scrollback_lines);
    try ensure(t.allocator, t.io, name);
    try t.expectEqual(@as(usize, 0), (try load(t.allocator, t.io, name, &line)).keys.len);
    try std.Io.Dir.cwd().writeFile(t.io, .{ .sub_path = name, .data = "" });
    try ensure(t.allocator, t.io, name);
    const content = try std.Io.Dir.cwd().readFileAlloc(t.io, name, t.allocator, .limited(65536));
    defer t.allocator.free(content);
    try t.expectEqual(@as(usize, 0), content.len);
}
