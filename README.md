# zig-comment-typos

`zig-comment-typos` is a small Zig-aware typo checker for Zig source comments.

It is not a full dictionary spellchecker. Instead, it scans `.zig` files, extracts Zig line comments, and reports known bad typo patterns such as `teh`, `recieve`, and `speling`.

## Features

- Scans a single `.zig` file or recursively scans `.zig` files under a directory.
- Checks `//`, `///`, and `//!` comments.
- Ignores comment-like text inside strings, character literals, and Zig multiline string lines.
- Skips noisy code-like tokens such as URLs, email addresses, paths, identifiers, digits, underscores, and mixed-case words.
- Emits deterministic `path:line:column` diagnostics.
- Supports `--fix` for typo rules with explicit lowercase corrections, preserving capitalization for title-case matches.

## Requirements

- Zig `0.16.0`

The expected Zig version is pinned in `.zigversion`.

## Build

```sh
zig build
```

The executable is written to `zig-out/bin/zig-comment-typos`.

## Test

```sh
zig build test
```

To check formatting:

```sh
zig fmt --check build.zig build.zig.zon src
```

## Usage

Scan a Zig project:

```sh
zig-out/bin/zig-comment-typos path/to/project
```

Scan one Zig file:

```sh
zig-out/bin/zig-comment-typos path/to/file.zig
```

Example output:

```text
src/main.zig:42:9 typo "teh", expected "the"
src/main.zig:43:12 typo "speling"
```

Use `--fix` to rewrite fixable typos in comments:

```sh
zig-out/bin/zig-comment-typos path/to/project --fix
```

Example fix output:

```text
src/main.zig:42:9 fixed "teh" -> "the"
src/main.zig:43:9 fixed "Teh" -> "The"
src/main.zig:44:12 typo "speling"
```

## Package Usage

This repository also exposes a Zig module named `comment_typos`.

After adding the package as a dependency, import it from your own Zig code:

```zig
const comment_typos = @import("comment_typos");

const checker = comment_typos.checker;
const rules = comment_typos.rules;
```

The module root re-exports the checker, fixer, rules, scanner, and word-tokenization modules.

## Exit Codes

- `0`: no unfixed typos were found
- `1`: one or more typos remain
- `2`: invalid arguments or a scan error

## Current Limitations

- Typo rules are currently built into the executable.
- Generated directories such as `.zig-cache` are not treated specially by the scanner yet; pass the source directory you want to check.

## License

MIT. See `LICENSE`.
