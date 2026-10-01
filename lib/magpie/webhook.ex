defmodule Magpie.Webhook do
  @moduledoc """
  Framework-independent Dropbox webhook verification and notification decoding.

  Notifications contain account IDs, not file changes. Enqueue those IDs and
  use each account's client and saved cursor with `Magpie.Storage.continue_list/3`.
  Respond promptly; serialize workers per account and apply pages idempotently.
  This module provides no persistence, queue, deduplication or replay protection.
  See the [incremental and webhook guide](incremental.md).
  """

  @doc """
  Returns `{:ok, %{status: 200, headers: headers, body: challenge}}` for a
  non-empty binary challenge, otherwise `{:error, :invalid_challenge}`.
  Headers are `content-type: text/plain` and `x-content-type-options: nosniff`.
  Echo the decoded query value as plain text without HTML interpolation.
  """
  @spec challenge(term()) :: {:ok, map()} | {:error, :invalid_challenge}
  def challenge(challenge) when is_binary(challenge) and byte_size(challenge) > 0 do
    {:ok,
     %{
       status: 200,
       body: challenge,
       headers: [{"content-type", "text/plain"}, {"x-content-type-options", "nosniff"}]
     }}
  end

  def challenge(_), do: {:error, :invalid_challenge}

  @doc """
  Checks the hexadecimal X-Dropbox-Signature using HMAC-SHA256 over original
  binary body bytes and the app secret. Compares equal-sized digests in constant
  time. Returns false for absent, malformed or invalid signatures/arguments.
  Never encode parsed JSON to reconstruct the signed body.
  """
  @spec valid_signature?(binary(), term(), binary()) :: boolean()
  def valid_signature?(body, signature, secret)
      when is_binary(body) and is_binary(signature) and byte_size(signature) == 64 and
             is_binary(secret) and byte_size(secret) > 0 do
    case Base.decode16(signature, case: :mixed) do
      {:ok, digest} -> secure_equal(digest, :crypto.mac(:hmac, :sha256, secret, body))
      :error -> false
    end
  end

  def valid_signature?(_, _, _), do: false

  defp secure_equal(left, right) do
    left
    |> :binary.bin_to_list()
    |> Enum.zip(:binary.bin_to_list(right))
    |> Enum.reduce(0, fn {a, b}, acc -> Bitwise.bor(acc, Bitwise.bxor(a, b)) end)
    |> Kernel.==(0)
  end

  @doc """
  Validates the signature before decoding JSON; returns `{:ok, [account_id]}`,
  `{:ok, :ignored}`, `{:error, :invalid_signature}` or
  `{:error, :invalid_payload}`.

  A signed JSON object without `list_folder` is an unsupported notification:
  return `{:ok, :ignored}` so the endpoint can acknowledge it without enqueueing
  accounts. Consumers may observe this result to detect formats they don't handle.
  This acknowledges receipt, not support for Business/team notifications.

  When `list_folder` is present, `accounts` must be a list of non-empty binary
  IDs. Malformed JSON, non-object JSON and malformed recognized notifications
  return `:invalid_payload`. Empty lists are valid; order and repeated IDs are
  preserved. Extra fields, including legacy `delta`, are ignored.
  """
  @spec notification(binary(), term(), binary()) ::
          {:ok, [binary()] | :ignored} | {:error, :invalid_signature | :invalid_payload}
  def notification(body, signature, secret) do
    if valid_signature?(body, signature, secret) do
      case Jason.decode(body) do
        {:ok, %{"list_folder" => %{"accounts" => accounts}}} when is_list(accounts) ->
          if Enum.all?(accounts, &(is_binary(&1) and byte_size(&1) > 0)),
            do: {:ok, accounts},
            else: {:error, :invalid_payload}

        {:ok, payload} when is_map(payload) ->
          if Map.has_key?(payload, "list_folder"),
            do: {:error, :invalid_payload},
            else: {:ok, :ignored}

        _ ->
          {:error, :invalid_payload}
      end
    else
      {:error, :invalid_signature}
    end
  end
end
