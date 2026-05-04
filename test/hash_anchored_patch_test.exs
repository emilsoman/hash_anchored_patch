defmodule HashAnchoredPatchTest do
  use ExUnit.Case, async: true

  @sample """
  defmodule Foo do
    def hello do
      IO.puts("hi")
    end

    def world do
      IO.puts("world")
      IO.puts("here")
    end

    def bye do
      IO.puts("bye")
    end
  end
  """

  setup do
    path = Path.join(System.tmp_dir!(), "hap_#{System.unique_integer([:positive])}.ex")
    File.write!(path, @sample)
    on_exit(fn -> File.rm(path) end)
    {:ok, path: path}
  end

  describe "normalize_lines/1" do
    test "converts CRLF to LF" do
      assert HashAnchoredPatch.normalize_lines("a\r\nb\r\nc") == "a\nb\nc"
    end
  end

  describe "compute_anchor/3" do
    test "is deterministic for the same window" do
      lines = String.split("a\nb\nc\nd\ne", "\n")

      assert HashAnchoredPatch.compute_anchor(lines, 2, 1) ==
               HashAnchoredPatch.compute_anchor(lines, 2, 1)
    end

    test "differs across center lines" do
      lines = String.split("a\nb\nc\nd\ne", "\n")

      refute HashAnchoredPatch.compute_anchor(lines, 1, 1) ==
               HashAnchoredPatch.compute_anchor(lines, 3, 1)
    end

    test "clamps the window at file bounds" do
      lines = ["only"]
      hash = HashAnchoredPatch.compute_anchor(lines, 0, 5)
      assert is_binary(hash) and byte_size(hash) == 64
    end
  end

  describe "build_anchor_map/2" do
    test "produces one entry per line with hash, line, preview", %{path: path} do
      content = File.read!(path)
      anchors = HashAnchoredPatch.build_anchor_map(content)

      assert length(anchors) == length(String.split(content, "\n"))

      Enum.each(anchors, fn a ->
        assert byte_size(a.anchor_hash) == 64
        assert a.context_lines == 5
        assert is_integer(a.line)
        assert is_binary(a.preview)
      end)
    end
  end

  describe "compute_anchors/2" do
    test "matches build_anchor_map for the same content", %{path: path} do
      {:ok, from_disk} = HashAnchoredPatch.compute_anchors(path)
      from_mem = HashAnchoredPatch.build_anchor_map(File.read!(path))
      assert from_disk == from_mem
    end

    test "returns {:error, _} for missing files" do
      assert {:error, :enoent} = HashAnchoredPatch.compute_anchors("/no/such/file.ex")
    end
  end

  describe "patch_file/3 — happy paths" do
    test "applies a single patch", %{path: path} do
      {:ok, anchors} = HashAnchoredPatch.compute_anchors(path)
      target = Enum.find(anchors, &String.contains?(&1.preview, ~s|IO.puts("world")|))

      patches = [
        %{
          anchor_hash: target.anchor_hash,
          search: ~s|IO.puts("world")|,
          replace: ~s|IO.puts("WORLD!")|
        }
      ]

      assert {:ok, %{patches_applied: 1, content: content}} =
               HashAnchoredPatch.patch_file(path, patches)

      assert content =~ ~s|IO.puts("WORLD!")|
      refute content =~ ~s|IO.puts("world")|
      assert File.read!(path) == content
    end

    test "applies multiple non-overlapping patches atomically and in reverse order", %{path: path} do
      {:ok, anchors} = HashAnchoredPatch.compute_anchors(path, 1)
      hi = Enum.find(anchors, &String.contains?(&1.preview, ~s|IO.puts("hi")|))
      bye = Enum.find(anchors, &String.contains?(&1.preview, ~s|IO.puts("bye")|))

      patches = [
        %{
          anchor_hash: hi.anchor_hash,
          context_lines: 1,
          search: ~s|IO.puts("hi")|,
          replace: ~s|IO.puts("HI")|
        },
        %{
          anchor_hash: bye.anchor_hash,
          context_lines: 1,
          search: ~s|IO.puts("bye")|,
          replace: ~s|IO.puts("BYE")|
        }
      ]

      assert {:ok, %{patches_applied: 2, content: content}} =
               HashAnchoredPatch.patch_file(path, patches, context_lines: 1)

      assert content =~ ~s|IO.puts("HI")|
      assert content =~ ~s|IO.puts("BYE")|
    end

    test "dry_run does not write to disk", %{path: path} do
      original = File.read!(path)
      {:ok, anchors} = HashAnchoredPatch.compute_anchors(path)
      target = Enum.find(anchors, &String.contains?(&1.preview, ~s|IO.puts("hi")|))

      patches = [
        %{anchor_hash: target.anchor_hash, search: ~s|IO.puts("hi")|, replace: ~s|IO.puts("HEY")|}
      ]

      assert {:ok, %{content: new_content}} =
               HashAnchoredPatch.patch_file(path, patches, dry_run: true)

      assert new_content =~ ~s|IO.puts("HEY")|
      assert File.read!(path) == original
    end
  end

  describe "patch_file/3 — error paths" do
    test "rejects empty patch list", %{path: path} do
      assert {:error, msg} = HashAnchoredPatch.patch_file(path, [])
      assert msg =~ "patches list is required"
    end

    test "rejects an unknown anchor", %{path: path} do
      bogus = String.duplicate("0", 64)
      patches = [%{anchor_hash: bogus, search: "x", replace: "y"}]
      assert {:error, msg} = HashAnchoredPatch.patch_file(path, patches)
      assert msg =~ "anchor_hash"
      assert msg =~ "not found"
    end

    test "rejects a patch whose search text isn't in the anchor window", %{path: path} do
      {:ok, anchors} = HashAnchoredPatch.compute_anchors(path)
      target = Enum.find(anchors, &String.contains?(&1.preview, ~s|IO.puts("hi")|))

      patches = [
        %{anchor_hash: target.anchor_hash, search: "TEXT THAT IS NOT IN THE FILE", replace: "z"}
      ]

      assert {:error, msg} = HashAnchoredPatch.patch_file(path, patches)
      assert msg =~ "search text not present"
    end

    test "rejects overlapping patches", %{path: path} do
      {:ok, anchors} = HashAnchoredPatch.compute_anchors(path)
      a = Enum.find(anchors, &String.contains?(&1.preview, ~s|IO.puts("world")|))
      b = Enum.find(anchors, &String.contains?(&1.preview, ~s|IO.puts("here")|))

      patches = [
        %{anchor_hash: a.anchor_hash, search: ~s|IO.puts("world")|, replace: "X"},
        %{anchor_hash: b.anchor_hash, search: ~s|IO.puts("here")|, replace: "Y"}
      ]

      assert {:error, msg} = HashAnchoredPatch.patch_file(path, patches)
      assert msg =~ "overlap"
    end

    test "leaves the file untouched when any patch fails", %{path: path} do
      original = File.read!(path)
      {:ok, anchors} = HashAnchoredPatch.compute_anchors(path)
      good = Enum.find(anchors, &String.contains?(&1.preview, ~s|IO.puts("hi")|))

      patches = [
        %{anchor_hash: good.anchor_hash, search: ~s|IO.puts("hi")|, replace: ~s|IO.puts("HEY")|},
        %{anchor_hash: String.duplicate("0", 64), search: "x", replace: "y"}
      ]

      assert {:error, _} = HashAnchoredPatch.patch_file(path, patches)
      assert File.read!(path) == original
    end
  end

  describe "check_overlaps/1" do
    test "passes when ranges are disjoint" do
      assert :ok =
               HashAnchoredPatch.check_overlaps([
                 %{start_line: 0, end_line: 2, search: "", replace: ""},
                 %{start_line: 3, end_line: 5, search: "", replace: ""}
               ])
    end

    test "rejects touching ranges" do
      assert {:error, _} =
               HashAnchoredPatch.check_overlaps([
                 %{start_line: 0, end_line: 3, search: "", replace: ""},
                 %{start_line: 3, end_line: 5, search: "", replace: ""}
               ])
    end
  end

  describe "CRLF handling" do
    test "anchors and search match across line endings" do
      crlf = "a\r\nb\r\nIO.puts(\"hi\")\r\nd\r\ne\r\n"
      lf = "a\nb\nIO.puts(\"hi\")\nd\ne\n"

      anchors_crlf = HashAnchoredPatch.build_anchor_map(crlf)
      anchors_lf = HashAnchoredPatch.build_anchor_map(lf)

      hashes = fn list -> Enum.map(list, & &1.anchor_hash) end
      assert hashes.(anchors_crlf) == hashes.(anchors_lf)
    end
  end
end
