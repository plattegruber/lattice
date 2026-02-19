defmodule Lattice.PRs.PR do
  @moduledoc """
  Represents a pull request tracked by Lattice.

  Captures the full lifecycle state of a PR that Lattice created or is
  monitoring, including review status, CI state, and links back to the
  originating intent.

  ## Review States

  - `:pending` — no reviews yet
  - `:approved` — at least one approving review, no outstanding changes requested
  - `:changes_requested` — at least one reviewer requested changes
  - `:commented` — only comment reviews (no approval/changes-requested)

  ## PR States

  - `:open` — PR is open
  - `:closed` — PR was closed without merging
  - `:merged` — PR was merged
  """

  @type review_state :: :pending | :approved | :changes_requested | :commented
  @type pr_state :: :open | :closed | :merged

  @type t :: %__MODULE__{
          number: pos_integer(),
          repo: String.t(),
          title: String.t() | nil,
          head_branch: String.t() | nil,
          base_branch: String.t() | nil,
          state: pr_state(),
          review_state: review_state(),
          mergeable: boolean() | nil,
          ci_status: atom() | nil,
          draft: boolean(),
          intent_id: String.t() | nil,
          run_id: String.t() | nil,
          url: String.t() | nil,
          created_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @enforce_keys [:number, :repo]
  defstruct [
    :number,
    :repo,
    :title,
    :head_branch,
    :base_branch,
    :intent_id,
    :run_id,
    :url,
    :mergeable,
    :ci_status,
    state: :open,
    review_state: :pending,
    draft: false,
    created_at: nil,
    updated_at: nil
  ]

  @doc """
  Create a new PR struct with defaults.

  ## Examples

      PR.new(42, "org/repo", intent_id: "int_abc", title: "Add feature")

  """
  @spec new(pos_integer(), String.t(), keyword()) :: t()
  def new(number, repo, opts \\ []) when is_integer(number) and is_binary(repo) do
    now = DateTime.utc_now()

    %__MODULE__{
      number: number,
      repo: repo,
      title: Keyword.get(opts, :title),
      head_branch: Keyword.get(opts, :head_branch),
      base_branch: Keyword.get(opts, :base_branch),
      state: Keyword.get(opts, :state, :open),
      review_state: Keyword.get(opts, :review_state, :pending),
      mergeable: Keyword.get(opts, :mergeable),
      ci_status: Keyword.get(opts, :ci_status),
      draft: Keyword.get(opts, :draft, false),
      intent_id: Keyword.get(opts, :intent_id),
      run_id: Keyword.get(opts, :run_id),
      url: Keyword.get(opts, :url),
      created_at: Keyword.get(opts, :created_at, now),
      updated_at: Keyword.get(opts, :updated_at, now)
    }
  end

  @doc """
  Update a PR with new fields, automatically bumping `updated_at`.
  """
  @spec update(t(), keyword()) :: t()
  def update(%__MODULE__{} = pr, fields) do
    pr
    |> struct!(fields)
    |> struct!(updated_at: DateTime.utc_now())
  end

  @doc """
  Returns true if the PR needs attention (changes requested or failing CI).
  """
  @spec needs_attention?(t()) :: boolean()
  def needs_attention?(%__MODULE__{state: :open, review_state: :changes_requested}), do: true
  def needs_attention?(%__MODULE__{state: :open, ci_status: :failure}), do: true
  def needs_attention?(%__MODULE__{state: :open, mergeable: false}), do: true
  def needs_attention?(_pr), do: false

  @doc """
  Returns true if the PR is ready to merge (approved, CI passing, mergeable).
  """
  @spec merge_ready?(t()) :: boolean()
  def merge_ready?(%__MODULE__{
        state: :open,
        review_state: :approved,
        mergeable: true,
        ci_status: ci
      })
      when ci in [:success, nil],
      do: true

  def merge_ready?(_pr), do: false
end
