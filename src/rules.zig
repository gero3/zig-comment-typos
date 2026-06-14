const std = @import("std");

pub const Rule = struct {
    typo: []const u8,
    correction: ?[]const u8,
};

pub const RuleSet = struct {
    allocator: std.mem.Allocator,
    map: std.StringHashMap(Rule),

    pub fn init(allocator: std.mem.Allocator) RuleSet {
        return .{
            .allocator = allocator,
            .map = std.StringHashMap(Rule).init(allocator),
        };
    }

    pub fn deinit(self: *RuleSet) void {
        var it = self.map.iterator();
        while (it.next()) |entry| {
            const rule = entry.value_ptr.*;
            self.allocator.free(rule.typo);
            if (rule.correction) |correction| self.allocator.free(correction);
        }
        self.map.deinit();
        self.* = undefined;
    }

    pub fn get(self: *const RuleSet, lowercase_typo: []const u8) ?Rule {
        return self.map.get(lowercase_typo);
    }

    fn put(self: *RuleSet, typo: []const u8, correction: ?[]const u8) !void {
        if (self.map.contains(typo)) return error.DuplicateRule;
        try self.map.put(typo, .{
            .typo = typo,
            .correction = correction,
        });
    }
};

pub const default_rule_source =
    \\teh=the
    \\recieve=receive
    \\seperate=separate
    \\adress=address
    \\occured=occurred
    \\speling
    \\jsut=just
;

pub fn defaultRules(allocator: std.mem.Allocator) !RuleSet {
    return parse(allocator, default_rule_source);
}

pub fn parse(allocator: std.mem.Allocator, source: []const u8) !RuleSet {
    var set = RuleSet.init(allocator);
    errdefer set.deinit();

    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;

        const eq_index = std.mem.indexOfScalar(u8, trimmed, '=');
        const raw_typo = if (eq_index) |idx|
            std.mem.trim(u8, trimmed[0..idx], " \t")
        else
            trimmed;
        if (raw_typo.len == 0) return error.InvalidRule;

        const typo = try lowerAlloc(allocator, raw_typo);
        errdefer allocator.free(typo);

        const correction = if (eq_index) |idx| blk: {
            const raw_correction = std.mem.trim(u8, trimmed[idx + 1 ..], " \t");
            if (raw_correction.len == 0) return error.InvalidRule;
            break :blk try allocator.dupe(u8, raw_correction);
        } else null;
        errdefer if (correction) |value| allocator.free(value);

        try set.put(typo, correction);
    }

    return set;
}

pub fn lowerAlloc(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, text.len);
    for (text, 0..) |char, i| out[i] = asciiLower(char);
    return out;
}

fn asciiLower(char: u8) u8 {
    if (char >= 'A' and char <= 'Z') return char + ('a' - 'A');
    return char;
}

test "parses fixable and unfixable rules" {
    var set = try parse(std.testing.allocator,
        \\teh
        \\recieve=receive
        \\
    );
    defer set.deinit();

    const teh = set.get("teh").?;
    try std.testing.expectEqualStrings("teh", teh.typo);
    try std.testing.expect(teh.correction == null);

    const recieve = set.get("recieve").?;
    try std.testing.expectEqualStrings("recieve", recieve.typo);
    try std.testing.expectEqualStrings("receive", recieve.correction.?);
}

test "normalizes rule keys to lowercase" {
    var set = try parse(std.testing.allocator, "TeH=the\n");
    defer set.deinit();

    try std.testing.expect(set.get("TeH") == null);
    try std.testing.expect(set.get("teh") != null);
}

test "rejects invalid and duplicate rules" {
    try std.testing.expectError(error.InvalidRule, parse(std.testing.allocator, "=the\n"));
    try std.testing.expectError(error.DuplicateRule, parse(std.testing.allocator,
        \\teh
        \\teh=the
    ));
}
