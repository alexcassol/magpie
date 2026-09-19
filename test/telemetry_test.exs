defmodule Magpie.TelemetryTest do
  use ExUnit.Case, async: false

  alias Magpie.Client
  alias Magpie.Error
  alias Magpie.FileMetadata
  alias Magpie.Storage

  @client Client.new("fake-token")
  @events [
    [:magpie, :request, :start],
    [:magpie, :request, :stop],
    [:magpie, :request, :exception],
    [:magpie, :request, :retry],
    [:magpie, :transfer, :progress]
  ]

  setup do
    handler = {__MODULE__, make_ref()}
    owner = self()
    previous_retry = Application.get_env(:magpie, :retry)

    :ok =
      :telemetry.attach_many(
        handler,
        @events,
        &__MODULE__.handle_event/4,
        owner
      )

    on_exit(fn ->
      :telemetry.detach(handler)

      if is_nil(previous_retry) do
        Application.delete_env(:magpie, :retry)
      else
        Application.put_env(:magpie, :retry, previous_retry)
      end
    end)

    :ok
  end

  test "safe Dropbox reads retry transient responses and emit retry telemetry" do
    Application.put_env(:magpie, :retry, max_retries: 1, log_level: false)
    {:ok, attempts} = Agent.start_link(fn -> 0 end)

    Req.Test.stub(Magpie, fn conn ->
      attempt = Agent.get_and_update(attempts, &{&1 + 1, &1 + 1})

      if attempt == 1 do
        conn
        |> Plug.Conn.put_resp_header("retry-after", "0")
        |> Plug.Conn.send_resp(429, Jason.encode!(%{"error_summary" => "too_many_requests/.."}))
      else
        conn
        |> Plug.Conn.put_resp_header("x-dropbox-request-id", "retry-ok")
        |> Req.Test.json(%{".tag" => "file", "name" => "a.txt", "rev" => "1"})
      end
    end)

    assert {:ok, %FileMetadata{name: "a.txt"}} = Storage.stat(@client, "/a.txt")
    assert Agent.get(attempts, & &1) == 2

    assert_receive {:telemetry, [:magpie, :request, :retry], %{retry_count: 1},
                    %{endpoint: "/files/get_metadata", status: 429}}

    assert_receive {:telemetry, [:magpie, :request, :stop], %{duration: duration},
                    %{
                      endpoint: "/files/get_metadata",
                      status: 200,
                      request_id: "retry-ok"
                    }}

    assert is_integer(duration) and duration >= 0
  end

  test "mutating requests are not retried" do
    Application.put_env(:magpie, :retry, max_retries: 3, delay: 0, log_level: false)
    {:ok, attempts} = Agent.start_link(fn -> 0 end)

    Req.Test.stub(Magpie, fn conn ->
      Agent.update(attempts, &(&1 + 1))
      Plug.Conn.send_resp(conn, 503, Jason.encode!(%{"error_summary" => "unavailable/.."}))
    end)

    assert {:error, %Error{status: 503}} = Storage.put(@client, "/a.txt", {:binary, "a"})
    assert Agent.get(attempts, & &1) == 1
    refute_receive {:telemetry, [:magpie, :request, :retry], _, _}
  end

  test "successful transfers emit byte progress" do
    Req.Test.stub(Magpie, fn conn ->
      Req.Test.json(conn, %{".tag" => "file", "name" => "a.txt"})
    end)

    assert {:ok, %FileMetadata{}} = Storage.put(@client, "/a.txt", {:binary, "abc"})

    assert_receive {:telemetry, [:magpie, :transfer, :progress], %{transferred: 3, total: 3},
                    %{direction: :upload, path: "/a.txt"}}
  end

  test "per-client labels and final attempt counts are observable without credentials" do
    Req.Test.stub(Magpie, fn conn ->
      conn |> Plug.Conn.put_status(503) |> Req.Test.json(%{"secret" => "private-body"})
    end)

    client =
      Client.new("private-token",
        account_id: "backup",
        retry: [max_retries: 1, delay: 0, log_level: false]
      )

    assert {:error, %Error{attempts: 2}} = Storage.stat(client, "/a")

    assert_receive {:telemetry, [:magpie, :request, :retry], %{retry_count: 1, delay: 0},
                    %{account_id: "backup"}}

    assert_receive {:telemetry, [:magpie, :request, :stop], _,
                    %{account_id: "backup", attempts: 2} = metadata}

    refute inspect(metadata) =~ "private-token"
    refute inspect(metadata) =~ "private-body"
  end

  test "client endpoint configuration wins over a legacy global Req base URL" do
    previous = Application.fetch_env(:magpie, :req_options)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:magpie, :req_options, value)
        :error -> Application.delete_env(:magpie, :req_options)
      end
    end)

    Application.put_env(:magpie, :req_options,
      plug: {Req.Test, Magpie},
      base_url: "https://global.example/2"
    )

    Req.Test.stub(Magpie, fn conn ->
      Req.Test.json(conn, %{".tag" => "file", "name" => conn.host})
    end)

    assert {:ok, %FileMetadata{name: "global.example"}} = Storage.stat(@client, "/a")
    client = Client.with_options(@client, base_url: "https://client.example/2")
    assert {:ok, %FileMetadata{name: "client.example"}} = Storage.stat(client, "/a")

    assert {:ok, %FileMetadata{name: "operation.example"}} =
             Storage.stat(client, "/a", request: [base_url: "https://operation.example/2"])
  end

  test "transport failures emit exception telemetry and Storage returns them" do
    Application.put_env(:magpie, :retry, false)
    Req.Test.stub(Magpie, &Req.Test.transport_error(&1, :timeout))

    assert {:error, %Req.TransportError{reason: :timeout}} = Storage.get(@client, "/a.txt")

    assert_receive {:telemetry, [:magpie, :request, :start], %{system_time: system_time},
                    %{endpoint: "/files/download", method: :post}}

    assert is_integer(system_time)

    assert_receive {:telemetry, [:magpie, :request, :exception], %{duration: duration},
                    %{endpoint: "/files/download", kind: :error, reason: %Req.TransportError{}}}

    assert is_integer(duration) and duration >= 0
  end

  def handle_event(event, measurements, metadata, pid) do
    send(pid, {:telemetry, event, measurements, metadata})
  end
end
