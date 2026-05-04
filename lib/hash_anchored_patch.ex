defmodule HashAnchoredPatch do
  @moduledoc """
  Hash-anchored surgical file patching — an Elixir port of the `patch_file`
  tool introduced in anomalyco/opencode#24515 (issue #24511).

  ## The problem it solves

  Conventional `edit_file` tools send the entire file contents to the model
  every time an edit is needed. On large files this wastes tokens and lets
  the model drift, mutating code far from the intended target. Identifying
  edits by raw line number is also brittle: any earlier insertion or
  deletion shifts every subsequent target.

  ## How it solves it

  Each edit target is anchored by a `sha256` over a small window of lines
  around the target (default 5 lines on each side). The flow is:

    1. `compute_anchors/2` — read the file once and emit, per line, the
       hash of its surrounding window. The model receives these hashes
       (along with line previews) instead of the full file.
    2. The model emits `patches`, each pairing an `anchor_hash` with a
       `search`/`replace` string scoped to that anchor's window.
    3. `patch_file/3` re-derives the same hashes from the on-disk file,
       locates each patch's window, verifies the search text is present,
       checks that no two patches overlap, and applies them in reverse
       line order so earlier rewrites don't shift later targets.

  Drift between the model's view and the current file state is caught
  before any write: a missing anchor or absent search text aborts the
  whole batch, so the caller can re-anchor and retry.

  ## Public interface

    * `normalize_lines/1`
    * `compute_anchor/3`
    * `build_anchor_map/2`
    * `compute_anchors/2`        — file-level convenience over `build_anchor_map/2`
    * `resolve_patch/3`
    * `check_overlaps/1`
    * `apply_patches/2`
    * `patch_file/3`             — top-level: read, resolve, validate, write
  """

  @default_context_lines 5

  @typedoc "A patch as supplied by the model."
  @type patch :: %{
          required(:anchor_hash) => String.t(),
          required(:search) => String.t(),
          required(:replace) => String.t(),
          optional(:context_lines) => non_neg_integer()
        }

  @typedoc "A patch resolved against the current file."
  @type resolved_patch :: %{
          start_line: non_neg_integer(),
          end_line: non_neg_integer(),
          search: String.t(),
          replace: String.t()
        }

  @typedoc "An entry in the anchor map returned by `build_anchor_map/2`."
  @type anchor_info :: %{
          anchor_hash: String.t(),
          line: non_neg_integer(),
          context_lines: non_neg_integer(),
          preview: String.t()
        }

  @doc "Normalize CRLF line endings to LF so anchors and search text match across platforms."
  @spec normalize_lines(String.t()) :: String.t()
  def normalize_lines(text) when is_binary(text), do: String.replace(text, "\r\n", "\n")

  @doc """
  Compute the SHA-256 anchor for the window of `2 * context_lines + 1` lines
  centered on `center_line` (clamped to file bounds). Returns a lowercase hex digest.
  """
  @spec compute_anchor([String.t()], non_neg_integer(), non_neg_integer()) :: String.t()
  def compute_anchor(lines, center_line, context_lines) when is_list(lines) do
    last = length(lines) - 1
    from = max(0, center_line - context_lines)
    to = min(last, center_line + context_lines)
    count = to - from + 1

    window =
      lines
      |> Enum.slice(from, count)
      |> Enum.join("\n")
      |> normalize_lines()

    :crypto.hash(:sha256, window) |> Base.encode16(case: :lower)
  end

  @doc """
  Build the per-line anchor map for `content`. Each entry contains the
  anchor hash, the 0-based line number, the context radius used, and the
  first 80 chars of the line as a preview.
  """
  @spec build_anchor_map(String.t(), non_neg_integer()) :: [anchor_info()]
  def build_anchor_map(content, context_lines \\ @default_context_lines) when is_binary(content) do
    lines = String.split(content, "\n")

    lines
    |> Enum.with_index()
    |> Enum.map(fn {line, i} ->
      %{
        anchor_hash: compute_anchor(lines, i, context_lines),
        line: i,
        context_lines: context_lines,
        preview: String.slice(line, 0, 80)
      }
    end)
  end

  @doc """
  File-level wrapper around `build_anchor_map/2`. Reads `file_path` and
  returns `{:ok, anchors}` or `{:error, reason}`.
  """
  @spec compute_anchors(Path.t(), non_neg_integer()) ::
          {:ok, [anchor_info()]} | {:error, term()}
  def compute_anchors(file_path, context_lines \\ @default_context_lines) do
    with {:ok, content} <- File.read(file_path) do
      {:ok, build_anchor_map(content, context_lines)}
    end
  end

  @doc """
  Locate `patch` in `lines`. Returns the resolved window (start/end line),
  or `{:error, reason}` if the anchor isn't found or the search text is
  absent from the anchor window.
  """
  @spec resolve_patch([String.t()], patch(), non_neg_integer()) ::
          {:ok, resolved_patch()} | {:error, String.t()}
  def resolve_patch(lines, patch, default_context_lines \\ @default_context_lines) do
    ctx = Map.get(patch, :context_lines, default_context_lines)
    last = length(lines) - 1

    found =
      Enum.find(0..last//1, fn idx ->
        compute_anchor(lines, idx, ctx) == patch.anchor_hash
      end)

    case found do
      nil ->
        {:error,
         "[patch_file] anchor_hash \"#{patch.anchor_hash}\" not found. " <>
           "Re-run with compute_anchors=true."}

      idx ->
        from = max(0, idx - ctx)
        to = min(last, idx + ctx)
        count = to - from + 1

        window_text =
          lines |> Enum.slice(from, count) |> Enum.join("\n") |> normalize_lines()

        search_norm = normalize_lines(patch.search)

        if String.contains?(window_text, search_norm) do
          {:ok,
           %{
             start_line: from,
             end_line: to,
             search: patch.search,
             replace: patch.replace
           }}
        else
          {:error,
           "[patch_file] anchor found but search text not present in window (line #{idx})."}
        end
    end
  end

  @doc """
  Verify no two resolved patches touch overlapping line ranges. After
  sorting by `start_line`, it's enough to compare each patch with its
  predecessor — any overlap surfaces as an adjacent-pair overlap.
  """
  @spec check_overlaps([resolved_patch()]) :: :ok | {:error, String.t()}
  def check_overlaps(resolved) when is_list(resolved) do
    sorted = Enum.sort_by(resolved, & &1.start_line)

    overlap? =
      sorted
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.any?(fn [a, b] -> b.start_line <= a.end_line end)

    if overlap? do
      {:error,
       "[patch_file] patches overlap. Each patch must target a non-overlapping section."}
    else
      :ok
    end
  end

  @doc """
  Apply resolved patches to `lines`, in reverse `start_line` order so
  earlier rewrites don't shift the line numbers of later patches. Each
  patch's `search` text is replaced once within its anchor window.
  """
  @spec apply_patches([String.t()], [resolved_patch()]) ::
          {:ok, [String.t()]} | {:error, String.t()}
  def apply_patches(lines, resolved) when is_list(lines) and is_list(resolved) do
    sorted = Enum.sort_by(resolved, & &1.start_line, :desc)

    Enum.reduce_while(sorted, {:ok, lines}, fn p, {:ok, acc} ->
      count = p.end_line - p.start_line + 1

      window_text =
        acc |> Enum.slice(p.start_line, count) |> Enum.join("\n") |> normalize_lines()

      search_norm = normalize_lines(p.search)

      if String.contains?(window_text, search_norm) do
        new_window =
          String.replace(window_text, search_norm, normalize_lines(p.replace), global: false)

        new_lines = String.split(new_window, "\n")

        before_window = Enum.slice(acc, 0, p.start_line)
        after_window = Enum.drop(acc, p.end_line + 1)

        {:cont, {:ok, before_window ++ new_lines ++ after_window}}
      else
        {:halt,
         {:error,
          "[patch_file] search text not found in anchor window " <>
            "(lines #{p.start_line}–#{p.end_line}). " <>
            "Re-run with compute_anchors=true to refresh anchors."}}
      end
    end)
  end

  @doc """
  Read `file_path`, resolve and validate every patch, apply them
  atomically in reverse line order, and write the result back.

  Options:

    * `:context_lines` — default radius for patches that don't specify
      `:context_lines` themselves (default `5`).
    * `:dry_run` — when `true`, returns the new content without writing.

  Returns `{:ok, summary}` on success or `{:error, reason}` if any
  anchor, search, or overlap check fails. On error nothing is written.
  """
  @spec patch_file(Path.t(), [patch()], keyword()) ::
          {:ok, %{file: Path.t(), patches_applied: non_neg_integer(), content: String.t()}}
          | {:error, term()}
  def patch_file(file_path, patches, opts \\ []) when is_list(patches) do
    default_ctx = Keyword.get(opts, :context_lines, @default_context_lines)
    dry_run? = Keyword.get(opts, :dry_run, false)

    with [_ | _] <- patches || [],
         {:ok, content} <- File.read(file_path) do
      lines = String.split(content, "\n")

      with {:ok, resolved} <- resolve_all(lines, patches, default_ctx),
           :ok <- check_overlaps(resolved),
           {:ok, new_lines} <- apply_patches(lines, resolved) do
        new_content = Enum.join(new_lines, "\n")

        unless dry_run?, do: File.write!(file_path, new_content)

        {:ok,
         %{
           file: file_path,
           patches_applied: length(patches),
           content: new_content
         }}
      end
    else
      [] ->
        {:error, "[patch_file] patches list is required and must be non-empty."}

      {:error, _} = err ->
        err
    end
  end

  defp resolve_all(lines, patches, default_ctx) do
    Enum.reduce_while(patches, {:ok, []}, fn p, {:ok, acc} ->
      case resolve_patch(lines, p, default_ctx) do
        {:ok, r} -> {:cont, {:ok, [r | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      err -> err
    end
  end
end
