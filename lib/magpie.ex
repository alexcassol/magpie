defmodule Magpie do
  @moduledoc """
  Core HTTP layer for the Dropbox API v2.

  Builds authenticated `Req` requests and normalizes responses. RPC-style
  endpoints go through `post/3`, while content endpoints (file bytes) go
  through `upload_request/5` and `download_request/5`.

  The Dropbox endpoints can be overridden (rarely needed) via:

      config :magpie,
        base_url: "https://api.dropboxapi.com/2",
        upload_url: "https://content.dropboxapi.com/2/"

  Extra options merged into every request (e.g. `plug: {Req.Test, Magpie}`
  for testing) can be set with `config :magpie, req_options: [...]`.
  """

  @default_base_url "https://api.dropboxapi.com/2"
  @default_upload_url "https://content.dropboxapi.com/2/"

  @type response :: {:ok, term()} | {:error, Magpie.Error.t()}

  @type response_download ::
          {:ok, %{body: binary(), headers: list() | map()}} | {:error, Magpie.Error.t()}

  @doc "Base URL for RPC endpoints."
  def base_url, do: Application.get_env(:magpie, :base_url, @default_base_url)

  @doc "Base URL for content (upload/download) endpoints."
  def upload_url, do: Application.get_env(:magpie, :upload_url, @default_upload_url)

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
  def process_response(%Req.Response{status: 200, body: body}), do: {:ok, body}

  def process_response(%Req.Response{status: status, body: body}),
    do: {:error, Magpie.Error.new(status, body)}

  @spec download_response(Req.Response.t()) :: response_download
  def download_response(%Req.Response{status: 200, body: body, headers: headers}),
    do: {:ok, %{body: body, headers: headers}}

  def download_response(%Req.Response{status: status, body: body}),
    do: {:error, Magpie.Error.new(status, body)}

  def post_request(req, url, body \\ "", headers \\ [])

  def post_request(req, url, "", headers) do
    req
    |> Req.post!(url: url, headers: headers)
    |> process_response()
  end

  def post_request(req, url, body, headers) do
    req
    |> Req.post!(url: url, headers: headers, json: body)
    |> process_response()
  end

  @doc """
  Upload the file at local path `file` as the raw request body.
  The file is streamed, so large files are not loaded into memory at once.
  """
  def upload_request(client, base_url, url, file, headers) do
    client
    |> new_req(base_url: base_url, headers: headers)
    |> Req.post!(url: url, body: File.stream!(file, 64_000))
    |> process_response()
  end

  @doc """
  Upload `data` (iodata or enumerable) as the raw request body.
  Used by content endpoints that take bytes directly instead of a local file.
  """
  def upload_data_request(client, base_url, url, data, headers) do
    client
    |> new_req(base_url: base_url, headers: headers)
    |> Req.post!(url: url, body: data)
    |> process_response()
  end

  def download_request(client, base_url, url, data, headers) do
    client
    |> new_req(base_url: base_url, headers: headers)
    |> Req.post!(url: url, body: data)
    |> download_response()
  end

  def new_req(client, opts \\ []) do
    base_url = Keyword.get(opts, :base_url, base_url())
    headers = Keyword.get(opts, :headers, [])

    [base_url: base_url, headers: headers, auth: {:bearer, client.access_token}]
    |> Keyword.merge(Application.get_env(:magpie, :req_options, []))
    |> Req.new()
  end
end
