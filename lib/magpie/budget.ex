defmodule Magpie.Budget do
  @moduledoc false

  def deadline(:infinity), do: nil
  def deadline(timeout), do: System.monotonic_time(:millisecond) + timeout

  def remaining(nil), do: :infinity
  def remaining(deadline), do: max(0, deadline - System.monotonic_time(:millisecond))

  def check!(request) do
    if remaining(Req.Request.get_private(request, :magpie_deadline)) == 0 do
      metadata = Req.Request.get_private(request, :magpie_telemetry, %{})

      raise Magpie.TimeoutError,
        endpoint: metadata[:endpoint],
        timeout: Req.Request.get_private(request, :magpie_timeout)
    end

    request
  end

  def prepare(request) do
    check!(request)
    left = remaining(Req.Request.get_private(request, :magpie_deadline))

    request =
      if left == :infinity do
        request
      else
        Enum.reduce([:receive_timeout, :request_timeout, :pool_timeout], request, fn key, req ->
          defaults = %{receive_timeout: 15_000, request_timeout: :infinity, pool_timeout: 5_000}
          finch = Req.Request.get_option(req, :finch, [])
          value = min(Req.Request.get_option(req, key, defaults[key]), left)
          req = Req.Request.put_option(req, key, value)

          if is_list(finch) and Keyword.has_key?(finch, key) do
            Req.Request.put_option(req, :finch, Keyword.put(finch, key, min(finch[key], left)))
          else
            req
          end
        end)
      end

    count = Req.Request.get_private(request, :magpie_attempts, 0)
    Req.Request.put_private(request, :magpie_attempts, count + 1)
  end
end
