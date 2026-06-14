const std = @import("std");
const checker = @import("checker.zig");
const fixer = @import("fixer.zig");
const rules = @import("rules.zig");
const scanner = @import("scanner.zig");

const max_file_bytes = 64 * 1024 * 1024;
const max_rules_file_bytes = 1024 * 1024;

pub const RunResult = struct {
    output: []u8,
    findings: usize,
    fixed: usize,
    unfixed: usize,

    pub fn deinit(self: *RunResult, allocator: std.mem.Allocator) void {
        if (self.output.len > 0) allocator.free(self.output);
        self.* = undefined;
    }
};

const Options = struct {
    path: []const u8,
    fix: bool,
    extract_text: bool,
    rules_path: ?[]const u8,
};

pub fn main(init: std.process.Init) !void {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(init.io, &stderr_buffer);
    const stderr = &stderr_writer.interface;

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const options = parseArgs(args) catch {
        try printUsage(stdout);
        try stdout.flush();
        std.process.exit(2);
    };

    var result = runProjectForOptions(init.gpa, init.io, options) catch |err| {
        try printRunError(stderr, options.path, err);
        try stderr.flush();
        std.process.exit(2);
    };
    defer result.deinit(init.gpa);

    try stdout.writeAll(result.output);
    try stdout.flush();

    if (result.unfixed > 0) std.process.exit(1);
}

fn parseArgs(args: []const [:0]const u8) !Options {
    var path: ?[]const u8 = null;
    var fix = false;
    var extract_text = false;
    var rules_path: ?[]const u8 = null;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--fix")) {
            fix = true;
        } else if (std.mem.eql(u8, arg, "--extract-text")) {
            extract_text = true;
        } else if (std.mem.eql(u8, arg, "--rules")) {
            if (rules_path != null) return error.InvalidArgs;
            i += 1;
            if (i >= args.len) return error.InvalidArgs;
            rules_path = args[i];
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return error.InvalidArgs;
        } else if (path == null) {
            path = arg;
        } else {
            return error.InvalidArgs;
        }
    }

    if (fix and extract_text) return error.InvalidArgs;

    return .{
        .path = path orelse return error.InvalidArgs,
        .fix = fix,
        .extract_text = extract_text,
        .rules_path = rules_path,
    };
}

fn printUsage(writer: *std.Io.Writer) !void {
    try writer.writeAll("usage: zig-comment-typos path/to/project [--fix | --extract-text] [--rules path/to/rules.txt]\n");
}

fn printRunError(writer: *std.Io.Writer, path: []const u8, err: anyerror) !void {
    switch (err) {
        error.FileNotFound => {
            try writer.print("error: path not found: {s}\n", .{path});
            if (looksLikeDriveRelativeWindowsPath(path)) {
                try writer.writeAll("hint: if this was an absolute Windows path in a POSIX-style shell, quote it or use forward slashes, e.g. C:/Projects/Ziglang/zig\n");
            }
        },
        error.NotDir => try writer.print("error: path is not a directory: {s}\n", .{path}),
        error.AccessDenied => try writer.print("error: access denied while scanning: {s}\n", .{path}),
        error.StreamTooLong => try writer.print("error: a Zig file under {s} is larger than the configured read limit\n", .{path}),
        else => try writer.print("error: failed to scan {s}: {s}\n", .{ path, @errorName(err) }),
    }
}

fn looksLikeDriveRelativeWindowsPath(path: []const u8) bool {
    return path.len >= 3 and
        std.ascii.isAlphabetic(path[0]) and
        path[1] == ':' and
        path[2] != '/' and
        path[2] != '\\';
}

fn runProjectForOptions(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: Options,
) !RunResult {
    if (options.extract_text) {
        return extractProjectText(allocator, io, options.path);
    }

    return runProjectWithRulesFile(allocator, io, options.path, options.fix, options.rules_path);
}

pub fn runProject(
    allocator: std.mem.Allocator,
    io: std.Io,
    root_path: []const u8,
    fix: bool,
) !RunResult {
    return runProjectWithRulesFile(allocator, io, root_path, fix, null);
}

pub fn runProjectWithRulesFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    root_path: []const u8,
    fix: bool,
    rules_path: ?[]const u8,
) !RunResult {
    var rule_set = try loadRules(allocator, io, rules_path);
    defer rule_set.deinit();

    const stat = try std.Io.Dir.cwd().statFile(io, root_path, .{});
    if (stat.kind == .file) {
        return runFileWithRuleSet(allocator, io, std.Io.Dir.cwd(), root_path, root_path, fix, &rule_set);
    }

    var root = try std.Io.Dir.cwd().openDir(io, root_path, .{ .iterate = true });
    defer root.close(io);

    return runDirectoryWithRuleSet(allocator, io, root, fix, &rule_set);
}

pub fn extractProjectText(
    allocator: std.mem.Allocator,
    io: std.Io,
    root_path: []const u8,
) !RunResult {
    const stat = try std.Io.Dir.cwd().statFile(io, root_path, .{});
    if (stat.kind == .file) {
        return extractFileText(allocator, io, std.Io.Dir.cwd(), root_path, root_path);
    }

    var root = try std.Io.Dir.cwd().openDir(io, root_path, .{ .iterate = true });
    defer root.close(io);

    return extractDirectoryText(allocator, io, root);
}

fn loadRules(allocator: std.mem.Allocator, io: std.Io, rules_path: ?[]const u8) !rules.RuleSet {
    const path = rules_path orelse return rules.defaultRules(allocator);

    const source = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_rules_file_bytes));
    defer allocator.free(source);

    return rules.parse(allocator, source);
}

fn runFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: std.Io.Dir,
    file_path: []const u8,
    display_file_path: []const u8,
    fix: bool,
) !RunResult {
    var rule_set = try rules.defaultRules(allocator);
    defer rule_set.deinit();

    return runFileWithRuleSet(allocator, io, root, file_path, display_file_path, fix, &rule_set);
}

fn extractFileText(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: std.Io.Dir,
    file_path: []const u8,
    display_file_path: []const u8,
) !RunResult {
    var output = std.Io.Writer.Allocating.init(allocator);
    errdefer output.deinit();

    var result: RunResult = .{
        .output = &.{},
        .findings = 0,
        .fixed = 0,
        .unfixed = 0,
    };

    try extractFileTextInto(allocator, io, root, file_path, display_file_path, &output.writer);

    result.output = try output.toOwnedSlice();
    return result;
}

fn runFileWithRuleSet(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: std.Io.Dir,
    file_path: []const u8,
    display_file_path: []const u8,
    fix: bool,
    rule_set: *const rules.RuleSet,
) !RunResult {
    var output = std.Io.Writer.Allocating.init(allocator);
    errdefer output.deinit();

    var result: RunResult = .{
        .output = &.{},
        .findings = 0,
        .fixed = 0,
        .unfixed = 0,
    };

    if (!std.mem.endsWith(u8, file_path, ".zig")) {
        result.output = try output.toOwnedSlice();
        return result;
    }

    const display_path = try normalizePath(allocator, display_file_path);
    defer allocator.free(display_path);

    const source = try root.readFileAlloc(io, file_path, allocator, .limited(max_file_bytes));
    defer allocator.free(source);

    const diagnostics = try checker.checkSource(allocator, display_path, source, rule_set);
    defer if (diagnostics.len != 0) allocator.free(diagnostics);

    if (fix) {
        try handleFixes(allocator, io, root, file_path, source, diagnostics, &output.writer, &result);
    } else {
        for (diagnostics) |diagnostic| {
            try checker.formatDiagnostic(&output.writer, diagnostic);
        }
        result.findings += diagnostics.len;
        result.unfixed += diagnostics.len;
    }

    result.output = try output.toOwnedSlice();
    return result;
}

pub fn runDirectory(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: std.Io.Dir,
    fix: bool,
) !RunResult {
    var rule_set = try rules.defaultRules(allocator);
    defer rule_set.deinit();

    return runDirectoryWithRuleSet(allocator, io, root, fix, &rule_set);
}

pub fn extractDirectoryText(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: std.Io.Dir,
) !RunResult {
    const files = try collectZigFiles(allocator, io, root);
    defer freeFileList(allocator, files);

    var output = std.Io.Writer.Allocating.init(allocator);
    errdefer output.deinit();

    var result: RunResult = .{
        .output = &.{},
        .findings = 0,
        .fixed = 0,
        .unfixed = 0,
    };

    for (files) |file_path| {
        try extractFileTextInto(allocator, io, root, file_path, file_path, &output.writer);
    }

    result.output = try output.toOwnedSlice();
    return result;
}

fn runDirectoryWithRuleSet(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: std.Io.Dir,
    fix: bool,
    rule_set: *const rules.RuleSet,
) !RunResult {
    const files = try collectZigFiles(allocator, io, root);
    defer freeFileList(allocator, files);

    var output = std.Io.Writer.Allocating.init(allocator);
    errdefer output.deinit();

    var result: RunResult = .{
        .output = &.{},
        .findings = 0,
        .fixed = 0,
        .unfixed = 0,
    };

    for (files) |file_path| {
        const display_path = try normalizePath(allocator, file_path);
        defer allocator.free(display_path);

        const source = try root.readFileAlloc(io, file_path, allocator, .limited(max_file_bytes));
        defer allocator.free(source);

        const diagnostics = try checker.checkSource(allocator, display_path, source, rule_set);
        defer if (diagnostics.len != 0) allocator.free(diagnostics);

        if (fix) {
            try handleFixes(allocator, io, root, file_path, source, diagnostics, &output.writer, &result);
        } else {
            for (diagnostics) |diagnostic| {
                try checker.formatDiagnostic(&output.writer, diagnostic);
            }
            result.findings += diagnostics.len;
            result.unfixed += diagnostics.len;
        }
    }

    result.output = try output.toOwnedSlice();
    return result;
}

fn extractFileTextInto(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: std.Io.Dir,
    file_path: []const u8,
    display_file_path: []const u8,
    writer: *std.Io.Writer,
) !void {
    if (!std.mem.endsWith(u8, file_path, ".zig")) return;

    const display_path = try normalizePath(allocator, display_file_path);
    defer allocator.free(display_path);

    const source = try root.readFileAlloc(io, file_path, allocator, .limited(max_file_bytes));
    defer allocator.free(source);

    const spans = try scanner.scan(allocator, display_path, source);
    defer if (spans.len != 0) allocator.free(spans);

    for (spans) |span| {
        try formatExtractedText(writer, span);
    }
}

fn formatExtractedText(writer: *std.Io.Writer, span: scanner.CommentSpan) !void {
    try writer.print("{s}:{d}:{d}:{s}\n", .{
        span.path,
        span.line,
        span.column,
        span.text,
    });
}

fn handleFixes(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: std.Io.Dir,
    file_path: []const u8,
    source: []const u8,
    diagnostics: []const checker.Diagnostic,
    writer: *std.Io.Writer,
    result: *RunResult,
) !void {
    var replacements: std.ArrayList(fixer.Replacement) = .empty;
    defer {
        for (replacements.items) |replacement| allocator.free(replacement.correction);
        replacements.deinit(allocator);
    }

    for (diagnostics) |diagnostic| {
        result.findings += 1;
        if (diagnostic.correction) |correction| {
            if (try fixer.correctionFor(allocator, diagnostic.typo, correction)) |replacement_text| {
                replacements.append(allocator, .{
                    .start = diagnostic.start,
                    .end = diagnostic.end,
                    .correction = replacement_text,
                }) catch |err| {
                    allocator.free(replacement_text);
                    return err;
                };
                result.fixed += 1;
                try writer.print("{s}:{d}:{d} fixed \"{s}\" -> \"{s}\"\n", .{
                    diagnostic.path,
                    diagnostic.line,
                    diagnostic.column,
                    diagnostic.typo,
                    replacement_text,
                });
                continue;
            }
        }

        result.unfixed += 1;
        try checker.formatDiagnostic(writer, diagnostic);
    }

    if (replacements.items.len == 0) return;

    const fixed_source = try fixer.applyReplacements(allocator, source, replacements.items);
    defer if (fixed_source.len != 0) allocator.free(fixed_source);
    try root.writeFile(io, .{ .sub_path = file_path, .data = fixed_source });
}

fn collectZigFiles(allocator: std.mem.Allocator, io: std.Io, root: std.Io.Dir) ![][]u8 {
    var walker = try root.walkSelectively(allocator);
    defer walker.deinit();

    var files: std.ArrayList([]u8) = .empty;
    errdefer {
        for (files.items) |file| allocator.free(file);
        files.deinit(allocator);
    }

    while (try walker.next(io)) |entry| {
        if (entry.kind == .directory) {
            if (!isGeneratedDirectory(entry.basename)) {
                try walker.enter(io, entry);
            }
            continue;
        }

        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;
        const owned = try allocator.dupe(u8, entry.path);
        errdefer allocator.free(owned);
        try files.append(allocator, owned);
    }

    std.mem.sort([]u8, files.items, {}, lessPath);
    return files.toOwnedSlice(allocator);
}

fn isGeneratedDirectory(name: []const u8) bool {
    return std.mem.eql(u8, name, ".zig-cache") or
        std.mem.eql(u8, name, "zig-cache") or
        std.mem.eql(u8, name, "zig-out");
}

fn freeFileList(allocator: std.mem.Allocator, files: [][]u8) void {
    for (files) |file| allocator.free(file);
    if (files.len != 0) allocator.free(files);
}

fn lessPath(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.lessThan(u8, left, right);
}

fn normalizePath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const out = try allocator.dupe(u8, path);
    std.mem.replaceScalar(u8, out, '\\', '/');
    return out;
}

test "CLI runner scans only sorted Zig files recursively" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "nested");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "z.zig", .data = "// speling here\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "nested/a.zig", .data = "// teh here\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "ignore.txt", .data = "// teh here\n" });

    var result = try runDirectory(allocator, std.testing.io, tmp.dir, false);
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), result.unfixed);
    try std.testing.expectEqualStrings(
        "nested/a.zig:1:4 typo \"teh\", expected \"the\"\n" ++
            "z.zig:1:4 typo \"speling\"\n",
        result.output,
    );
}

test "CLI runner skips generated Zig directories" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "src");
    try tmp.dir.createDirPath(std.testing.io, ".zig-cache/o");
    try tmp.dir.createDirPath(std.testing.io, "zig-out/bin");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/main.zig", .data = "// teh source\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".zig-cache/o/generated.zig", .data = "// speling generated\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "zig-out/bin/generated.zig", .data = "// recieve generated\n" });

    var result = try runDirectory(allocator, std.testing.io, tmp.dir, false);
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), result.unfixed);
    try std.testing.expectEqualStrings(
        "src/main.zig:1:4 typo \"teh\", expected \"the\"\n",
        result.output,
    );
}

test "CLI runner scans a single Zig file input" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "sample.zig", .data = "// teh here\n" });

    const file_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/sample.zig", .{&tmp.sub_path});
    defer allocator.free(file_path);

    var result = try runProject(allocator, std.testing.io, file_path, false);
    defer result.deinit(allocator);

    const expected = try std.fmt.allocPrint(allocator, "{s}:1:4 typo \"teh\", expected \"the\"\n", .{file_path});
    defer allocator.free(expected);

    try std.testing.expectEqual(@as(usize, 1), result.unfixed);
    try std.testing.expectEqualStrings(expected, result.output);
}

test "detects Windows absolute paths mangled by POSIX-style shells" {
    try std.testing.expect(looksLikeDriveRelativeWindowsPath("C:ProjectsZiglangzig"));
    try std.testing.expect(!looksLikeDriveRelativeWindowsPath("C:/Projects/Ziglang/zig"));
    try std.testing.expect(!looksLikeDriveRelativeWindowsPath("C:\\Projects\\Ziglang\\zig"));
    try std.testing.expect(!looksLikeDriveRelativeWindowsPath("relative/path"));
}

test "CLI parser accepts an external rules file" {
    const args = [_][:0]const u8{ "zig-comment-typos", "--rules", "rules.txt", "src", "--fix" };

    const options = try parseArgs(&args);

    try std.testing.expectEqualStrings("src", options.path);
    try std.testing.expect(options.fix);
    try std.testing.expectEqualStrings("rules.txt", options.rules_path.?);
}

test "CLI parser accepts extract-text mode" {
    const args = [_][:0]const u8{ "zig-comment-typos", "--extract-text", "--rules", "rules.txt", "src" };

    const options = try parseArgs(&args);

    try std.testing.expectEqualStrings("src", options.path);
    try std.testing.expect(!options.fix);
    try std.testing.expect(options.extract_text);
    try std.testing.expectEqualStrings("rules.txt", options.rules_path.?);
}

test "CLI parser rejects fix with extract-text mode" {
    const args = [_][:0]const u8{ "zig-comment-typos", "src", "--fix", "--extract-text" };

    try std.testing.expectError(error.InvalidArgs, parseArgs(&args));
}

test "extract-text mode emits sorted scanner text without diagnostics" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "nested");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "z.zig", .data = "const text = \"teh\";\n// teh source\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "nested/a.zig", .data = "//!container docs\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "ignore.txt", .data = "// speling ignored\n" });

    var result = try extractDirectoryText(allocator, std.testing.io, tmp.dir);
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), result.findings);
    try std.testing.expectEqual(@as(usize, 0), result.fixed);
    try std.testing.expectEqual(@as(usize, 0), result.unfixed);
    try std.testing.expectEqualStrings(
        "nested/a.zig:1:4:container docs\n" ++
            "z.zig:2:3: teh source\n",
        result.output,
    );
}

test "extract-text mode does not load rules files" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "main.zig", .data = "// teh source\n" });

    const root_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer allocator.free(root_path);
    const missing_rules_path = try std.fmt.allocPrint(allocator, "{s}/missing.rules", .{root_path});
    defer allocator.free(missing_rules_path);

    var result = try runProjectForOptions(allocator, std.testing.io, .{
        .path = root_path,
        .fix = false,
        .extract_text = true,
        .rules_path = missing_rules_path,
    });
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings("main.zig:1:3: teh source\n", result.output);
}

test "CLI runner loads typo rules from a file" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "main.zig", .data = "// wierd typo\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "rules.txt", .data = "wierd=weird\n" });

    const root_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer allocator.free(root_path);
    const rules_path = try std.fmt.allocPrint(allocator, "{s}/rules.txt", .{root_path});
    defer allocator.free(rules_path);

    var result = try runProjectWithRulesFile(allocator, std.testing.io, root_path, false, rules_path);
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), result.unfixed);
    try std.testing.expectEqualStrings("main.zig:1:4 typo \"wierd\", expected \"weird\"\n", result.output);
}

test "CLI runner applies external rules to a single Zig file input" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "sample.zig", .data = "// wierd typo\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "rules.txt", .data = "wierd=weird\n" });

    const root_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer allocator.free(root_path);
    const file_path = try std.fmt.allocPrint(allocator, "{s}/sample.zig", .{root_path});
    defer allocator.free(file_path);
    const rules_path = try std.fmt.allocPrint(allocator, "{s}/rules.txt", .{root_path});
    defer allocator.free(rules_path);

    var result = try runProjectWithRulesFile(allocator, std.testing.io, file_path, false, rules_path);
    defer result.deinit(allocator);

    const expected = try std.fmt.allocPrint(allocator, "{s}:1:4 typo \"wierd\", expected \"weird\"\n", .{file_path});
    defer allocator.free(expected);

    try std.testing.expectEqual(@as(usize, 1), result.unfixed);
    try std.testing.expectEqualStrings(expected, result.output);
}

test "CLI runner returns clean output when no typos are found" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "main.zig", .data = "// clean comment\n" });

    var result = try runDirectory(allocator, std.testing.io, tmp.dir, false);
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), result.unfixed);
    try std.testing.expectEqualStrings("", result.output);
}

test "fix mode rewrites fixable typos while preserving capitalization" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.zig",
        .data = "// teh speling\nconst text = \"teh\";\n// Teh again\n",
    });

    var result = try runDirectory(allocator, std.testing.io, tmp.dir, true);
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), result.fixed);
    try std.testing.expectEqual(@as(usize, 1), result.unfixed);
    try std.testing.expectEqualStrings(
        "main.zig:1:4 fixed \"teh\" -> \"the\"\n" ++
            "main.zig:1:8 typo \"speling\"\n" ++
            "main.zig:3:4 fixed \"Teh\" -> \"The\"\n",
        result.output,
    );

    const fixed = try tmp.dir.readFileAlloc(std.testing.io, "main.zig", allocator, .limited(max_file_bytes));
    defer if (fixed.len != 0) allocator.free(fixed);
    try std.testing.expectEqualStrings("// the speling\nconst text = \"teh\";\n// The again\n", fixed);
}
