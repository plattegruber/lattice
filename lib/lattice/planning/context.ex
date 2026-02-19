defmodule Lattice.Planning.Context do
  @moduledoc """
  Conversational context per intent — tracks question/answer pairs and
  accumulated information during planning and dialogue.

  Stored in-memory (ETS) keyed by intent ID. Used by the dialogue engine
  to maintain state across multiple rounds of clarification.

  ## Example

      Context.add_question("int-123", "What environment?", ["staging", "production"])
      Context.add_answer("int-123", 0, "production")
      Context.get("int-123")
      #=> %Context{intent_id: "int-123", exchanges: [...], notes: []}
  """

  alias Lattice.Store.ETS, as: MetadataStore

  @namespace :planning_contexts

  @type exchange :: %{
          question: String.t(),
          options: [String.t()],
          answer: String.t() | nil,
          asked_at: DateTime.t(),
          answered_at: DateTime.t() | nil
        }

  @type t :: %__MODULE__{
          intent_id: String.t(),
          exchanges: [exchange()],
          notes: [String.t()],
          updated_at: DateTime.t()
        }

  defstruct [:intent_id, exchanges: [], notes: [], updated_at: nil]

  # ── Public API ──────────────────────────────────────────────────

  @doc "Get or initialize context for an intent."
  @spec get(String.t()) :: t()
  def get(intent_id) do
    case MetadataStore.get(@namespace, intent_id) do
      {:ok, data} when is_map(data) -> from_map(data)
      {:error, :not_found} -> %__MODULE__{intent_id: intent_id, updated_at: DateTime.utc_now()}
    end
  end

  @doc "Add a clarifying question to the context."
  @spec add_question(String.t(), String.t(), [String.t()]) :: t()
  def add_question(intent_id, question, options \\ []) do
    ctx = get(intent_id)

    exchange = %{
      question: question,
      options: options,
      answer: nil,
      asked_at: DateTime.utc_now(),
      answered_at: nil
    }

    updated = %{ctx | exchanges: ctx.exchanges ++ [exchange], updated_at: DateTime.utc_now()}
    save(updated)
    updated
  end

  @doc "Record an answer for the most recent unanswered question."
  @spec add_answer(String.t(), non_neg_integer(), String.t()) ::
          {:ok, t()} | {:error, :no_pending_question}
  def add_answer(intent_id, question_index, answer) do
    ctx = get(intent_id)

    if question_index < length(ctx.exchanges) do
      exchanges =
        List.update_at(ctx.exchanges, question_index, fn ex ->
          %{ex | answer: answer, answered_at: DateTime.utc_now()}
        end)

      updated = %{ctx | exchanges: exchanges, updated_at: DateTime.utc_now()}
      save(updated)
      {:ok, updated}
    else
      {:error, :no_pending_question}
    end
  end

  @doc "Add a free-form note to the context."
  @spec add_note(String.t(), String.t()) :: t()
  def add_note(intent_id, note) do
    ctx = get(intent_id)
    updated = %{ctx | notes: ctx.notes ++ [note], updated_at: DateTime.utc_now()}
    save(updated)
    updated
  end

  @doc "Check if all questions have been answered."
  @spec all_answered?(t()) :: boolean()
  def all_answered?(%__MODULE__{exchanges: exchanges}) do
    Enum.all?(exchanges, fn ex -> ex.answer != nil end)
  end

  @doc "Get unanswered questions."
  @spec pending_questions(t()) :: [{non_neg_integer(), exchange()}]
  def pending_questions(%__MODULE__{exchanges: exchanges}) do
    exchanges
    |> Enum.with_index()
    |> Enum.filter(fn {ex, _idx} -> ex.answer == nil end)
    |> Enum.map(fn {ex, idx} -> {idx, ex} end)
  end

  @doc "Render context as Markdown for display."
  @spec to_markdown(t()) :: String.t()
  def to_markdown(%__MODULE__{} = ctx) do
    header = "## Planning Context\n\n"

    exchanges_md =
      ctx.exchanges
      |> Enum.with_index(1)
      |> Enum.map_join("\n\n", fn {ex, idx} ->
        answer_text =
          if ex.answer, do: "> **A:** #{ex.answer}", else: "> _Awaiting answer..._"

        """
        ### Q#{idx}: #{ex.question}
        #{format_options(ex.options)}
        #{answer_text}\
        """
      end)

    notes_md =
      if ctx.notes == [] do
        ""
      else
        "\n\n### Notes\n\n" <> Enum.map_join(ctx.notes, "\n", &("- " <> &1))
      end

    header <> exchanges_md <> notes_md
  end

  @doc "Delete context for an intent."
  @spec delete(String.t()) :: :ok
  def delete(intent_id) do
    MetadataStore.delete(@namespace, intent_id)
    :ok
  end

  # ── Private ─────────────────────────────────────────────────────

  defp save(%__MODULE__{intent_id: id} = ctx) do
    MetadataStore.put(@namespace, id, Map.from_struct(ctx))
  end

  defp from_map(data) do
    %__MODULE__{
      intent_id: data[:intent_id] || data["intent_id"],
      exchanges: data[:exchanges] || data["exchanges"] || [],
      notes: data[:notes] || data["notes"] || [],
      updated_at: data[:updated_at] || data["updated_at"]
    }
  end

  defp format_options([]), do: ""

  defp format_options(options) do
    options
    |> Enum.with_index(1)
    |> Enum.map_join("\n", fn {opt, idx} -> "> #{idx}. #{opt}" end)
  end
end
