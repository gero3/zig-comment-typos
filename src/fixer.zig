const std = @import("std");

pub const Replacement = struct {
    start: usize,
    end: usize,
    correction: []const u8,
};

pub fn canFix(typo: []const u8, correction: []const u8) bool {
    return isLowercaseAsciiWord(typo) and isLowercaseAsciiWord(correction);
}

pub fn applyReplacements(
    allocator: std.mem.Allocator,
    source: []const u8,
    replacements: []const Replacement,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var cursor: usize = 0;
    for (replacements) |replacement| {
        if (replacement.start < cursor or replacement.end < replacement.start or replacement.end > source.len) {
            return error.InvalidReplacement;
        }
        try out.appendSlice(allocator, source[cursor..replacement.start]);
        try out.appendSlice(allocator, replacement.correction);
        cursor = replacement.end;
    }
    try out.appendSlice(allocator, source[cursor..]);

    return out.toOwnedSlice(allocator);
}

fn isLowercaseAsciiWord(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text) |char| {
        if (char < 'a' or char > 'z') return false;
    }
    return true;
}

test "applies replacements without shifting later spans" {
    const allocator = std.testing.allocator;
    const fixed = try applyReplacements(allocator, "// teh and teh\n", &.{
        .{ .start = 3, .end = 6, .correction = "the" },
        .{ .start = 11, .end = 14, .correction = "the" },
    });
    defer if (fixed.len != 0) allocator.free(fixed);

    try std.testing.expectEqualStrings("// the and the\n", fixed);
}

test "only lowercase explicit corrections are fixable" {
    try std.testing.expect(canFix("teh", "the"));
    try std.testing.expect(!canFix("Teh", "the"));
    try std.testing.expect(!canFix("teh", "The"));
}
