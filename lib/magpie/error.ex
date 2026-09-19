defmodule Magpie.Error do
  @moduledoc """
  Normalized Dropbox API error.

  Every Magpie function returns `{:error, %Magpie.Error{}}` when Dropbox
  answers with a non-success status:

    * `status` — the HTTP status code (e.g. `409`)
    * `summary` — Dropbox's `error_summary` string when present
      (e.g. `"path/not_found/.."`), `nil` otherwise
    * `body` — the full decoded error payload
    * `request_id` — Dropbox's request identifier, useful when contacting support
    * `endpoint` — normalized API route when the error came through the HTTP layer
    * `attempts` — number of HTTP attempts, including authentication replay
    * `retry_after` — server-requested delay in milliseconds, or `nil`

  It is also an exception, so it can be raised — `Magpie.Pager` streams do
  exactly that, since a `Stream` cannot return an error tuple
  mid-enumeration:

      case Magpie.Files.create_folder(client, "/Existing") do
        {:ok, %Magpie.FolderMetadata{} = folder} -> folder
        {:error, %Magpie.Error{status: 409, summary: "path/conflict" <> _}} -> :already_exists
        {:error, error} -> raise error
      end

  """

  defexception [:status, :body, :summary, :request_id, :endpoint, :retry_after, attempts: 1]

  @type t :: %__MODULE__{
          status: pos_integer(),
          body: term(),
          summary: String.t() | nil,
          request_id: String.t() | nil,
          endpoint: String.t() | nil,
          retry_after: non_neg_integer() | nil,
          attempts: non_neg_integer()
        }

  @doc """
  Builds a `Magpie.Error` from an HTTP status and a decoded response body,
  extracting Dropbox's `error_summary` when present.

  OAuth 2 errors (`Magpie.Auth`) have no `error_summary` — their `error`
  field is a plain string such as `"invalid_grant"`, which is used as the
  summary instead.

      iex> Magpie.Error.new(409, %{"error_summary" => "path/conflict/folder/.."}).summary
      "path/conflict/folder/.."

      iex> Magpie.Error.new(400, %{"error" => "invalid_grant"}).summary
      "invalid_grant"

  """
  def new(status, body, headers \\ [])

  def new(status, %{"error_summary" => summary} = body, headers),
    do: %__MODULE__{
      status: status,
      body: body,
      summary: summary,
      request_id: request_id(headers),
      retry_after: retry_after(headers)
    }

  def new(status, %{"error" => summary} = body, headers) when is_binary(summary),
    do: %__MODULE__{
      status: status,
      body: body,
      summary: summary,
      request_id: request_id(headers),
      retry_after: retry_after(headers)
    }

  def new(status, body, headers),
    do: %__MODULE__{
      status: status,
      body: body,
      summary: nil,
      request_id: request_id(headers),
      retry_after: retry_after(headers)
    }

  @doc """
  Returns a safe diagnostic map without response bodies or credentials.

  `:retry_after` is milliseconds, `:attempts` counts HTTP attempts (including
  an authentication replay), and `:endpoint` identifies the API route.
  """
  @spec diagnostics(t()) :: map()
  def diagnostics(%__MODULE__{} = error) do
    error
    |> Map.from_struct()
    |> Map.take([:status, :request_id, :endpoint, :retry_after, :attempts])
  end

  @doc "Returns the required scope reported by Dropbox, or nil."
  @spec required_scope(t()) :: String.t() | nil
  def required_scope(%__MODULE__{
        body: %{"error" => %{".tag" => "missing_scope", "required_scope" => scope}}
      })
      when is_binary(scope), do: scope

  def required_scope(_), do: nil

  @doc false
  def retry_after(headers) do
    case header(headers, "retry-after") do
      nil ->
        nil

      value when is_binary(value) ->
        case Integer.parse(value) do
          {seconds, ""} when seconds >= 0 -> seconds * 1000
          _ -> retry_date(value)
        end

      _ ->
        nil
    end
  end

  defp retry_date(value) do
    Req.Response.new(headers: [{"retry-after", value}])
    |> Req.Response.get_retry_after()
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  @doc "Returns whether an error represents a content integrity mismatch."
  @spec integrity?(term()) :: boolean()
  def integrity?(%Magpie.IntegrityError{}), do: true
  def integrity?(_), do: false

  @doc "Returns whether Dropbox reported that the requested resource was not found."
  @spec not_found?(term()) :: boolean()
  def not_found?(%__MODULE__{status: 409} = error), do: tagged?(error, "not_found")
  def not_found?(_), do: false

  @doc "Returns whether Dropbox reported a path, file, or folder conflict."
  @spec conflict?(term()) :: boolean()
  def conflict?(%__MODULE__{status: 409} = error), do: tagged?(error, "conflict")
  def conflict?(_), do: false

  @doc "Returns whether Dropbox rate-limited the request."
  @spec rate_limited?(term()) :: boolean()
  def rate_limited?(%__MODULE__{status: 429}), do: true
  def rate_limited?(_), do: false

  @doc "Returns whether an error represents failed authentication or authorization."
  @spec auth?(term()) :: boolean()
  def auth?(%__MODULE__{status: status}) when status in [401, 403], do: true

  def auth?(%__MODULE__{} = error),
    do:
      Enum.any?(
        ["invalid_access_token", "expired_access_token", "invalid_grant"],
        &tagged?(error, &1)
      )

  def auth?(_), do: false

  @doc "Returns whether retrying the operation may succeed without changing it."
  @spec retryable?(term()) :: boolean()
  def retryable?(%__MODULE__{status: status}) when status == 429 or status in 500..599, do: true
  def retryable?(_), do: false

  defp tagged?(%__MODULE__{body: body, summary: summary}, tag) do
    contains_tag?(body, tag) or summary_has_segment?(summary, tag)
  end

  defp contains_tag?(%{".tag" => tag}, tag), do: true
  defp contains_tag?(%{tag: tag}, tag), do: true

  defp contains_tag?(map, tag) when is_map(map),
    do: Enum.any?(map, fn {_key, value} -> contains_tag?(value, tag) end)

  defp contains_tag?(list, tag) when is_list(list),
    do: Enum.any?(list, &contains_tag?(&1, tag))

  defp contains_tag?(_value, _tag), do: false

  defp summary_has_segment?(summary, tag) when is_binary(summary),
    do: tag in String.split(summary, "/", trim: true)

  defp summary_has_segment?(_summary, _tag), do: false

  defp request_id(headers), do: header(headers, "x-dropbox-request-id")

  defp header(headers, name) when is_map(headers) or is_list(headers) do
    Enum.find_value(headers, fn
      {key, value} when is_binary(key) ->
        if String.downcase(key) == name, do: value |> List.wrap() |> List.first()

      _ ->
        nil
    end)
  end

  defp header(_, _), do: nil

  @impl true
  def message(%__MODULE__{status: status, summary: nil, body: body}),
    do: "Dropbox returned status #{status}: #{inspect(body)}"

  def message(%__MODULE__{status: status, summary: summary}),
    do: "Dropbox returned status #{status}: #{summary}"
end
