const std = @import("std");
const rules = @import("rules.zig");

pub const Candidate = struct {
    text: []const u8,
    normalized: []u8,
    offset: usize,
};

pub fn deinitCandidates(allocator: std.mem.Allocator, candidates: []Candidate) void {
    for (candidates) |candidate| allocator.free(candidate.normalized);
    if (candidates.len != 0) allocator.free(candidates);
}

pub fn extract(allocator: std.mem.Allocator, comment: []const u8) ![]Candidate {
    var candidates: std.ArrayList(Candidate) = .empty;
    errdefer {
        for (candidates.items) |candidate| allocator.free(candidate.normalized);
        candidates.deinit(allocator);
    }

    var i: usize = 0;
    while (i < comment.len) {
        while (i < comment.len and isWhitespace(comment[i])) : (i += 1) {}
        if (i >= comment.len) break;

        const raw_start = i;
        while (i < comment.len and !isWhitespace(comment[i])) : (i += 1) {}
        const raw_end = i;
        const raw = comment[raw_start..raw_end];

        const trimmed = trimToken(raw);
        if (trimmed.len() == 0) continue;

        const word_offset = raw_start + trimmed.start;
        const word = raw[trimmed.start..trimmed.end];
        if (shouldSkip(raw, word)) continue;

        const normalized = try rules.lowerAlloc(allocator, word);
        errdefer allocator.free(normalized);
        try candidates.append(allocator, .{
            .text = word,
            .normalized = normalized,
            .offset = word_offset,
        });
    }

    return candidates.toOwnedSlice(allocator);
}

const Trimmed = struct {
    start: usize,
    end: usize,

    fn len(self: Trimmed) usize {
        return self.end - self.start;
    }
};

fn trimToken(raw: []const u8) Trimmed {
    var start: usize = 0;
    while (start < raw.len and !isAsciiAlnum(raw[start])) : (start += 1) {}

    var end = raw.len;
    while (end > start and !isAsciiAlnum(raw[end - 1])) : (end -= 1) {}

    return .{ .start = start, .end = end };
}

fn shouldSkip(raw: []const u8, word: []const u8) bool {
    if (word.len < 3) return true;
    if (looksLikeUrl(raw)) return true;

    var uppercase_count: usize = 0;
    var lowercase_count: usize = 0;

    for (word, 0..) |char, index| {
        if (char >= '0' and char <= '9') return true;
        if (char == '_') return true;
        if (char == '@' or char == '/' or char == '\\' or char == '.') return true;
        if (!isAsciiAlpha(char)) return true;

        if (char >= 'A' and char <= 'Z') {
            uppercase_count += 1;
            if (index != 0) return true;
        } else {
            lowercase_count += 1;
        }
    }

    if (uppercase_count > 1) return true;
    if (uppercase_count > 0 and lowercase_count == 0) return true;
    return false;
}

fn looksLikeUrl(raw: []const u8) bool {
    return std.mem.indexOf(u8, raw, "://") != null;
}

fn isWhitespace(char: u8) bool {
    return char == ' ' or char == '\t' or char == '\n' or char == '\r';
}

fn isAsciiAlnum(char: u8) bool {
    return isAsciiAlpha(char) or (char >= '0' and char <= '9');
}

fn isAsciiAlpha(char: u8) bool {
    return (char >= 'a' and char <= 'z') or (char >= 'A' and char <= 'Z');
}

test "extracts prose words with offsets and lowercase normalization" {
    const allocator = std.testing.allocator;
    const candidates = try extract(allocator, " teh, Bug.");
    defer deinitCandidates(allocator, candidates);

    try std.testing.expectEqual(@as(usize, 2), candidates.len);
    try std.testing.expectEqualStrings("teh", candidates[0].text);
    try std.testing.expectEqualStrings("teh", candidates[0].normalized);
    try std.testing.expectEqual(@as(usize, 1), candidates[0].offset);
    try std.testing.expectEqualStrings("Bug", candidates[1].text);
    try std.testing.expectEqualStrings("bug", candidates[1].normalized);
}

test "skips noisy code-like and metadata-like tokens" {
    const allocator = std.testing.allocator;
    const candidates = try extract(allocator, "https://teh.example user@teh.test src/teh.zig v1 teh_bug ab CamelCase mixedCase HTTP");
    defer deinitCandidates(allocator, candidates);

    try std.testing.expectEqual(@as(usize, 0), candidates.len);
}
