defmodule Lattice.Events.ApprovalNeeded do
  @moduledoc """
  Event emitted when a Sprite action requires human-in-the-loop approval.

  When the safety classifier determines an action is dangerous or needs review,
  this event is broadcast so the dashboard can display it in the approvals queue
  and a GitHub issue can be created for the approval workflow.
  """

  @type t :: %__MODULE__{
          sprite_id: String.t(),
          action: String.t(),
          classification: :needs_review | :dangerous,
          context: map(),
          timestamp: DateTime.t()
        }

  @enforce_keys [:sprite_id, :action, :classification, :timestamp]
  defstruct [:sprite_id, :action, :classification, :timestamp, context: %{}]

  @valid_classifications [:needs_review, :dangerous]

  @doc """
  Creates a new ApprovalNeeded event.

  ## Examples

      iex> Lattice.Events.ApprovalNeeded.new("sprite-001", "deploy to prod", :dangerous)
      {:ok, %Lattice.Events.ApprovalNeeded{sprite_id: "sprite-001", action: "deploy to prod", classification: :dangerous, ...}}

  """
  @spec new(String.t(), String.t(), atom(), keyword()) :: {:ok, t()} | {:error, term()}
  def new(sprite_id, action, classification, opts \\ [])

  def new(sprite_id, action, classification, opts)
      when classification in @valid_classifications do
    {:ok,
     %__MODULE__{
       sprite_id: sprite_id,
       action: action,
       classification: classification,
       context: Keyword.get(opts, :context, %{}),
       timestamp: Keyword.get(opts, :timestamp, DateTime.utc_now())
     }}
  end

  def new(_sprite_id, _action, classification, _opts) do
    {:error, {:invalid_classification, classification}}
  end

  @doc "Returns the list of valid approval classifications."
  @spec valid_classifications() :: [atom()]
  def valid_classifications, do: @valid_classifications
end
