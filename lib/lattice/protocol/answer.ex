defmodule Lattice.Protocol.Answer do
  @moduledoc "Represents a human answer to a sprite question."

  defstruct [:question_prompt, :selected_choice, :free_text, :answered_by, :answered_at]

  @type t :: %__MODULE__{
          question_prompt: String.t() | nil,
          selected_choice: String.t() | nil,
          free_text: String.t() | nil,
          answered_by: String.t(),
          answered_at: DateTime.t()
        }

  @doc "Build an Answer from a map of attributes (atom or string keys)."
  @spec new(map()) :: t()
  def new(attrs) when is_map(attrs) do
    %__MODULE__{
      question_prompt: Map.get(attrs, :question_prompt) || Map.get(attrs, "question_prompt"),
      selected_choice: Map.get(attrs, :selected_choice) || Map.get(attrs, "selected_choice"),
      free_text: Map.get(attrs, :free_text) || Map.get(attrs, "free_text"),
      answered_by: Map.get(attrs, :answered_by) || Map.get(attrs, "answered_by") || "operator",
      answered_at: DateTime.utc_now()
    }
  end
end
