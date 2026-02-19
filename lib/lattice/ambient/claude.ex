defmodule Lattice.Ambient.Claude do
  @moduledoc """
  Claude API client for ambient response decisions.

  Calls the Anthropic Messages API to classify GitHub events and optionally
  generate responses. Returns a structured decision: respond with a comment,
  react with a thumbs-up, or ignore.

  ## Configuration

  Requires `ANTHROPIC_API_KEY` environment variable or config:

      config :lattice, Lattice.Ambient.Claude,
        api_key: "sk-ant-...",
        model: "claude-sonnet-4-20250514"
  """

  require Logger

  @api_url "https://api.anthropic.com/v1/messages"
  @default_model "claude-sonnet-4-20250514"
  @max_tokens 1024

  @type decision :: :respond | :react | :ignore
  @type result :: {:ok, decision(), String.t() | nil} | {:error, term()}

  @doc """
  Classify a GitHub event and optionally generate a response.

  Returns `{:ok, :respond, "response text"}`, `{:ok, :react, nil}`,
  `{:ok, :ignore, nil}`, or `{:error, reason}`.

  ## Parameters

  - `event` — a map describing the event (type, body, author, etc.)
  - `thread_context` — list of prior messages in the thread for context
  """
  @spec classify(map(), [map()]) :: result()
  def classify(event, thread_context \\ []) do
    api_key = resolve_api_key()

    if is_nil(api_key) or api_key == "" do
      Logger.warning("Ambient Claude: no ANTHROPIC_API_KEY configured, defaulting to :ignore")
      {:ok, :ignore, nil}
    else
      prompt = build_prompt(event, thread_context)
      call_api(api_key, prompt)
    end
  end

  # ── Private: Prompt Construction ────────────────────────────────

  defp build_prompt(event, thread_context) do
    thread_text = format_thread(thread_context)

    event_text = """
    Event type: #{event[:type]}
    Author: #{event[:author]}
    Surface: #{event[:surface]}
    Number: #{event[:number]}

    Message body:
    #{event[:body]}
    """

    system = """
    You are Lattice, an AI coding agent control plane that monitors a GitHub repository. \
    You've received a new event from the repo you manage. Decide how to respond.

    Rules:
    1. If the message asks a question, requests feedback, or warrants a thoughtful reply → respond with a comment
    2. If the message is an acknowledgment, status update, or doesn't need a reply (e.g., "sounds good", "done", "merged") → react with thumbs-up
    3. If the event is noise (CI bot comments, auto-generated messages, dependency updates) → ignore
    4. Consider the full conversation thread for context
    5. Be helpful but concise. Don't be chatty or over-eager.
    6. When responding, speak as a knowledgeable teammate, not a bot.

    You MUST respond with EXACTLY one of these formats:
    - DECISION: respond
      <your response text here>
    - DECISION: react
    - DECISION: ignore
    """

    user_content =
      if thread_text != "" do
        """
        ## Thread context (previous messages):
        #{thread_text}

        ## New event:
        #{event_text}
        """
      else
        """
        ## New event:
        #{event_text}
        """
      end

    {system, user_content}
  end

  defp format_thread([]), do: ""

  defp format_thread(comments) do
    comments
    |> Enum.map(fn c ->
      "**#{c[:user] || "unknown"}**: #{c[:body] || ""}"
    end)
    |> Enum.join("\n\n")
  end

  # ── Private: API Call ───────────────────────────────────────────

  defp call_api(api_key, {system, user_content}) do
    model = config(:model, @default_model)

    payload =
      Jason.encode!(%{
        model: model,
        max_tokens: @max_tokens,
        system: system,
        messages: [
          %{role: "user", content: user_content}
        ]
      })

    headers = [
      {~c"x-api-key", String.to_charlist(api_key)},
      {~c"anthropic-version", ~c"2023-06-01"},
      {~c"content-type", ~c"application/json"}
    ]

    request =
      {String.to_charlist(@api_url), headers, ~c"application/json", String.to_charlist(payload)}

    http_opts = [timeout: 60_000, connect_timeout: 10_000]

    case :httpc.request(:post, request, http_opts, []) do
      {:ok, {{_, 200, _}, _resp_headers, resp_body}} ->
        parse_response(to_string(resp_body))

      {:ok, {{_, 429, _}, _resp_headers, _resp_body}} ->
        Logger.warning("Ambient Claude: rate limited")
        {:error, :rate_limited}

      {:ok, {{_, status, _}, _resp_headers, resp_body}} ->
        Logger.error("Ambient Claude: API error #{status}: #{to_string(resp_body)}")
        {:error, {:api_error, status}}

      {:error, reason} ->
        Logger.error("Ambient Claude: request failed: #{inspect(reason)}")
        {:error, {:request_failed, reason}}
    end
  end

  defp parse_response(body) do
    case Jason.decode(body) do
      {:ok, %{"content" => [%{"text" => text} | _]}} ->
        parse_decision(text)

      {:ok, other} ->
        Logger.error("Ambient Claude: unexpected response shape: #{inspect(other)}")
        {:error, :unexpected_response}

      {:error, _} ->
        {:error, :invalid_json}
    end
  end

  defp parse_decision(text) do
    cond do
      String.contains?(text, "DECISION: respond") ->
        # Extract everything after "DECISION: respond\n"
        response =
          text
          |> String.split("DECISION: respond", parts: 2)
          |> List.last()
          |> String.trim()

        {:ok, :respond, response}

      String.contains?(text, "DECISION: react") ->
        {:ok, :react, nil}

      String.contains?(text, "DECISION: ignore") ->
        {:ok, :ignore, nil}

      true ->
        # If Claude didn't follow the format exactly, try to infer
        Logger.warning("Ambient Claude: non-standard response, defaulting to ignore: #{text}")
        {:ok, :ignore, nil}
    end
  end

  # ── Private: Config ─────────────────────────────────────────────

  defp resolve_api_key do
    config(:api_key, nil) || System.get_env("ANTHROPIC_API_KEY")
  end

  defp config(key, default) do
    Application.get_env(:lattice, __MODULE__, [])
    |> Keyword.get(key, default)
  end
end
