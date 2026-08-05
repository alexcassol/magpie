defmodule Magpie.Error do
  @moduledoc """
  Normalized Dropbox API error.

  Every Magpie function returns `{:error, %Magpie.Error{}}` when Dropbox
  answers with a non-success status:

    * `status` — the HTTP status code (e.g. `409`)
    * `summary` — Dropbox's `error_summary` string when present
      (e.g. `"path/not_found/.."`), `nil` otherwise
    * `body` — the full decoded error payload

  It is also an exception, so it can be raised — `Magpie.Pager` streams do
  exactly that, since a `Stream` cannot return an error tuple
  mid-enumeration:

      case Magpie.Files.create_folder(client, "/Existing") do
        {:ok, %{"metadata" => metadata}} -> metadata
        {:error, %Magpie.Error{status: 409, summary: "path/conflict" <> _}} -> :already_exists
        {:error, error} -> raise error
      end

  """

  defexception [:status, :body, :summary]

  @type t :: %__MODULE__{
          status: pos_integer(),
          body: term(),
          summary: String.t() | nil
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
  def new(status, %{"error_summary" => summary} = body),
    do: %__MODULE__{status: status, body: body, summary: summary}

  def new(status, %{"error" => summary} = body) when is_binary(summary),
    do: %__MODULE__{status: status, body: body, summary: summary}

  def new(status, body), do: %__MODULE__{status: status, body: body, summary: nil}

  @impl true
  def message(%__MODULE__{status: status, summary: nil, body: body}),
    do: "Dropbox returned status #{status}: #{inspect(body)}"

  def message(%__MODULE__{status: status, summary: summary}),
    do: "Dropbox returned status #{status}: #{summary}"
end
