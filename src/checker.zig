const std = @import("std");
const scanner = @import("scanner.zig");
const words = @import("words.zig");
const rules = @import("rules.zig");

pub const Diagnostic = struct {
    path: []const u8,
    line: usize,
    column: usize,
    typo: []const u8,
    correction: ?[]const u8,
    start: usize,
    end: usize,
};

pub fn checkSource(
    allocator: std.mem.Allocator,
    path: []const u8,
    source: []const u8,
    rule_set: *const rules.RuleSet,
) ![]Diagnostic {
    const spans = try scanner.scan(allocator, path, source);
    defer if (spans.len != 0) allocator.free(spans);

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    errdefer diagnostics.deinit(allocator);

    for (spans) |span| {
        const candidates = try words.extract(allocator, span.text);
        defer words.deinitCandidates(allocator, candidates);

        for (candidates) |candidate| {
            if (rule_set.get(candidate.normalized)) |rule| {
                const start = span.start + candidate.offset;
                const end = start + candidate.text.len;
                try diagnostics.append(allocator, .{
                    .path = path,
                    .line = span.line,
                    .column = span.column + candidate.offset,
                    .typo = source[start..end],
                    .correction = rule.correction,
                    .start = start,
                    .end = end,
                });
            }
        }
    }

    std.mem.sort(Diagnostic, diagnostics.items, {}, lessDiagnostic);
    return diagnostics.toOwnedSlice(allocator);
}

pub fn formatDiagnostic(writer: *std.Io.Writer, diagnostic: Diagnostic) !void {
    try writer.print("{s}:{d}:{d} typo \"{s}\"", .{
        diagnostic.path,
        diagnostic.line,
        diagnostic.column,
        diagnostic.typo,
    });
    if (diagnostic.correction) |correction| {
        try writer.print(", expected \"{s}\"", .{correction});
    }
    try writer.print("\n", .{});
}

fn lessDiagnostic(_: void, left: Diagnostic, right: Diagnostic) bool {
    switch (std.mem.order(u8, left.path, right.path)) {
        .lt => return true,
        .gt => return false,
        .eq => {},
    }
    if (left.line != right.line) return left.line < right.line;
    return left.column < right.column;
}

test "reports typo diagnostics with exact typo columns" {
    const allocator = std.testing.allocator;
    var rule_set = try rules.parse(allocator,
        \\teh=the
        \\speling
    );
    defer rule_set.deinit();

    const source =
        \\const text = "teh";
        \\// teh speling bug
    ;
    const diagnostics = try checkSource(allocator, "src/main.zig", source, &rule_set);
    defer if (diagnostics.len != 0) allocator.free(diagnostics);

    try std.testing.expectEqual(@as(usize, 2), diagnostics.len);
    try std.testing.expectEqual(@as(usize, 2), diagnostics[0].line);
    try std.testing.expectEqual(@as(usize, 4), diagnostics[0].column);
    try std.testing.expectEqualStrings("teh", diagnostics[0].typo);
    try std.testing.expectEqualStrings("the", diagnostics[0].correction.?);
    try std.testing.expectEqual(@as(usize, 8), diagnostics[1].column);
    try std.testing.expectEqualStrings("speling", diagnostics[1].typo);
    try std.testing.expect(diagnostics[1].correction == null);
}

test "formats diagnostics deterministically" {
    const allocator = std.testing.allocator;
    var output = std.Io.Writer.Allocating.init(allocator);
    defer output.deinit();

    try formatDiagnostic(&output.writer, .{
        .path = "src/main.zig",
        .line = 42,
        .column = 9,
        .typo = "teh",
        .correction = "the",
        .start = 0,
        .end = 3,
    });

    try std.testing.expectEqualStrings(
        "src/main.zig:42:9 typo \"teh\", expected \"the\"\n",
        output.written(),
    );
}
