defmodule Lattice.Capabilities.Sprites.Live do
  @moduledoc """
  Live implementation of the Sprites capability backed by the `sprites-ex` SDK.

  Communicates with the Sprites REST API at `api.sprites.dev` using the official
  SDK. Auth is via a Bearer token read from the `SPRITES_API_TOKEN` environment
  variable.

  ## Status Mapping

  The API returns string statuses that map directly to atoms:

  | API Status  | Internal Atom |
  |-------------|---------------|
  | `"cold"`    | `:cold`       |
  | `"warm"`    | `:warm`       |
  | `"running"` | `:running`    |

  ## Wake / Sleep

  The Sprites API has no explicit wake/sleep endpoints. Sprites auto-wake when
  you run commands on them and go cold naturally after inactivity. Therefore:

  - `wake/1` runs a no-op command (`true`) to trigger auto-wake
  - `sleep/1` returns `{:ok, :noop}` — you cannot force a sprite to sleep
  """

  @behaviour Lattice.Capabilities.Sprites

  require Logger

  alias Lattice.Sprites.ExecSupervisor

  @default_base_url "https://api.sprites.dev"

  # ── Callbacks ──────────────────────────────────────────────────────────

  @impl true
  def create_sprite(name, _opts \\ []) do
    client = build_client()

    case Sprites.create(client, name) do
      {:ok, sprite} ->
        {:ok, parse_sprite(sprite)}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> {:error, normalize_error(e)}
  end

  @impl true
  def list_sprites do
    client = build_client()

    case Sprites.list(client) do
      {:ok, sprites} when is_list(sprites) ->
        {:ok, Enum.map(sprites, &parse_sprite/1)}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> {:error, normalize_error(e)}
  end

  @impl true
  def get_sprite(id) do
    client = build_client()

    case Sprites.get_sprite(client, id) do
      {:ok, data} ->
        {:ok, parse_sprite(data)}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> {:error, normalize_error(e)}
  end

  @impl true
  def wake(id) do
    # The Sprites API has no wake endpoint. Running any command triggers auto-wake.
    sprite = build_sprite(id)

    Logger.debug("Sprites API: waking #{id} via no-op command")
    Sprites.cmd(sprite, "true", [])

    # Fetch current state after the command triggers wake
    get_sprite(id)
  rescue
    e -> {:error, normalize_error(e)}
  end

  @impl true
  def sleep(_id) do
    # The Sprites API has no sleep endpoint. Sprites go cold naturally after inactivity.
    {:ok, :noop}
  end

  @impl true
  def delete_sprite(id) do
    sprite = build_sprite(id)

    case Sprites.destroy(sprite) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, normalize_error(e)}
  end

  @impl true
  def exec(id, command) do
    sprite = build_sprite(id)

    case Sprites.cmd(sprite, "sh", ["-c", command]) do
      {output, exit_code} ->
        {:ok, %{sprite_id: id, command: command, output: output, exit_code: exit_code}}
    end
  rescue
    e -> {:error, normalize_error(e)}
  end

  @impl true
  def exec_ws(sprite_id, command, opts \\ []) do
    args = [sprite_id: sprite_id, command: command] ++ opts
    ExecSupervisor.start_session(args)
  end

  @impl true
  def fetch_logs(id, opts) do
    # The SDK doesn't wrap the services endpoint, so use Req directly
    query = build_log_query(opts)
    url = "#{base_url()}/v1/sprites/#{URI.encode(id)}/services#{query}"
    token = auth_token()

    case Req.get(url, headers: [{"authorization", "Bearer #{token}"}]) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        services = normalize_services(body)
        logs = Enum.flat_map(services, fn svc -> Map.get(svc, "logs", []) end)
        {:ok, logs}

      {:ok, %{status: 404}} ->
        {:error, :not_found}

      {:ok, %{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> {:error, normalize_error(e)}
  end

  # ── Parsing ────────────────────────────────────────────────────────────

  @doc false
  def parse_sprite(%Sprites.Sprite{} = sprite) do
    %{
      id: sprite.name,
      name: sprite.name,
      status: parse_status(sprite.status),
      organization: nil,
      url: nil,
      created_at: nil,
      updated_at: nil,
      last_started_at: nil,
      last_active_at: nil
    }
  end

  def parse_sprite(data) when is_map(data) do
    name = field(data, "name")

    %{
      id: name || field(data, "id"),
      name: name,
      status: parse_status(field(data, "status")),
      organization: field(data, "organization"),
      url: field(data, "url"),
      created_at: field(data, "created_at"),
      updated_at: field(data, "updated_at"),
      last_started_at: field(data, "last_started_at"),
      last_active_at: field(data, "last_active_at")
    }
  end

  @doc false
  def parse_status("cold"), do: :cold
  def parse_status("warm"), do: :warm
  def parse_status("running"), do: :running
  def parse_status(nil), do: :cold
  def parse_status(_other), do: :cold

  # Look up a field by string key, falling back to atom key.
  # All keys passed here are hardcoded literals with existing atoms.
  defp field(data, key) when is_binary(key), do: data[key] || data[String.to_existing_atom(key)]

  # ── Private ────────────────────────────────────────────────────────────

  defp build_client do
    Sprites.new(auth_token(), base_url: base_url())
  end

  defp build_sprite(name) do
    client = build_client()
    Sprites.sprite(client, name)
  end

  defp normalize_services(body) when is_list(body), do: body
  defp normalize_services(%{"data" => services}) when is_list(services), do: services
  defp normalize_services(_), do: []

  defp normalize_error(%Sprites.Error.APIError{status: 404}), do: :not_found
  defp normalize_error(%Sprites.Error.APIError{status: 401}), do: :unauthorized
  defp normalize_error(%Sprites.Error.APIError{status: 429}), do: :rate_limited

  defp normalize_error(%Sprites.Error.APIError{status: status, message: message})
       when status in 400..499 do
    {:client_error, status, message || ""}
  end

  defp normalize_error(%Sprites.Error.APIError{status: status, message: message})
       when status >= 500 do
    {:server_error, status, message || ""}
  end

  defp normalize_error(%Sprites.Error.ConnectionError{reason: reason}) do
    {:connection_error, reason}
  end

  defp normalize_error(%Sprites.Error.TimeoutError{}), do: :timeout

  defp normalize_error(%Sprites.Error.CommandError{exit_code: code}) do
    {:command_error, code}
  end

  defp normalize_error(other), do: {:request_failed, other}

  defp build_log_query(opts) do
    params =
      opts
      |> Enum.flat_map(fn
        {:since, value} -> [{"since", to_string(value)}]
        {:limit, value} -> [{"limit", to_string(value)}]
        _ -> []
      end)

    case params do
      [] -> ""
      pairs -> "?" <> URI.encode_query(pairs)
    end
  end

  # ── Configuration ─────────────────────────────────────────────────────

  defp base_url do
    Application.get_env(:lattice, :resources)[:sprites_api_base] || @default_base_url
  end

  defp auth_token do
    System.get_env("SPRITES_API_TOKEN") ||
      raise "SPRITES_API_TOKEN environment variable is not set"
  end
end
