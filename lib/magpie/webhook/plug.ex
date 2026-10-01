defmodule Magpie.Webhook.Plug do
  @moduledoc """
  Optional Plug-compatible Dropbox webhook endpoint. The consumer supplies Plug;
  Magpie keeps it test-only, just as Phoenix integrations have no runtime dependency.

  Install **before** `Plug.Parsers` or anything that reads request bodies:

      plug Magpie.Webhook.Plug,
        path: "/webhooks/dropbox",
        app_secret: &MyApp.DropboxConfig.app_secret/0,
        notify: &MyApp.DropboxJobs.enqueue/1

  Options: `:path` (required exact request path), `:app_secret` (non-empty binary
  or zero-arity function), `:notify` (function receiving the entire account list,
  returning `:ok` after durable enqueue, or `{:error, reason}`), and
  `:max_body_bytes` (positive integer, default 1 MiB). Callbacks run synchronously:
  enqueue only, never scan Dropbox in the callback. With compile-time Plug
  initialization use remote captures (`&Module.function/arity`), since anonymous
  functions cannot be escaped into compiled pipeline options. A secret function
  must return a non-empty binary; invalid resolved secrets raise `ArgumentError`.
  Unexpected callback returns also raise `ArgumentError`, without exposing values.
  Exceptions propagate so the application can observe configuration/programming
  failures; returned enqueue failures send 503 for retry.

  Matching GETs echo the challenge with safe headers. POSTs read the untouched
  body in chunks, reject missing/duplicate/invalid signatures with 403, malformed
  signed JSON with 400, oversized bodies with 413 and read failures with 400.
  Successful enqueue returns 200. Empty account lists and signed JSON objects
  without `list_folder` return 200 without calling `:notify`. Ignored formats set
  `conn.private[:magpie_webhook_notification]` to `:ignored` for observation.
  Other methods return 405. Matching requests
  are halted; other paths pass through. The raw body is stored in
  `conn.private[:magpie_webhook_raw_body]` for successful reads, without reencoding.
  It is never logged or retained by Magpie after the request.
  """

  @doc "Validates endpoint options."
  @spec init(keyword()) :: keyword()
  def init(opts) do
    Magpie.Options.keyword!(opts)

    unless Enum.all?(Keyword.keys(opts), &(&1 in [:path, :app_secret, :notify, :max_body_bytes])),
      do: raise(ArgumentError, "unsupported webhook option")

    unless is_binary(opts[:path]) and String.starts_with?(opts[:path], "/"),
      do: raise(ArgumentError, "expected a webhook :path")

    unless (is_binary(opts[:app_secret]) and byte_size(opts[:app_secret]) > 0) or
             is_function(opts[:app_secret], 0),
           do: raise(ArgumentError, "expected an :app_secret or zero-arity function")

    unless is_function(opts[:notify], 1),
      do: raise(ArgumentError, "expected a one-arity :notify function")

    limit = Keyword.get(opts, :max_body_bytes, 1_048_576)

    unless is_integer(limit) and limit > 0,
      do: raise(ArgumentError, "expected positive :max_body_bytes")

    Keyword.put(opts, :max_body_bytes, limit)
  end

  @doc "Handles matching webhook requests before body parsers."
  @spec call(map(), keyword()) :: map()
  def call(conn, opts) do
    if conn.request_path == opts[:path], do: handle(conn, opts), else: conn
  end

  defp handle(%{method: "GET"} = conn, _opts) do
    conn = invoke(:fetch_query_params, [conn])

    case Magpie.Webhook.challenge(conn.query_params["challenge"]) do
      {:ok, response} ->
        conn =
          Enum.reduce(response.headers, conn, fn {key, value}, acc ->
            invoke(:put_resp_header, [acc, key, value])
          end)

        respond(conn, 200, response.body)

      {:error, _} ->
        respond(conn, 400, "")
    end
  end

  defp handle(%{method: "POST"} = conn, opts) do
    case read_raw(conn, opts[:max_body_bytes], [], 0) do
      {:ok, body, conn} ->
        conn = invoke(:put_private, [conn, :magpie_webhook_raw_body, body])

        signature =
          case invoke(:get_req_header, [conn, "x-dropbox-signature"]) do
            [value] -> value
            _ -> nil
          end

        secret = opts[:app_secret]
        secret = if is_function(secret, 0), do: secret.(), else: secret

        unless is_binary(secret) and byte_size(secret) > 0,
          do: raise(ArgumentError, "webhook :app_secret must resolve to a non-empty binary")

        case Magpie.Webhook.notification(body, signature, secret) do
          {:ok, :ignored} ->
            conn = invoke(:put_private, [conn, :magpie_webhook_notification, :ignored])
            respond(conn, 200, "")

          {:ok, []} ->
            respond(conn, 200, "")

          {:ok, accounts} ->
            case opts[:notify].(accounts) do
              :ok -> respond(conn, 200, "")
              {:error, _} -> respond(conn, 503, "")
              _ -> raise ArgumentError, "webhook :notify must return :ok or {:error, reason}"
            end

          {:error, :invalid_signature} ->
            respond(conn, 403, "")

          {:error, :invalid_payload} ->
            respond(conn, 400, "")
        end

      {:error, :too_large, conn} ->
        respond(conn, 413, "")

      {:error, :read_failed, conn} ->
        respond(conn, 400, "")
    end
  end

  defp handle(conn, _opts), do: respond(conn, 405, "")

  defp read_raw(conn, limit, chunks, size) do
    case invoke(:read_body, [conn, [length: min(limit + 1, 64_000)]]) do
      {status, chunk, conn} when status in [:ok, :more] ->
        size = size + byte_size(chunk)

        cond do
          size > limit -> {:error, :too_large, conn}
          status == :more -> read_raw(conn, limit, [chunk | chunks], size)
          true -> {:ok, IO.iodata_to_binary(Enum.reverse([chunk | chunks])), conn}
        end

      {:error, _} ->
        {:error, :read_failed, conn}
    end
  end

  defp respond(conn, status, body),
    do: conn |> then(&invoke(:send_resp, [&1, status, body])) |> then(&invoke(:halt, [&1]))

  # Resolve at runtime so consumers without Plug can compile Magpie without warnings.
  defp invoke(fun, args), do: apply(Plug.Conn, fun, args)
end
