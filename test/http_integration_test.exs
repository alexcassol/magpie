defmodule Magpie.HTTPIntegrationTest do
  use ExUnit.Case, async: true
  alias Magpie.{Client, Error, Storage}

  # Use a real socket here to cover behavior that Req.Test bypasses.
  defp serve(replies) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, {_, port}} = :inet.sockname(listener)
    parent = self()

    server =
      Task.async(fn ->
        Enum.each(replies, fn {delay, status, headers, body} ->
          {:ok, socket} = :gen_tcp.accept(listener, 3000)
          {:ok, request} = :gen_tcp.recv(socket, 0, 3000)
          send(parent, {:http_request, request})
          Process.sleep(delay)

          :gen_tcp.send(socket, [
            "HTTP/1.1 ",
            Integer.to_string(status),
            " Response\r\n",
            "content-type: application/json\r\nconnection: close\r\ncontent-length: ",
            Integer.to_string(byte_size(body)),
            "\r\n",
            headers,
            "\r\n",
            body
          ])

          :gen_tcp.close(socket)
        end)
      end)

    on_exit(fn -> :gen_tcp.close(listener) end)
    {"http://127.0.0.1:#{port}/2", server}
  end

  test "real HTTP retry preserves credentials and returns terminal diagnostics" do
    body = Jason.encode!(%{"error_summary" => "too_many_requests"})

    {url, server} =
      serve([
        {0, 429, "retry-after: 0\r\nx-dropbox-request-id: first\r\n", body},
        {0, 429, "retry-after: 2\r\nx-dropbox-request-id: second\r\n", body}
      ])

    client =
      Client.new("local-test-token",
        base_url: url,
        req_options: [plug: nil],
        retry: [max_retries: 1, log_level: false]
      )

    assert {:error, %Error{attempts: 2, retry_after: 2000, request_id: "second"}} =
             Storage.stat(client, "/a")

    Task.await(server)

    for _ <- 1..2 do
      assert_receive {:http_request, request}
      assert request =~ "authorization: Bearer local-test-token"
      assert request =~ "POST /2/files/get_metadata"
    end
  end

  test "longpoll outwaits the configured receive timeout and drops the bearer token" do
    {url, server} = serve([{150, 200, "", ~s({"changes": true})}])

    client =
      Client.new("local-test-token",
        notify_url: url,
        req_options: [plug: nil, receive_timeout: 20],
        retry: false
      )

    assert {:ok, %{"changes" => true}} = Magpie.Files.ListFolder.longpoll(client, "cursor")
    Task.await(server)

    assert_receive {:http_request, request}
    assert request =~ "POST /2/files/list_folder/longpoll"
    refute request =~ "authorization:"
  end

  test "real HTTP receive timeout follows Storage's error tuple contract" do
    {url, server} = serve([{100, 200, "", "{}"}])

    client =
      Client.new("token",
        base_url: url,
        req_options: [plug: nil, receive_timeout: 10],
        retry: false
      )

    assert {:error, %Req.TransportError{reason: :timeout}} = Storage.stat(client, "/a")
    Task.await(server)
  end
end
