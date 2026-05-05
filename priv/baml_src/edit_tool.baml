// BAML function that drives the hash-anchored patch tool.
//
// The Elixir caller pre-computes anchors for the target file (one anchor
// per line: a SHA-256 over a small window of surrounding lines, plus an
// 80-char preview of the line). The model receives those anchors plus an
// edit instruction and must emit one or more `Patch` records. Each patch
// references an existing `anchor_hash` and a `search`/`replace` pair that
// applies inside that anchor's window.
//
// The model never computes hashes; it just picks anchors from the list.

client<llm> OpenAIGPT4o {
    provider openai
    options {
        model "gpt-4o-mini"
        api_key env.OPENAI_API_KEY
    }
}

class Anchor {
    line int           @description("0-based line number in the file")
    anchor_hash string @description("SHA-256 of the window centered on this line")
    preview string     @description("First 80 chars of the line — your view of the file")
}

class Patch {
    anchor_hash string @description("Short hash prefix copied verbatim from one of the input anchors (typically 3-6 hex chars). Do not pad, lengthen, or modify it.")
    search string      @description("Exact text to find within ±5 lines of the anchor. Multi-line allowed; must match the file byte-for-byte.")
    replace string     @description("Replacement text. Use the same indentation style as the surrounding code.")
}

class EditPlan {
    reasoning string @description("One short paragraph explaining what you changed and why.")
    patches Patch[]  @description("Non-overlapping patches that, applied together, fulfill the instruction.")
}

function EditTool(instruction: string, anchors: Anchor[]) -> EditPlan {
    client OpenAIGPT4o
    prompt #"
        You are a surgical code editor. You edit files using *hash-anchored
        patches*: instead of rewriting the whole file, you produce small
        search/replace pairs scoped to a specific anchor in the file.

        You will receive:
          - An edit `instruction` describing what to change.
          - A list of `anchors`, one per line of the target file. Each anchor
            has a `line` number, an `anchor_hash`, and a `preview` (the first
            80 chars of that line). The anchors collectively describe the
            file — treat the previews as your view of the source.

        Rules — read carefully:
          1. For every patch, `anchor_hash` MUST be one of the hashes in the
             input. Never invent or modify a hash. Pick the anchor whose line
             sits inside the region you want to change.
          2. `search` must appear VERBATIM within ±5 lines of that anchor's
             line. Copy whitespace, punctuation, and casing exactly.
          3. `replace` is what `search` becomes. Preserve indentation.
          4. Patches must NOT overlap. With a default radius of 5, two
             anchors whose lines are within ~10 of each other share a
             window — even if you anchor on different lines. When in doubt,
             collapse nearby edits into ONE patch with a multi-line
             `search`/`replace`. Example:

               INSTRUCTION: rename `hello` to `greet` and change the
               message it prints.

               BAD (two patches, overlapping windows):
                 patch A: search "  def hello(name) do"
                          replace "  def greet(name) do"
                 patch B: search "    IO.puts(\"hi \" <> name)"
                          replace "    IO.puts(\"hello, \" <> name)"

               GOOD (one merged patch):
                 search:  "  def hello(name) do\n    IO.puts(\"hi \" <> name)"
                 replace: "  def greet(name) do\n    IO.puts(\"hello, \" <> name)"

             Use `\n` between lines in the JSON string. Keep one patch per
             contiguous edit region.
          5. Prefer the smallest `search` that uniquely identifies the spot
             inside the anchor window. Don't include unrelated lines.
          6. If the instruction can't be satisfied from the anchors given,
             return an empty `patches` array and explain in `reasoning`.

        {{ ctx.output_format }}

        Instruction:
        {{ instruction }}

        Anchors. Each line below has the format:

            <line>\t<hash>\t«<preview>»

        The preview is wrapped in « » so leading/trailing whitespace is
        unambiguous. When you write `search`, copy bytes from BETWEEN the
        guillemets — do not add or drop spaces, do not change indentation.

        {% for a in anchors %}
        {{ a.line }}	{{ a.anchor_hash }}	«{{ a.preview }}»
        {% endfor %}
    "#
}

test SimpleRename {
    functions [EditTool]
    args {
        instruction "Rename the function `hello` to `greet`."
        anchors [
            {
                line 0
                anchor_hash "deadbeef"
                preview "defmodule Foo do"
            }
            {
                line 1
                anchor_hash "cafebabe"
                preview "  def hello do"
            }
            {
                line 2
                anchor_hash "f00dface"
                preview "    IO.puts(\"hi\")"
            }
            {
                line 3
                anchor_hash "abad1dea"
                preview "  end"
            }
            {
                line 4
                anchor_hash "1badb002"
                preview "end"
            }
        ]
    }
}
