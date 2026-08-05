defmodule Magpie.Auth.Token do
  @moduledoc """
  An OAuth 2 token set returned by Dropbox's `/oauth2/token` endpoint.

    * `access_token` — the short-lived token used to authenticate API calls
    * `refresh_token` — the long-lived token used to mint new access tokens.
      Only returned by the code exchange; refresh responses leave it `nil`,
      since Dropbox does not rotate refresh tokens (keep the original one)
    * `expires_at` — absolute expiry, computed from Dropbox's `expires_in`
    * `scope` — space-separated scopes granted to the token, when present
    * `account_id` / `uid` — the Dropbox account the token belongs to
      (code exchange only)

  """

  defstruct [:access_token, :refresh_token, :expires_at, :scope, :account_id, :uid]

  @type t :: %__MODULE__{
          access_token: String.t() | nil,
          refresh_token: String.t() | nil,
          expires_at: DateTime.t() | nil,
          scope: String.t() | nil,
          account_id: String.t() | nil,
          uid: String.t() | nil
        }

  @doc """
  Builds a token from a decoded `/oauth2/token` response body.

  `expires_in` (seconds from now) is turned into an absolute `expires_at`.

      iex> body = %{"access_token" => "sl.ABC", "expires_in" => 14_400, "token_type" => "bearer"}
      iex> token = Magpie.Auth.Token.from_response(body)
      iex> token.access_token
      "sl.ABC"
      iex> DateTime.diff(token.expires_at, DateTime.utc_now()) > 14_000
      true

  """
  @spec from_response(map()) :: t()
  def from_response(body) when is_map(body) do
    %__MODULE__{
      access_token: body["access_token"],
      refresh_token: body["refresh_token"],
      expires_at: expires_at(body["expires_in"]),
      scope: body["scope"],
      account_id: body["account_id"],
      uid: body["uid"]
    }
  end

  @doc """
  Returns `true` when the token is usable for at least `margin` more seconds.

  A token without an `expires_at` is never considered fresh — its expiry is
  unknown, so it is safer to refresh it.

      iex> token = %Magpie.Auth.Token{access_token: "sl.ABC", expires_at: DateTime.add(DateTime.utc_now(), 3600)}
      iex> Magpie.Auth.Token.fresh?(token, 300)
      true
      iex> Magpie.Auth.Token.fresh?(%Magpie.Auth.Token{}, 300)
      false

  """
  @spec fresh?(t(), non_neg_integer()) :: boolean()
  def fresh?(%__MODULE__{access_token: nil}, _margin), do: false
  def fresh?(%__MODULE__{expires_at: nil}, _margin), do: false

  def fresh?(%__MODULE__{expires_at: expires_at}, margin),
    do: DateTime.diff(expires_at, DateTime.utc_now(), :second) > margin

  defp expires_at(nil), do: nil

  defp expires_at(expires_in) when is_integer(expires_in) do
    DateTime.utc_now()
    |> DateTime.add(expires_in, :second)
    |> DateTime.truncate(:second)
  end
end
