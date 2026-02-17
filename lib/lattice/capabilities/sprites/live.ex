defmodule Lattice.Capabilities.Sprites.Live do
  @moduledoc """
  Live implementation of the Sprites capability backed by the Sprites API.

  Communicates with the Sprites REST API at `api.sprites.dev` using `:httpc`
  (Erlang's built-in HTTP client). Auth is via a Bearer token read from the
  `SPRITES_API_TOKEN` environment variable.

  ## Status Mapping

  The API returns string statuses that are mapped to internal atoms:

  | API Status  | Internal Atom   |
  |-------------|-----------------|
  | `"cold"`    | `:hibernating`  |
  | `"warm"`    | `:waking`       |
  | `"running"` | `:ready`        |
  | other       | `:error`        |
  """

  @behaviour Lattice.Capabilities.Sprites

  require Logger

  @default_base_url "https://api.sprites.dev"
  @default_timeout 15_000
  @api_version "v1"

  # ── Callbacks ──────────────────────────────────────────────────────────

  @impl true
  def create_sprite(name, _opts \\ []) do
    body = %{"name" => name}

    case post("/#{@api_version}/sprites", body) do
      {:ok, sprite} when is_map(sprite) ->
        {:ok, parse_sprite(sprite)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def list_sprites do
    case get("/#{@api_version}/sprites") do
      {:ok, sprites} when is_list(sprites) ->
        {:ok, Enum.map(sprites, &parse_sprite/1)}

      {:ok, %{"data" => sprites}} when is_list(sprites) ->
        {:ok, Enum.map(sprites, &parse_sprite/1)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def get_sprite(id) do
    case get("/#{@api_version}/sprites/#{URI.encode(id)}") do
      {:ok, sprite} when is_map(sprite) ->
        {:ok, parse_sprite(sprite)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def wake(id) do
    case put("/#{@api_version}/sprites/#{URI.encode(id)}", %{status: "running"}) do
      {:ok, sprite} when is_map(sprite) ->
        {:ok, parse_sprite(sprite)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def sleep(id) do
    case delete("/#{@api_version}/sprites/#{URI.encode(id)}") do
      {:ok, sprite} when is_map(sprite) ->
        {:ok, parse_sprite(sprite)}

      {:ok, :no_content} ->
        {:ok, %{id: id, status: :hibernating}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def exec(id, command) do
    query = URI.encode_query([{"cmd", command}])
    path = "/#{@api_version}/sprites/#{URI.encode(id)}/exec?#{query}"

    case post(path, nil) do
      {:ok, result} when is_map(result) ->
        {:ok, parse_exec_result(id, command, result)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def fetch_logs(id, opts) do
    query = build_log_query(opts)
    path = "/#{@api_version}/sprites/#{URI.encode(id)}/services"

    case get(path <> query) do
      {:ok, services} when is_list(services) ->
        # Aggregate logs from all services
        logs = Enum.flat_map(services, fn svc -> Map.get(svc, "logs", []) end)
        {:ok, logs}

      {:ok, %{"data" => services}} when is_list(services) ->
        logs = Enum.flat_map(services, fn svc -> Map.get(svc, "logs", []) end)
        {:ok, logs}

      {:ok, _other} ->
        {:ok, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ── HTTP Helpers ───────────────────────────────────────────────────────

  defp get(path) do
    request(:get, path, nil)
  end

  defp post(path, body) do
    request(:post, path, body)
  end

  defp put(path, body) do
    request(:put, path, body)
  end

  defp delete(path) do
    request(:delete, path, nil)
  end

  defp request(method, path, body) do
    url = build_url(path)
    headers = build_headers()

    httpc_request = build_httpc_request(method, url, headers, body)

    Logger.debug("Sprites API #{method |> to_string() |> String.upcase()} #{path}")

    case :httpc.request(method, httpc_request, http_opts(), []) do
      {:ok, {{_http_version, status, _reason}, _resp_headers, resp_body}} ->
        handle_response(status, resp_body)

      {:error, reason} ->
        Logger.error("Sprites API request failed: #{inspect(reason)}")
        {:error, {:request_failed, reason}}
    end
  end

  defp build_httpc_request(:get, url, headers, _body) do
    {url, headers}
  end

  defp build_httpc_request(:delete, url, headers, _body) do
    {url, headers}
  end

  defp build_httpc_request(_method, url, headers, body) do
    encoded_body = if body, do: Jason.encode!(body), else: ""
    {url, headers, ~c"application/json", encoded_body}
  end

  defp build_url(path) do
    base = base_url()
    String.to_charlist(base <> path)
  end

  defp build_headers do
    token = auth_token()
    [{~c"authorization", String.to_charlist("Bearer #{token}")}]
  end

  defp http_opts do
    [
      timeout: timeout(),
      connect_timeout: timeout(),
      ssl: ssl_opts()
    ]
  end

  defp ssl_opts do
    [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      depth: 3,
      customize_hostname_check: [
        match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
      ]
    ]
  end

  # ── Response Handling ──────────────────────────────────────────────────

  defp handle_response(status, _body) when status == 204 do
    {:ok, :no_content}
  end

  defp handle_response(status, body) when status in 200..299 do
    body
    |> to_string()
    |> decode_json()
  end

  defp handle_response(401, _body) do
    Logger.error("Sprites API authentication failed (401)")
    {:error, :unauthorized}
  end

  defp handle_response(404, _body) do
    {:error, :not_found}
  end

  defp handle_response(429, _body) do
    Logger.warning("Sprites API rate limited (429)")
    {:error, :rate_limited}
  end

  defp handle_response(status, body) when status in 400..499 do
    Logger.warning("Sprites API client error (#{status}): #{to_string(body)}")
    {:error, {:client_error, status, to_string(body)}}
  end

  defp handle_response(status, body) when status >= 500 do
    Logger.error("Sprites API server error (#{status}): #{to_string(body)}")
    {:error, {:server_error, status, to_string(body)}}
  end

  defp decode_json(""), do: {:ok, %{}}

  defp decode_json(body) do
    case Jason.decode(body) do
      {:ok, parsed} -> {:ok, parsed}
      {:error, _} -> {:error, {:invalid_json, body}}
    end
  end

  # ── Parsing ────────────────────────────────────────────────────────────

  @doc false
  def parse_sprite(data) when is_map(data) do
    %{
      id: data["id"] || data["name"],
      name: data["name"],
      status: parse_status(data["status"]),
      organization: data["organization"],
      url: data["url"],
      created_at: data["created_at"],
      updated_at: data["updated_at"],
      last_started_at: data["last_started_at"],
      last_active_at: data["last_active_at"]
    }
  end

  @doc false
  def parse_status("cold"), do: :hibernating
  def parse_status("warm"), do: :waking
  def parse_status("running"), do: :ready
  def parse_status(nil), do: :error
  def parse_status(_other), do: :error

  defp parse_exec_result(id, command, result) do
    %{
      sprite_id: id,
      command: command,
      output: result["stdout"] || result["output"] || "",
      exit_code: result["exit_code"] || result["exitCode"] || 0
    }
  end

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

  defp timeout do
    Application.get_env(:lattice, :sprites_api_timeout, @default_timeout)
  end
end
