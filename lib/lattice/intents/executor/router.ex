defmodule Lattice.Intents.Executor.Router do
  @moduledoc """
  Routes approved intents to the appropriate executor.

  The Router examines the intent's kind, source, and payload to select the
  correct executor module. The routing logic is:

  - Task intents (run_task operation) -> `Executor.Task`
  - Action intents from sprites -> `Executor.Sprite`
  - Action intents from operators/cron/agents -> `Executor.ControlPlane`
  - Maintenance intents -> `Executor.ControlPlane`
  - Inquiry intents -> not executable (inquiries await human response)

  ## Extensibility

  The executor list is ordered by priority. The first executor that returns
  `true` from `can_execute?/1` wins. New executors can be added by extending
  the `@executors` list.
  """

  alias Lattice.Intents.Executor.ControlPlane
  alias Lattice.Intents.Executor.PrFixup
  alias Lattice.Intents.Executor.Sprite
  alias Lattice.Intents.Executor.Task
  alias Lattice.Intents.Intent

  @executors [Task, PrFixup, Sprite, ControlPlane]

  @doc """
  Select the executor module for a given intent.

  Returns `{:ok, executor_module}` if an executor can handle the intent,
  or `{:error, :no_executor}` if none of the registered executors accept it.
  """
  @spec route(Intent.t()) :: {:ok, module()} | {:error, :no_executor}
  def route(%Intent{} = intent) do
    case Enum.find(@executors, & &1.can_execute?(intent)) do
      nil -> {:error, :no_executor}
      executor -> {:ok, executor}
    end
  end

  @doc """
  Returns the list of registered executor modules, in priority order.
  """
  @spec executors() :: [module()]
  def executors, do: @executors
end
