pub const checker = @import("checker.zig");
pub const fixer = @import("fixer.zig");
pub const rules = @import("rules.zig");
pub const scanner = @import("scanner.zig");
pub const words = @import("words.zig");

pub const Candidate = words.Candidate;
pub const CommentSpan = scanner.CommentSpan;
pub const Diagnostic = checker.Diagnostic;
pub const Replacement = fixer.Replacement;
pub const Rule = rules.Rule;
pub const RuleSet = rules.RuleSet;

test {
    _ = checker;
    _ = fixer;
    _ = rules;
    _ = scanner;
    _ = words;
}
