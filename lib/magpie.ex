defmodule Magpie do
  @moduledoc """
  Core HTTP layer for the Dropbox API v2.

  Builds authenticated `Req` requests and normalizes responses. RPC-style
  endpoints go through `post/3`, while content endpoints (file bytes) go
  through `upload_request/5` and `download_request/5`.

  Requests are authenticated by the client's `Magpie.Auth.TokenProvider`: a
  request step asks it for an access token, and when Dropbox answers `401
  expired_access_token` a response step refreshes the token and replays the
  request once.

  The Dropbox endpoints can be overridden (rarely needed) via:

      config :magpie,
        base_url: "https://api.dropboxapi.com/2",
        upload_url: "https://content.dropboxapi.com/2/",
        oauth_authorize_url: "https://www.dropbox.com/oauth2/authorize",
        oauth_token_url: "https://api.dropboxapi.com/oauth2/token"

  Extra options merged into every request (e.g. `plug: {Req.Test, Magpie}`
  for testing) can be set with `config :magpie, req_options: [...]`.

  Selected read-only file routes — downloads, metadata, temporary links,
  listings, revisions and search — retry transient failures by default. Tune
  the maximum attempts, log level, or delay controller with:

      config :magpie,
        retry: [max_retries: 3, log_level: :warning]

  Setting `retry: false` disables automatic retries. A `:delay` integer or
  one-arity function overrides `Retry-After`/exponential backoff. Mutation
  routes are never retried automatically, regardless of this setting.

  Use `Magpie.Client.new/2` or `Magpie.Client.with_options/2` to override
  configuration per client, and `request: [...]` on Storage calls to override
  it per operation. See the [configuration guide](configuration.html) for
  precedence, execution budgets and diagnostic fields.
  """

  @default_base_url "https://api.dropboxapi.com/2"
  @default_upload_url "https://content.dropboxapi.com/2/"
  @default_oauth_authorize_url "https://www.dropbox.com/oauth2/authorize"
  @default_oauth_token_url "https://api.dropboxapi.com/oauth2/token"

  # Dropbox's API is POST-only, including reads. Req therefore cannot infer
  # which calls are safe to repeat from the HTTP method alone.
  @retryable_reads MapSet.new([
                     "/files/download",
                     "/files/get_metadata",
                     "/files/get_temporary_link",
                     "/files/get_temporary_upload_link",
                     "/files/list_folder",
                     "/files/list_folder/continue",
                     "/files/list_revisions",
                     "/files/search_v2",
                     "/files/search/continue_v2"
                   ])

  @type response :: {:ok, term()} | {:error, Magpie.Error.t()}

  @type response_download ::
          {:ok, %{body: binary(), headers: list() | map()}} | {:error, Magpie.Error.t()}

  @doc "Base URL for RPC endpoints."
  def base_url, do: Application.get_env(:magpie, :base_url, @default_base_url)

  @doc "Base URL for content (upload/download) endpoints."
  def upload_url, do: Application.get_env(:magpie, :upload_url, @default_upload_url)

  @doc "URL where users authorize the app (OAuth 2 authorization endpoint)."
  def oauth_authorize_url,
    do: Application.get_env(:magpie, :oauth_authorize_url, @default_oauth_authorize_url)

  @doc "OAuth 2 token endpoint — note it lives outside the `/2` base URL."
  def oauth_token_url,
    do: Application.get_env(:magpie, :oauth_token_url, @default_oauth_token_url)

  @doc """
  Send an RPC request to a Dropbox endpoint, JSON-encoding `body` when given.
  """
  @spec post(struct(), binary(), term()) :: response
  def post(client, url, body \\ "") do
    client
    |> new_req()
    |> post_request(url, body)
  end

  @doc """
  Same as `post/3` but against an explicit base URL (used by content endpoints
  that speak JSON, such as `/files/get_thumbnail_batch`).
  """
  @spec post_url(struct(), binary(), binary(), term()) :: response
  def post_url(client, base_url, url, body \\ "") do
    client
    |> new_req(base_url: base_url)
    |> post_request(url, body)
  end

  @spec process_response(Req.Response.t()) :: response
  def process_response(%Req.Response{} = response) do
    case magpie_error(response) do
      nil -> do_process_response(response)
      error -> {:error, error}
    end
  end

  defp do_process_response(%Req.Response{status: 200, body: body}), do: {:ok, body}

  defp do_process_response(%Req.Response{} = response),
    do: {:error, response_error(response)}

  @spec download_response(Req.Response.t()) :: response_download
  def download_response(%Req.Response{} = response) do
    case magpie_error(response) do
      nil -> do_download_response(response)
      error -> {:error, error}
    end
  end

  defp do_download_response(%Req.Response{status: 200, body: body, headers: headers}),
    do: {:ok, %{body: body, headers: headers}}

  defp do_download_response(%Req.Response{} = response),
    do: {:error, response_error(response)}

  defp response_error(response) do
    error = Magpie.Error.new(response.status, response.body, response.headers)

    struct(
      error,
      Map.take(Map.get(response.private, :magpie_diagnostics, %{}), [:endpoint, :attempts])
    )
  end

  # Errors produced by the auth steps (a token provider that could not hand
  # out a token) ride back on the response, already normalized.
  defp magpie_error(%Req.Response{private: private}),
    do: Map.get(private, Magpie.Auth.Steps.error_key())

  def post_request(req, url, body \\ "", headers \\ [])

  def post_request(req, url, "", headers) do
    req
    |> request!(url, headers: headers)
    |> process_response()
  end

  def post_request(req, url, body, headers) do
    req
    |> request!(url, headers: headers, json: body)
    |> process_response()
  end

  @doc """
  Upload the file at local path `file` as the raw request body.
  The file is streamed, so large files are not loaded into memory at once.
  """
  def upload_request(client, base_url, url, file, headers) do
    client
    |> new_req(base_url: base_url, headers: headers)
    |> request!(url, body: Magpie.Utils.file_stream(file, 64_000))
    |> process_response()
  end

  @doc """
  Upload `data` (iodata or enumerable) as the raw request body.
  Used by content endpoints that take bytes directly instead of a local file.
  """
  def upload_data_request(client, base_url, url, data, headers) do
    client
    |> new_req(base_url: base_url, headers: headers)
    |> request!(url, body: data)
    |> process_response()
  end

  def download_request(client, base_url, url, data, headers) do
    client
    |> new_req(base_url: base_url, headers: headers)
    |> request!(url, body: data)
    |> download_response()
  end

  @doc """
  Download a content endpoint directly to `destination` without accumulating
  the response body in memory.

  The response is first written to a temporary sibling file and only moved to
  `destination` after Dropbox returns a successful response. Existing files
  are therefore left untouched when Dropbox returns an API error.
  """
  @spec download_file_request(struct(), binary(), binary(), term(), map(), Path.t()) ::
          {:ok, %{path: Path.t(), headers: list() | map()}}
          | {:error, Magpie.Error.t() | File.posix()}
  def download_file_request(client, base_url, url, data, headers, destination) do
    download_file_request(client, base_url, url, data, headers, destination, [])
  end

  def download_file_request(client, base_url, url, data, headers, destination, opts) do
    do_download_file_request(
      client,
      base_url,
      url,
      data,
      headers,
      destination,
      temporary_download_path(destination),
      opts
    )
  end

  defp do_download_file_request(
         client,
         base_url,
         url,
         data,
         headers,
         destination,
         temporary,
         opts
       ) do
    try do
      result =
        client
        |> new_req(base_url: base_url, headers: headers)
        # Retrying a response already being streamed to a collectable can
        # duplicate bytes in the temporary file. The higher-level call still
        # returns transport failures as values and never corrupts destination.
        |> request!(
          url,
          [
            body: data,
            into:
              Magpie.Progress.wrap(
                File.stream!(temporary),
                Keyword.get(opts, :progress),
                Keyword.get(opts, :size),
                %{direction: :download, path: Keyword.get(opts, :transfer_path)}
              )
          ],
          retry: false
        )
        |> download_response()

      case result do
        {:ok, %{headers: response_headers}} ->
          case File.rename(temporary, destination) do
            :ok -> {:ok, %{path: destination, headers: response_headers}}
            {:error, reason} -> {:error, reason}
          end

        {:error, _} = error ->
          error
      end
    rescue
      error in File.Error -> {:error, error.reason}
    after
      _ = File.rm(temporary)
    end
  end

  defp temporary_download_path(destination) do
    suffix = System.unique_integer([:positive, :monotonic])
    destination <> ".magpie-#{suffix}.part"
  end

  def new_req(client, opts \\ []) do
    default_url = Keyword.get(opts, :base_url, base_url())
    url_key = if default_url == upload_url(), do: :upload_url, else: :base_url
    config = Map.get(client, :config, [])

    req_options =
      Keyword.merge(
        Application.get_env(:magpie, :req_options, []),
        Keyword.get(config, :req_options, [])
      )

    base =
      cond do
        Keyword.has_key?(opts, :base_url) and default_url not in [base_url(), upload_url()] ->
          default_url

        Keyword.has_key?(config, url_key) ->
          Keyword.fetch!(config, url_key)

        true ->
          Keyword.get(req_options, :base_url, default_url)
      end

    timeout = Magpie.Client.option(client, :timeout, :infinity)
    retry = Magpie.Client.option(client, :retry, [])
    Magpie.Options.config!(timeout: timeout, retry: retry)

    Req.new(Keyword.put(req_options, :base_url, base))
    |> Req.merge(Keyword.delete(opts, :base_url))
    |> Req.Request.put_private(:magpie_retry, retry)
    |> Req.Request.put_private(:magpie_timeout, timeout)
    |> Req.Request.put_private(:magpie_deadline, Map.get(client, :deadline))
    |> Req.Request.put_private(:magpie_account_id, Keyword.get(config, :account_id))
    |> Magpie.Auth.Steps.attach(Magpie.Client.token_provider(client))
    |> Req.Request.prepend_request_steps(magpie_check_budget: &Magpie.Budget.check!/1)
    |> Req.Request.append_request_steps(magpie_budget: &Magpie.Budget.prepare/1)
  end

  defp request!(req, url, opts, overrides \\ []) do
    endpoint = normalize_endpoint(url)

    metadata = %{
      method: :post,
      endpoint: endpoint,
      operation: endpoint |> String.trim_leading("/") |> String.replace("/", "."),
      account_id: Req.Request.get_private(req, :magpie_account_id)
    }

    deadline =
      Req.Request.get_private(req, :magpie_deadline) ||
        Magpie.Budget.deadline(Req.Request.get_private(req, :magpie_timeout, :infinity))

    req =
      req
      |> Req.Request.put_private(:magpie_telemetry, metadata)
      |> Req.Request.put_private(:magpie_deadline, deadline)

    request_opts =
      url
      |> retry_options(Req.Request.get_private(req, :magpie_retry, []))
      |> Keyword.merge(opts)
      |> Keyword.merge(overrides)
      |> Keyword.put(:retry_delay, nil)
      |> Keyword.put(:url, url)

    Magpie.Telemetry.span(metadata, fn ->
      {request, response} = Req.run(req, Keyword.put(request_opts, :method, :post))
      Magpie.Budget.check!(request)

      if is_exception(response), do: raise(response)

      diagnostics = %{
        endpoint: endpoint,
        attempts: Req.Request.get_private(request, :magpie_attempts, 0)
      }

      Req.Response.put_private(response, :magpie_diagnostics, diagnostics)
    end)
  end

  defp retry_options(url, retry_config) do
    cond do
      retry_config == false ->
        [retry: false]

      MapSet.member?(@retryable_reads, normalize_endpoint(url)) ->
        retry_config = if is_list(retry_config), do: retry_config, else: []

        [
          retry: &Magpie.Telemetry.retry/2,
          max_retries: Keyword.get(retry_config, :max_retries, 3),
          retry_log_level: Keyword.get(retry_config, :log_level, :warning)
        ]

      true ->
        [retry: false]
    end
  end

  defp normalize_endpoint(url), do: "/" <> String.trim_leading(url, "/")
end
