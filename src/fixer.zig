const std = @import("std");

pub const Replacement = struct {
    start: usize,
    end: usize,
    correction: []const u8,
};

pub fn canFix(typo: []const u8, correction: []const u8) bool {
    return isLowercaseAsciiWord(correction) and (isLowercaseAsciiWord(typo) or isTitlecaseAsciiWord(typo));
}

pub fn correctionFor(allocator: std.mem.Allocator, typo: []const u8, correction: []const u8) !?[]u8 {
    if (!canFix(typo, correction)) return null;

    const fixed = try allocator.dupe(u8, correction);
    if (isTitlecaseAsciiWord(typo)) {
        fixed[0] = asciiUpper(fixed[0]);
    }
    return fixed;
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

fn isTitlecaseAsciiWord(text: []const u8) bool {
    if (text.len == 0) return false;
    if (text[0] < 'A' or text[0] > 'Z') return false;
    for (text[1..]) |char| {
        if (char < 'a' or char > 'z') return false;
    }
    return true;
}

fn asciiUpper(char: u8) u8 {
    if (char >= 'a' and char <= 'z') return char - ('a' - 'A');
    return char;
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

test "lowercase and titlecase typos with lowercase explicit corrections are fixable" {
    try std.testing.expect(canFix("teh", "the"));
    try std.testing.expect(canFix("Teh", "the"));
    try std.testing.expect(!canFix("teh", "The"));
    try std.testing.expect(!canFix("TEH", "the"));
}

test "allocates replacement text with matching capitalization" {
    const allocator = std.testing.allocator;

    const lowercase = (try correctionFor(allocator, "teh", "the")).?;
    defer allocator.free(lowercase);
    try std.testing.expectEqualStrings("the", lowercase);

    const titlecase = (try correctionFor(allocator, "Teh", "the")).?;
    defer allocator.free(titlecase);
    try std.testing.expectEqualStrings("The", titlecase);
}
