//! Bounded, strictly validated configuration. Parsing never mutates live state.
const std = @import("std");
const prefix = @import("prefix.zig");
const paths = @import("paths.zig");

pub const template = @embedFile("config.example.toml");
pub const guide = @embedFile("config-guide.txt");
pub const Config = struct {
    keys: prefix.Keymap = .{},
    sidebar_width: ?u16 = null,
    pane_style: @import("layout.zig").PaneStyle = .compact,
    scrollback_lines: u32 = 50_000,
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
            const bit: u8 = if (section == .keys and std.mem.eql(u8, key, "prefix")) 1 else if (section == .ui and std.mem.eql(u8, key, "sidebar_width")) 2 else if (section == .terminal and std.mem.eql(u8, key, "scrollback_lines")) 4 else if (section == .ui and std.mem.eql(u8, key, "pane_style")) 8 else return error.UnknownSetting;
            if (seen & bit != 0) return error.DuplicateSetting;
            seen |= bit;
            switch (bit) {
                1 => out.keys.prefix_key = try prefix.parseTrigger(try quoted(value)),
                8 => out.pane_style = std.meta.stringToEnum(@import("layout.zig").PaneStyle, try quoted(value)) orelse return error.InvalidPaneStyle,
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
        if (b.trigger.eql(out.keys.prefix_key)) return error.BindingConflictsWithPrefix;
    }
    const k: @import("input.zig").Key = .{ .code = out.keys.prefix_key.code, .mods = out.keys.prefix_key.mods };
    if (out.keys.lookup(k, false) != null) return error.BindingConflictsWithPrefix;
    return out;
}

test "pane styles are typed, optional, unique, and bindable without a default key" {
    var line: usize = 0;
    try std.testing.expectEqual(.compact, (try parse("", &line)).pane_style);
    try std.testing.expectEqual(.compact, (try parse("[ui]\npane_style = 'compact'", &line)).pane_style);
    const c = try parse("[ui]\npane_style = 'framed'\n[bindings]\n'prefix+f' = 'toggle_pane_style'", &line);
    try std.testing.expectEqual(.framed, c.pane_style);
    try std.testing.expectEqualDeep(prefix.Action.toggle_pane_style, c.keys.lookup(.typed('f'), true).?);
    try std.testing.expect((Config{}).keys.lookup(.typed('f'), true) == null);
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
