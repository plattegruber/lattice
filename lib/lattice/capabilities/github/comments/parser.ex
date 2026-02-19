defmodule Lattice.Capabilities.GitHub.Comments.Parser do
  @moduledoc """
  Parses user responses from GitHub comments that reply to structured
  Lattice comments (questions, plans, etc.).

  Uses sentinel markers (`<!-- lattice:... -->`) embedded in the original
  comment to identify the comment type and extract metadata.
  """

  @sentinel_regex ~r/<!--\s*lattice:(\w+)\s+(.*?)\s*-->/

  @doc """
  Extract sentinel metadata from a comment body.

  Returns `{:ok, %{type: atom, attrs: map}}` or `:error` if no sentinel found.

  ## Examples

      iex> extract_sentinel("some text <!-- lattice:question intent_id=int_abc --> footer")
      {:ok, %{type: :question, attrs: %{"intent_id" => "int_abc"}}}

  """
  @spec extract_sentinel(String.t()) :: {:ok, %{type: atom(), attrs: map()}} | :error
  def extract_sentinel(body) when is_binary(body) do
    case Regex.run(@sentinel_regex, body) do
      [_, type, attrs_str] ->
        attrs = parse_attrs(attrs_str)
        {:ok, %{type: String.to_existing_atom(type), attrs: attrs}}

      nil ->
        :error
    end
  rescue
    ArgumentError -> :error
  end

  @doc """
  Parse a user's response to a question comment.

  Detects checked checkboxes (`- [x]`) and extracts freeform text that
  isn't part of the original template structure. Returns structured response
  data or `{:error, :not_a_response}` if the comment doesn't look like a reply.

  ## Examples

      iex> parse_response("- [x] **1.** Deploy to staging\\n- [ ] **2.** Skip\\n\\nAlso please run tests")
      {:ok, %{checked: [1], freeform: "Also please run tests"}}

  """
  @spec parse_response(String.t()) ::
          {:ok, %{checked: [integer()], freeform: String.t()}} | {:error, :not_a_response}
  def parse_response(body) when is_binary(body) do
    checked = extract_checked_items(body)
    freeform = extract_freeform(body)

    if checked == [] and freeform == "" do
      {:error, :not_a_response}
    else
      {:ok, %{checked: checked, freeform: String.trim(freeform)}}
    end
  end

  @doc """
  Parse a full comment, extracting both sentinel info and response data.

  Combines `extract_sentinel/1` and `parse_response/1` for convenience.
  Returns a structured map with intent_id, comment type, and response payload.
  """
  @spec parse_comment(String.t()) ::
          {:ok, map()} | {:error, :not_a_lattice_comment | :not_a_response}
  def parse_comment(body) when is_binary(body) do
    case extract_sentinel(body) do
      {:ok, %{type: type, attrs: attrs}} ->
        case parse_response(body) do
          {:ok, response} ->
            {:ok,
             %{
               intent_id: Map.get(attrs, "intent_id"),
               type: type,
               response: response
             }}

          {:error, _} ->
            {:error, :not_a_response}
        end

      :error ->
        {:error, :not_a_lattice_comment}
    end
  end

  # ── Private ──────────────────────────────────────────────────────

  @checked_regex ~r/-\s*\[x\]\s*\*\*(\d+)\.\*\*/i

  defp extract_checked_items(body) do
    @checked_regex
    |> Regex.scan(body)
    |> Enum.map(fn [_, num] -> String.to_integer(num) end)
    |> Enum.sort()
  end

  defp extract_freeform(body) do
    body
    |> String.split("\n")
    |> Enum.reject(fn line ->
      trimmed = String.trim(line)

      trimmed == "" or
        String.starts_with?(trimmed, "- [") or
        String.starts_with?(trimmed, "##") or
        String.starts_with?(trimmed, "**") or
        String.starts_with?(trimmed, "<!--") or
        String.starts_with?(trimmed, "_Posted by")
    end)
    |> Enum.join("\n")
    |> String.trim()
  end

  defp parse_attrs(attrs_str) do
    ~r/(\w+)=(\S+)/
    |> Regex.scan(attrs_str)
    |> Map.new(fn [_, key, value] -> {key, value} end)
  end
end
