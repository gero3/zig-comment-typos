const std = @import("std");

pub const CommentSpan = struct {
    path: []const u8,
    line: usize,
    column: usize,
    text: []const u8,
    start: usize,
    end: usize,
};

pub fn scan(allocator: std.mem.Allocator, path: []const u8, source: []const u8) ![]CommentSpan {
    var spans: std.ArrayList(CommentSpan) = .empty;
    errdefer spans.deinit(allocator);

    var offset: usize = 0;
    var line_number: usize = 1;
    while (offset < source.len) : (line_number += 1) {
        const line_start = offset;
        var line_end = offset;
        while (line_end < source.len and source[line_end] != '\n') : (line_end += 1) {}

        var content_end = line_end;
        if (content_end > line_start and source[content_end - 1] == '\r') content_end -= 1;

        const line = source[line_start..content_end];
        if (!isMultilineStringLine(line)) {
            if (findCommentStart(line)) |comment_start| {
                const prefix_len = commentPrefixLen(line, comment_start);
                const text_column_zero_based = comment_start + prefix_len;
                const text_start = line_start + text_column_zero_based;
                try spans.append(allocator, .{
                    .path = path,
                    .line = line_number,
                    .column = text_column_zero_based + 1,
                    .text = source[text_start..content_end],
                    .start = text_start,
                    .end = content_end,
                });
            }
        }

        offset = if (line_end < source.len) line_end + 1 else line_end;
    }

    return spans.toOwnedSlice(allocator);
}

fn isMultilineStringLine(line: []const u8) bool {
    var i: usize = 0;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
    return i + 1 < line.len and line[i] == '\\' and line[i + 1] == '\\';
}

fn commentPrefixLen(line: []const u8, start: usize) usize {
    if (start + 2 < line.len and (line[start + 2] == '/' or line[start + 2] == '!')) return 3;
    return 2;
}

fn findCommentStart(line: []const u8) ?usize {
    const State = enum { code, string, char };
    var state: State = .code;
    var escaped = false;
    var i: usize = 0;

    while (i < line.len) : (i += 1) {
        const char = line[i];
        switch (state) {
            .code => {
                if (char == '"') {
                    state = .string;
                } else if (char == 0x27) {
                    state = .char;
                } else if (char == '/' and i + 1 < line.len and line[i + 1] == '/') {
                    return i;
                }
            },
            .string => {
                if (escaped) {
                    escaped = false;
                } else if (char == '\\') {
                    escaped = true;
                } else if (char == '"') {
                    state = .code;
                }
            },
            .char => {
                if (escaped) {
                    escaped = false;
                } else if (char == '\\') {
                    escaped = true;
                } else if (char == 0x27) {
                    state = .code;
                }
            },
        }
    }

    return null;
}

test "extracts line comment forms and trailing comments" {
    const allocator = std.testing.allocator;
    const source =
        \\// normal comment
        \\/// doc comment
        \\//! container doc comment
        \\const value = 1; // trailing comment
    ;
    const spans = try scan(allocator, "sample.zig", source);
    defer if (spans.len != 0) allocator.free(spans);

    try std.testing.expectEqual(@as(usize, 4), spans.len);
    try std.testing.expectEqualStrings(" normal comment", spans[0].text);
    try std.testing.expectEqual(@as(usize, 1), spans[0].line);
    try std.testing.expectEqual(@as(usize, 3), spans[0].column);
    try std.testing.expectEqualStrings(" doc comment", spans[1].text);
    try std.testing.expectEqual(@as(usize, 4), spans[1].column);
    try std.testing.expectEqualStrings(" container doc comment", spans[2].text);
    try std.testing.expectEqual(@as(usize, 4), spans[2].column);
    try std.testing.expectEqualStrings(" trailing comment", spans[3].text);
    try std.testing.expectEqual(@as(usize, 4), spans[3].line);
    try std.testing.expectEqual(@as(usize, 20), spans[3].column);
}

test "ignores comment-like text in strings and character literals" {
    const allocator = std.testing.allocator;
    const source =
        \\const url = "https://example.com/foo";
        \\const text = "hello \"// not a comment\"";
        \\const slash = '/';
    ;
    const spans = try scan(allocator, "sample.zig", source);
    defer if (spans.len != 0) allocator.free(spans);

    try std.testing.expectEqual(@as(usize, 0), spans.len);
}

test "ignores Zig multiline string content lines" {
    const allocator = std.testing.allocator;
    const source =
        \\const message =
        \\    \\this // is string content, not a comment
        \\;
    ;
    const spans = try scan(allocator, "sample.zig", source);
    defer if (spans.len != 0) allocator.free(spans);

    try std.testing.expectEqual(@as(usize, 0), spans.len);
}

test "extracts a trailing comment after a string containing slashes" {
    const allocator = std.testing.allocator;
    const source = "const url = \"https://example.com/foo\"; // teh comment\n";
    const spans = try scan(allocator, "sample.zig", source);
    defer if (spans.len != 0) allocator.free(spans);

    try std.testing.expectEqual(@as(usize, 1), spans.len);
    try std.testing.expectEqualStrings(" teh comment", spans[0].text);
}
