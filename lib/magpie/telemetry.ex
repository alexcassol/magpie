defmodule Magpie.Telemetry do
  @moduledoc """
  Telemetry events emitted by Magpie's HTTP layer.

  Every logical Dropbox request emits:

    * `[:magpie, :request, :start]`
    * `[:magpie, :request, :stop]`
    * `[:magpie, :request, :exception]` when the request raises
    * `[:magpie, :request, :retry]` before an automatic retry
    * `[:magpie, :transfer, :progress]` while bytes are uploaded/downloaded

  Request metadata includes `:method`, `:endpoint` and `:operation`. Stop
  metadata also includes `:status` and Dropbox's `:request_id` when present.
  Measurements use native monotonic time and can be converted with
  `System.convert_time_unit/3`. Transfer measurements contain `:transferred`
  and `:total`, while metadata identifies the `:direction` and Dropbox `:path`.
  """

  @doc false
  def span(metadata, fun) when is_function(fun, 0) do
    start = System.monotonic_time()

    :telemetry.execute(
      [:magpie, :request, :start],
      %{system_time: System.system_time()},
      metadata
    )

    try do
      response = fun.()
      duration = System.monotonic_time() - start

      :telemetry.execute(
        [:magpie, :request, :stop],
        %{duration: duration},
        Map.merge(metadata, response_metadata(response))
      )

      response
    catch
      kind, reason ->
        duration = System.monotonic_time() - start
        stacktrace = __STACKTRACE__

        :telemetry.execute(
          [:magpie, :request, :exception],
          %{duration: duration},
          Map.merge(metadata, %{kind: kind, reason: reason, stacktrace: stacktrace})
        )

        :erlang.raise(kind, reason, stacktrace)
    end
  end

  @doc false
  def retry(request, response_or_exception) do
    retry_count = Req.Request.get_private(request, :req_retry_count, 0)
    max_retries = Req.Request.get_option(request, :max_retries, 3)

    if transient?(response_or_exception) and retry_count < max_retries do
      metadata = Req.Request.get_private(request, :magpie_telemetry, %{})

      :telemetry.execute(
        [:magpie, :request, :retry],
        %{retry_count: retry_count + 1},
        Map.merge(metadata, failure_metadata(response_or_exception))
      )

      true
    else
      false
    end
  end

  defp transient?(%Req.Response{status: status}),
    do: status in [408, 429, 500, 502, 503, 504]

  defp transient?(%Req.TransportError{reason: reason}),
    do: reason in [:timeout, :econnrefused, :closed]

  defp transient?(%Req.HTTPError{protocol: :http2, reason: reason}),
    do: reason in [:unprocessed, :pool_not_available]

  defp transient?(_), do: false

  defp response_metadata(%Req.Response{} = response) do
    %{status: response.status, request_id: request_id(response)}
  end

  defp response_metadata(_), do: %{}

  defp failure_metadata(%Req.Response{} = response),
    do: %{status: response.status, request_id: request_id(response)}

  defp failure_metadata(exception), do: %{exception: exception}

  defp request_id(response) do
    response
    |> Req.Response.get_header("x-dropbox-request-id")
    |> List.first()
  end
end
