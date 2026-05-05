# HashAnchoredPatch

Hash-anchored surgical file patching for Elixir, with an optional
LLM-driven editor on top.

Edit specific regions of a file by **content hash**, not by line number.
Each edit target is identified by a SHA-256 over a small window of
surrounding lines, so the patch survives unrelated insertions or
deletions earlier in the file. If the file has drifted since the anchor
was computed, the patch aborts cleanly instead of corrupting the file.

This repo ships two layers:

1. **`HashAnchoredPatch`** — the deterministic patching engine. Pure
   Elixir, no network. Works for any agent that can produce
   `{anchor_hash, search, replace}` tuples.
2. **`HashAnchoredPatch.EditTool`** — a thin wrapper that asks an OpenAI
   model (via [`baml_elixir`](https://github.com/emilsoman/baml_elixir))
   to produce those tuples for you, given a natural-language instruction
   and a target file. Built around the *hashline* trick from
   <https://blog.can.ac/2026/02/12/the-harness-problem/>: anchor hashes
   are truncated to the smallest unique prefix per file before the
   prompt goes out, then expanded back before patches are applied.

## Why

Conventional "rewrite this file" tools have two costs:

1. **Tokens** — the whole file goes into context every time.
2. **Drift** — with a large window the model can change code far from
   the intended target.

Identifying edits by line number is also brittle: any earlier insertion
or deletion shifts every later target.

Anchoring by a content hash of a few surrounding lines fixes both. The
agent sees only the anchors (short hash + line preview) and edits with a
`search` / `replace` pair scoped to one anchor's window. The engine
re-derives anchors from the on-disk file at apply-time, so a stale view
fails loudly instead of corrupting the file.

## Installation

### Use it from another project (recommended)

Add it as a git dependency in your `mix.exs`:

```elixir
def deps do
  [
    {:hash_anchored_patch, github: "emilsoman/hash_anchored_patch"}
  ]
end
```

Then `mix deps.get` and `mix compile`. That's it — both the engine
(`HashAnchoredPatch`) and the LLM editor (`HashAnchoredPatch.EditTool`)
are immediately available. The BAML prompt files in `priv/baml_src/`
ship with the dep and are resolved at runtime via
`:code.priv_dir(:hash_anchored_patch)`.

You can also pin a tag, branch, or commit:

```elixir
{:hash_anchored_patch, github: "emilsoman/hash_anchored_patch", tag: "v0.1.0"}
{:hash_anchored_patch, github: "emilsoman/hash_anchored_patch", branch: "main"}
```

Or use a local path while developing:

```elixir
{:hash_anchored_patch, path: "../hash_anchored_patch"}
```

### Environment

The deterministic engine has zero runtime requirements.

The LLM editor (`HashAnchoredPatch.EditTool`) needs `OPENAI_API_KEY`
exported in the environment of whatever process calls it — that's all.

### Hacking on this repo directly

```bash
git clone https://github.com/emilsoman/hash_anchored_patch.git
cd hash_anchored_patch
mix deps.get
mix test
mix run examples/demo.exs   # needs OPENAI_API_KEY
```

---

## Part 1 — The patching engine

The deterministic flow has two phases.

### 1. Compute anchors

```elixir
{:ok, anchors} = HashAnchoredPatch.compute_anchors("lib/foo.ex")
# => [
#   %{line: 0, anchor_hash: "abc...", context_lines: 5, preview: "defmodule Foo do"},
#   %{line: 1, anchor_hash: "def...", context_lines: 5, preview: "  def hello do"},
#   ...
# ]
```

Each entry hashes a window of `±context_lines` lines centered on that
line (default radius `5`). Hand the list to whoever decides on edits,
along with the `preview` field for orientation.

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

`patch_file/3` reads the file, re-derives every anchor, finds the
matching window, verifies `search` is present, checks no two patches
overlap, applies them in reverse line order, and writes the file. If
anything fails, **nothing is written**.

### Multiple patches in one call

```elixir
patches = [
  %{anchor_hash: hash_a, search: "old_a", replace: "new_a"},
  %{anchor_hash: hash_b, search: "old_b", replace: "new_b"},
  %{anchor_hash: hash_c, search: "old_c", replace: "new_c"}
]

HashAnchoredPatch.patch_file(path, patches)
```

All-or-nothing. Patches must target non-overlapping line ranges
(remember: with the default radius of 5, two anchors within ~10 lines
of each other share a window). If two edits are close, collapse them
into a single patch with a multi-line `search` / `replace`.

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

Recovery for drift errors: re-run `compute_anchors/2` and rebuild the
patch.

### Public functions

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

---

## Part 2 — The LLM editor (`HashAnchoredPatch.EditTool`)

`HashAnchoredPatch.EditTool.edit/3` ties the engine above to a BAML
function (`priv/baml_src/edit_tool.baml`) that calls an OpenAI model.
The model never sees the full file; it sees one short hash + an 80-char
preview per line, plus your instruction.

### Prerequisites

* `OPENAI_API_KEY` exported in the environment.
* `mix deps.get` run at least once (pulls `baml_elixir` and the
  precompiled BAML NIF).

### One-call usage

```elixir
{:ok, %{
  patches_applied: n,
  content: new_content,
  reasoning: model_reasoning,
  patches: applied_patches
}} = HashAnchoredPatch.EditTool.edit(
  "lib/greeter.ex",
  "Rename the function `hello/1` to `greet/1` and change its message."
)
```

What happens under the hood:

1. `compute_anchors/2` reads the file and builds the per-line anchor list.
2. Each anchor's hash is truncated to the smallest prefix length (≥ 3
   chars) that is still unique within this file.
3. Those short anchors + your instruction go to the BAML function
   `EditTool`, which uses `gpt-4o-mini` by default and returns an
   `EditPlan { reasoning, patches[] }`.
4. The short hashes in returned patches are expanded back to full
   SHA-256 via a prefix→full lookup.
5. `patch_file/3` re-derives anchors from disk, validates, applies, and
   writes — atomically.

### Options

```elixir
HashAnchoredPatch.EditTool.edit(path, instruction,
  context_lines: 5,   # anchor window radius (default 5)
  dry_run: true       # don't write; return new content in :content
)
```

### Demo

```bash
mix run examples/demo.exs
```

The demo creates a small `Greeter` module in `$TMPDIR`, asks the model
to rename `hello/1` → `greet/1` and change the printed message, then
prints the model's reasoning, the patches it produced (note the short
anchor prefixes), and the resulting file.

### Tweaking the prompt or model

Everything the model sees lives in `priv/baml_src/edit_tool.baml`. To
swap models, change the `client<llm> OpenAIGPT4o` block (BAML supports
OpenAI, Anthropic, and others — see the [baml_elixir
README](https://github.com/emilsoman/baml_elixir) and upstream BAML
docs). After editing the `.baml` file, run `mix compile` to regenerate
the Elixir client.

---

## Running the tests

```bash
mix test
```

The suite covers the engine; it doesn't hit the network. For a
live end-to-end check of the LLM path, run `examples/demo.exs`.

## Layout

```
hash_anchored_patch/
├── lib/
│   ├── hash_anchored_patch.ex            # the engine
│   └── hash_anchored_patch/
│       ├── baml_client.ex                # use BamlElixir.Client, path: …
│       └── edit_tool.ex                  # high-level edit/3 wrapper
├── priv/baml_src/
│   └── edit_tool.baml                    # prompt + IO schema for the LLM
├── examples/
│   └── demo.exs
└── test/
    └── hash_anchored_patch_test.exs
```

## Credits

* The hash-anchored patch idea: <https://github.com/anomalyco/opencode/issues/24511>.
* The short-hash ("hashline") format: <https://blog.can.ac/2026/02/12/the-harness-problem/>.
* `baml_elixir`: <https://github.com/emilsoman/baml_elixir>.
