defmodule Magpie.Auth.Steps do
  @moduledoc false
  # Req steps that plug a `Magpie.Auth.TokenProvider` into the request
  # pipeline: one request step that stamps the bearer token, and one
  # response step that refreshes it and retries once when Dropbox answers
  # `expired_access_token`.

  alias Magpie.Error

  @provider_key :magpie_token_provider
  @retried_key :magpie_token_refreshed
  @error_key :magpie_error

  @expired "expired_access_token"

  @doc false
  def error_key, do: @error_key

  @doc false
  def attach(%Req.Request{} = request, {module, _arg} = provider) when is_atom(module) do
    request
    |> Req.Request.put_private(@provider_key, provider)
    |> Req.Request.append_request_steps(magpie_put_token: &put_token/1)
    |> Req.Request.append_response_steps(magpie_refresh_token: &maybe_refresh/1)
  end

  # Request step: ask the provider for a token and stamp it on the request.
  # A provider error short-circuits the pipeline before any network call.
  defp put_token(%Req.Request{} = request) do
    {module, arg} = Req.Request.get_private(request, @provider_key)

    case module.fetch_token(arg) do
      {:ok, nil} -> request
      {:ok, token} when is_binary(token) -> put_bearer(request, token)
      {:error, %Error{} = error} -> Req.Request.halt(request, error_response(error))
    end
  end

  # Response step: on `expired_access_token`, refresh once and replay.
  defp maybe_refresh({request, %Req.Response{} = response}) do
    if retry?(request, response) do
      {module, arg} = Req.Request.get_private(request, @provider_key)

      case module.refresh_token(arg) do
        {:ok, _token} -> replay(request)
        {:error, %Error{} = error} -> Req.Request.halt(request, error_response(error))
      end
    else
      {request, response}
    end
  end

  defp replay(request) do
    request = Req.Request.put_private(request, @retried_key, true)
    {request, response_or_exception} = Req.Request.run_request(%{request | halted: false})

    Req.Request.halt(request, response_or_exception)
  end

  defp retry?(request, response) do
    expired?(response) and
      not Req.Request.get_private(request, @retried_key, false) and
      replayable?(request.body)
  end

  defp expired?(%Req.Response{status: 401, body: body}), do: expired_body?(body)
  defp expired?(%Req.Response{}), do: false

  defp expired_body?(%{"error_summary" => summary}) when is_binary(summary),
    do: String.starts_with?(summary, @expired)

  # Content endpoints answer with the JSON error as plain text, so it
  # reaches this step undecoded.
  defp expired_body?(body) when is_binary(body), do: String.contains?(body, @expired)
  defp expired_body?(_body), do: false

  # Streamed bodies (an upload session reading from `File.stream!/2`) cannot
  # be replayed safely, so those requests are never retried — the proactive
  # refresh margin is what keeps uploads from hitting an expired token.
  defp replayable?(body) when is_nil(body) or is_binary(body) or is_list(body), do: true
  defp replayable?(_body), do: false

  defp put_bearer(request, token),
    do: Req.Request.put_header(request, "authorization", "Bearer " <> token)

  # Errors raised before/instead of a Dropbox response travel back as a
  # response carrying the original struct, so `Magpie.process_response/1`
  # returns it untouched.
  defp error_response(%Error{} = error) do
    [status: error.status || 401, body: error.body]
    |> Req.Response.new()
    |> Req.Response.put_private(@error_key, error)
  end
end
