# HashAnchoredPatch

Hash-anchored surgical file patching for Elixir.

Edit specific regions of a file by **content hash**, not by line number. Each
edit target is identified by a SHA-256 over a small window of surrounding
lines, so the patch survives unrelated insertions or deletions earlier in the
file. If the file has drifted since the anchor was computed, the patch aborts
cleanly instead of corrupting the file.

This is useful when an LLM (or any other agent) wants to edit a region of a
large file without seeing or rewriting the full contents.

## Why

Conventional "rewrite this file" tools have two costs:

1. **Tokens** — the whole file goes into context every time.
2. **Drift** — with a large window the model can change code far from the
   intended target.

Identifying edits by line number is also brittle: any earlier insertion or
deletion shifts every later target.

Anchoring by a content hash of a few surrounding lines fixes both. The agent
sees only the anchors (hash + line preview) and edits with a `search` /
`replace` pair scoped to one anchor's window.

## Installation

This is currently a standalone Mix project. Clone it and use it directly:

```bash
git clone <this repo> hash_anchored_patch
cd hash_anchored_patch
mix test
```

To use it from another project as a path dependency, in your `mix.exs`:

```elixir
def deps do
  [
    {:hash_anchored_patch, path: "../hash_anchored_patch"}
  ]
end
```

## Usage

The flow has two phases.

### 1. Compute anchors

```elixir
{:ok, anchors} = HashAnchoredPatch.compute_anchors("lib/foo.ex")
# => [
#   %{line: 0, anchor_hash: "abc...", context_lines: 5, preview: "defmodule Foo do"},
#   %{line: 1, anchor_hash: "def...", context_lines: 5, preview: "  def hello do"},
#   ...
# ]
```

Each entry hashes a window of `±context_lines` lines centered on that line
(default radius `5`). Hand the list to whoever decides on edits, along with
the `preview` field for orientation.

### 2. Apply patches

```elixir
patches = [
  %{
    anchor_hash: "def...",                # one of the hashes from step 1
    search:  ~s|IO.puts("hi")|,           # exact text inside that window
    replace: ~s|IO.puts("hello")|         # what to swap it for
  }
]

{:ok, %{file: path, patches_applied: 1, content: new_content}} =
  HashAnchoredPatch.patch_file("lib/foo.ex", patches)
```

`patch_file/3` reads the file, re-derives every anchor, finds the matching
window, verifies `search` is present, checks no two patches overlap, applies
them in reverse line order, and writes the file. If anything fails, **nothing
is written**.

### Multiple patches in one call

```elixir
patches = [
  %{anchor_hash: hash_a, search: "old_a", replace: "new_a"},
  %{anchor_hash: hash_b, search: "old_b", replace: "new_b"},
  %{anchor_hash: hash_c, search: "old_c", replace: "new_c"}
]

HashAnchoredPatch.patch_file(path, patches)
```

All-or-nothing. Patches must target non-overlapping line ranges; otherwise
you'll get `{:error, "...patches overlap..."}`.

### Options

```elixir
# Don't write — return the would-be content
HashAnchoredPatch.patch_file(path, patches, dry_run: true)

# Use a different default context radius
# (must match the radius used when anchors were computed,
# unless each patch overrides via :context_lines)
HashAnchoredPatch.patch_file(path, patches, context_lines: 8)

# Per-patch override — wins over the file-level default
%{anchor_hash: "...", context_lines: 10, search: "...", replace: "..."}
```

### Errors

```elixir
{:error, "[patch_file] anchor_hash \"...\" not found. Re-run with compute_anchors=true."}
# Anchor doesn't match — file has drifted since you computed anchors.

{:error, "[patch_file] anchor found but search text not present in window (line N)."}
# Anchor matches but your search string isn't in the surrounding window.

{:error, "[patch_file] patches overlap. Each patch must target a non-overlapping section."}
# Two patches touch the same line range.

{:error, "[patch_file] patches list is required and must be non-empty."}
# Empty list passed.
```

Recovery for drift errors: re-run `compute_anchors/2` and rebuild the patch.

## Public functions

| Function | Purpose |
|---|---|
| `normalize_lines/1`  | Normalize CRLF → LF (used internally for cross-platform stability). |
| `compute_anchor/3`   | Hash a single line's window. |
| `build_anchor_map/2` | Anchor map for an in-memory string. |
| `compute_anchors/2`  | File-level wrapper around `build_anchor_map/2`. |
| `resolve_patch/3`    | Locate a single patch's window in given lines. |
| `check_overlaps/1`   | Reject overlapping resolved patches. |
| `apply_patches/2`    | Apply resolved patches in reverse line order. |
| `patch_file/3`       | Top-level: read, resolve, validate, write. |

The lower-level functions are exposed so callers can drive the pieces
themselves (e.g. to sandbox the write or batch across files).

## Running the tests

```bash
mix test
```
