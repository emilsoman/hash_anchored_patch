defmodule HashAnchoredPatch.EditTool do
  @moduledoc """
  High-level wrapper that ties the BAML `EditTool` function to the
  algorithmic `HashAnchoredPatch.patch_file/3` engine.

  Flow:

    1. Compute anchors for `file_path` (`HashAnchoredPatch.compute_anchors/2`).
    2. Hand the anchors + `instruction` to the LLM via BAML, which returns
       an `EditPlan` with one or more `{anchor_hash, search, replace}`
       patches.
    3. Feed those patches to `HashAnchoredPatch.patch_file/3`, which
       re-derives the anchors from disk, validates each patch against its
       window, and applies them atomically.

  Steps 1 and 3 are deterministic Elixir; the model's only job is choosing
  anchors and writing search/replace pairs.
  """

  alias HashAnchoredPatch
  alias HashAnchoredPatch.BamlClient

  @type opts :: [
          context_lines: non_neg_integer(),
          dry_run: boolean()
        ]

  @spec edit(Path.t(), String.t(), opts()) ::
          {:ok,
           %{
             file: Path.t(),
             patches_applied: non_neg_integer(),
             content: String.t(),
             reasoning: String.t(),
             patches: [map()]
           }}
          | {:error, term()}
  def edit(file_path, instruction, opts \\ []) do
    context_lines = Keyword.get(opts, :context_lines, 5)

    with {:ok, anchors} <- HashAnchoredPatch.compute_anchors(file_path, context_lines),
         short_len = min_unique_prefix_len(anchors, 3),
         lookup = build_prefix_lookup(anchors, short_len),
         short_anchors = shorten(anchors, short_len),
         {:ok, plan} <- run_baml(instruction, short_anchors),
         {:ok, patches} <- expand_patches(plan.patches, lookup),
         {:ok, summary} <-
           HashAnchoredPatch.patch_file(file_path, patches,
             context_lines: context_lines,
             dry_run: Keyword.get(opts, :dry_run, false)
           ) do
      {:ok, Map.merge(summary, %{reasoning: plan.reasoning, patches: patches})}
    end
  end

  # Pick the smallest prefix length (>= floor) at which every anchor's hash
  # is still unique. SHA-256 hex is 64 chars, so we'll always succeed.
  defp min_unique_prefix_len(anchors, floor) do
    hashes = Enum.map(anchors, & &1.anchor_hash)

    Enum.find(floor..64, fn n ->
      hashes |> Enum.map(&String.slice(&1, 0, n)) |> Enum.uniq() |> length() ==
        length(hashes)
    end)
  end

  defp build_prefix_lookup(anchors, n),
    do: Map.new(anchors, &{String.slice(&1.anchor_hash, 0, n), &1.anchor_hash})

  defp shorten(anchors, n),
    do:
      Enum.map(anchors, fn a ->
        %{line: a.line, anchor_hash: String.slice(a.anchor_hash, 0, n), preview: a.preview}
      end)

  defp expand_patches(patches, lookup) do
    Enum.reduce_while(patches, {:ok, []}, fn p, {:ok, acc} ->
      np = normalize_patch(p)

      case Map.fetch(lookup, np.anchor_hash) do
        {:ok, full} ->
          {:cont, {:ok, [%{np | anchor_hash: full} | acc]}}

        :error ->
          {:halt, {:error, "model returned unknown anchor prefix #{inspect(np.anchor_hash)}"}}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      err -> err
    end
  end

  defp run_baml(instruction, anchors) do
    payload = %{instruction: instruction, anchors: anchors}

    case BamlClient.EditTool.call(payload) do
      {:ok, plan} -> {:ok, plan}
      {:error, _} = err -> err
      plan when is_map(plan) -> {:ok, plan}
    end
  end

  defp normalize_patch(%{anchor_hash: h, search: s, replace: r}),
    do: %{anchor_hash: h, search: s, replace: r}

  defp normalize_patch(%{"anchor_hash" => h, "search" => s, "replace" => r}),
    do: %{anchor_hash: h, search: s, replace: r}
end
