defmodule Lattice.Connections.GitHubRepos do
  @moduledoc """
  Lists GitHub repositories accessible to a user via their OAuth token.

  Used by the repo connection UI to show a picker of available repos.
  """

  require Logger

  @api_base "https://api.github.com"

  @doc """
  List repositories accessible to the user with the given GitHub token.

  Returns `{:ok, repos}` where each repo is a map with `:full_name`, `:private`,
  and `:description` keys. Sorted by most recently pushed.
  """
  @spec list(String.t()) :: {:ok, [map()]} | {:error, term()}
  def list(github_token) when is_binary(github_token) do
    url = ~c"#{@api_base}/user/repos?sort=pushed&per_page=50&type=all"

    headers = [
      {~c"authorization", ~c"Bearer #{github_token}"},
      {~c"accept", ~c"application/vnd.github+json"},
      {~c"x-github-api-version", ~c"2022-11-28"},
      {~c"user-agent", ~c"Lattice/1.0"}
    ]

    case :httpc.request(:get, {url, headers}, [timeout: 15_000], []) do
      {:ok, {{_, 200, _}, _headers, body}} ->
        parse_repos_response(to_string(body))

      {:ok, {{_, 401, _}, _headers, _body}} ->
        {:error, :unauthorized}

      {:ok, {{_, status, _}, _headers, body}} ->
        Logger.warning("GitHub repos list failed (status #{status}): #{to_string(body)}")
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  defp parse_repos_response(body_str) do
    case Jason.decode(body_str) do
      {:ok, repos} when is_list(repos) ->
        parsed =
          Enum.map(repos, fn r ->
            %{
              full_name: r["full_name"],
              private: r["private"],
              description: r["description"]
            }
          end)

        {:ok, parsed}

      _ ->
        {:error, :invalid_response}
    end
  end
end
