# Demo: hash-anchored patching driven by an LLM via BAML.
#
# Run with:
#   mix run examples/demo.exs
#
# Requires OPENAI_API_KEY in the env (the .envrc in this repo sets one).

alias HashAnchoredPatch.EditTool

# 1. Materialise a small file we'll let the model edit.
sample_path =
  Path.join(System.tmp_dir!(), "hash_anchored_demo_#{System.unique_integer([:positive])}.ex")

File.write!(sample_path, """
defmodule Greeter do
  @moduledoc "Tiny module used as a demo target for hash-anchored edits."

  def hello(name) do
    IO.puts("hi " <> name)
  end

  def add(a, b) do
    a + b
  end

  def goodbye(name) do
    IO.puts("bye " <> name)
  end
end
""")

IO.puts("== before ==")
IO.puts(File.read!(sample_path))

instruction = """
Rename the function `hello/1` to `greet/1`, and change the message it prints
from "hi <name>" to "hello, <name>!". Leave the rest of the module alone.
"""

IO.puts("== instruction ==")
IO.puts(instruction)

case EditTool.edit(sample_path, instruction) do
  {:ok, %{patches_applied: n, reasoning: why, patches: patches, content: new}} ->
    IO.puts("== model reasoning ==")
    IO.puts(why)

    IO.puts("== patches (#{n}) ==")

    Enum.each(patches, fn p ->
      IO.puts("  anchor: #{String.slice(p.anchor_hash, 0, 12)}…")
      IO.puts("  - " <> inspect(p.search))
      IO.puts("  + " <> inspect(p.replace))
    end)

    IO.puts("== after ==")
    IO.puts(new)

  {:error, reason} ->
    IO.puts("== error ==")
    IO.inspect(reason)
end

File.rm(sample_path)
