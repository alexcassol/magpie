defmodule MagpieTokenServerTest do
  @moduledoc """
  Caching, proactive refresh, single-flight and failure handling of the
  supervised token holder.
  """
  use ExUnit.Case, async: true

  alias Magpie.Auth.Token
  alias Magpie.Auth.TokenServer

  @opts [app_key: "APP_KEY", app_secret: "APP_SECRET", refresh_token: "RT"]

  describe "start_link/1" do
    test "requires an app key" do
      assert_raise ArgumentError, ~r/requires a :app_key/, fn ->
        TokenServer.start_link(Keyword.delete(@opts, :app_key))
      end
    end

    test "the refresh token is optional, but must be a string when given" do
      assert {:ok, pid} = TokenServer.start_link(Keyword.delete(@opts, :refresh_token))
      assert Process.alive?(pid)

      assert_raise ArgumentError, ~r/:refresh_token to be a string/, fn ->
        TokenServer.start_link(Keyword.put(@opts, :refresh_token, :not_a_string))
      end
    end

    test "requires an app secret unless the app uses PKCE" do
      assert_raise ArgumentError, ~r/requires an :app_secret/, fn ->
        TokenServer.start_link(Keyword.delete(@opts, :app_secret))
      end

      assert {:ok, pid} =
               TokenServer.start_link(Keyword.delete(@opts, :app_secret) ++ [pkce: true])

      assert Process.alive?(pid)
    end

    test "is supervision-tree friendly" do
      assert %{id: TokenServer, start: {TokenServer, :start_link, [_opts]}} =
               TokenServer.child_spec(@opts)
    end
  end

  describe "fetch_token/1" do
    test "returns the cached token while it is comfortably fresh" do
      stub_token("sl.REFRESHED")

      server = start_server!(access_token: "sl.CACHED", expires_at: in_seconds(3600))

      assert {:ok, "sl.CACHED"} = TokenServer.fetch_token(server)
      assert {:ok, "sl.CACHED"} = TokenServer.fetch_token(server)

      assert request_count() == 0
    end

    test "refreshes proactively once the token is inside the margin" do
      stub_token("sl.REFRESHED")

      server = start_server!(access_token: "sl.CACHED", expires_at: in_seconds(120))

      assert {:ok, "sl.REFRESHED"} = TokenServer.fetch_token(server)
      assert request_count() == 1
    end

    test "honors a custom refresh margin" do
      stub_token("sl.REFRESHED")

      server =
        start_server!(access_token: "sl.CACHED", expires_at: in_seconds(120), refresh_margin: 60)

      assert {:ok, "sl.CACHED"} = TokenServer.fetch_token(server)
      assert request_count() == 0
    end

    test "refreshes when it starts without an access token" do
      stub_token("sl.REFRESHED")

      server = start_server!([])

      assert {:ok, "sl.REFRESHED"} = TokenServer.fetch_token(server)
      assert %Token{access_token: "sl.REFRESHED", refresh_token: "RT"} = TokenServer.token(server)
    end

    test "refreshes a token whose expiry is unknown" do
      stub_token("sl.REFRESHED")

      server = start_server!(access_token: "sl.NO_EXPIRY")

      assert {:ok, "sl.REFRESHED"} = TokenServer.fetch_token(server)
    end

    test "refreshes an already expired token" do
      stub_token("sl.REFRESHED")

      server = start_server!(access_token: "sl.STALE", expires_at: in_seconds(-10))

      assert {:ok, "sl.REFRESHED"} = TokenServer.fetch_token(server)
    end

    test "concurrent callers share a single refresh" do
      test_pid = self()

      Req.Test.stub(Magpie, fn conn ->
        send(test_pid, :token_request)
        # Long enough for every caller to pile up behind the first one
        Process.sleep(50)
        Req.Test.json(conn, %{"access_token" => "sl.REFRESHED", "expires_in" => 14_400})
      end)

      server = start_server!([])

      results =
        1..10
        |> Task.async_stream(fn _ -> TokenServer.fetch_token(server) end, ordered: false)
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.all?(results, &(&1 == {:ok, "sl.REFRESHED"}))
      assert request_count() == 1
    end
  end

  describe "refresh_token/1" do
    test "refreshes even when the cached token is still fresh" do
      stub_token("sl.REFRESHED")

      server = start_server!(access_token: "sl.CACHED", expires_at: in_seconds(3600))

      assert {:ok, "sl.REFRESHED"} = TokenServer.refresh_token(server)
      assert {:ok, "sl.REFRESHED"} = TokenServer.fetch_token(server)
      assert request_count() == 1
    end

    test "adopts a rotated refresh token when Dropbox sends one" do
      Req.Test.stub(Magpie, fn conn ->
        Req.Test.json(conn, %{
          "access_token" => "sl.REFRESHED",
          "refresh_token" => "ROTATED",
          "expires_in" => 14_400
        })
      end)

      server = start_server!([])

      assert {:ok, "sl.REFRESHED"} = TokenServer.refresh_token(server)
      assert %Token{refresh_token: "ROTATED"} = TokenServer.token(server)
    end
  end

  describe "failed refresh" do
    test "replies with the error, keeps the old state and stays alive" do
      Req.Test.stub(Magpie, fn conn ->
        conn
        |> Plug.Conn.put_status(400)
        |> Req.Test.json(%{"error" => "invalid_grant"})
      end)

      server = start_server!(access_token: "sl.STALE", expires_at: in_seconds(-10))

      assert {:error, %Magpie.Error{status: 400, summary: "invalid_grant"}} =
               TokenServer.fetch_token(server)

      assert Process.alive?(server)
      assert %Token{access_token: "sl.STALE"} = TokenServer.token(server)
    end
  end

  describe "unconfigured server" do
    test "answers no_refresh_token without touching the network, and stays alive" do
      stub_token("sl.NEVER")

      server = start_server!(refresh_token: nil)

      assert {:error, %Magpie.Error{status: 401, summary: "no_refresh_token"}} =
               TokenServer.fetch_token(server)

      assert {:error, %Magpie.Error{summary: "no_refresh_token"}} =
               TokenServer.refresh_token(server)

      assert TokenServer.token(server) == nil
      assert Process.alive?(server)
      assert request_count() == 0
    end
  end

  describe "set_refresh_token/3" do
    test "configures an unconfigured server; the next fetch refreshes with it" do
      stub_recording_refresh_token()

      server = start_server!(refresh_token: nil)

      assert :ok = TokenServer.set_refresh_token(server, "NEW_RT")
      assert {:ok, "sl.minted-with-NEW_RT"} = TokenServer.fetch_token(server)
      assert_receive {:refresh_with, "NEW_RT"}

      assert %Token{refresh_token: "NEW_RT", access_token: "sl.minted-with-NEW_RT"} =
               TokenServer.token(server)
    end

    test "a seeded valid pair is used without refreshing" do
      stub_token("sl.REFRESHED")

      server = start_server!(refresh_token: nil)

      assert :ok =
               TokenServer.set_refresh_token(server, "NEW_RT",
                 access_token: "sl.SEEDED",
                 expires_at: in_seconds(3600)
               )

      assert {:ok, "sl.SEEDED"} = TokenServer.fetch_token(server)
      assert request_count() == 0
    end

    test "a seeded expired pair triggers a refresh" do
      stub_token("sl.REFRESHED")

      server = start_server!(refresh_token: nil)

      assert :ok =
               TokenServer.set_refresh_token(server, "NEW_RT",
                 access_token: "sl.STALE",
                 expires_at: in_seconds(-10)
               )

      assert {:ok, "sl.REFRESHED"} = TokenServer.fetch_token(server)
      assert request_count() == 1
    end

    test "an incomplete pair is discarded rather than seeded" do
      stub_token("sl.REFRESHED")

      server = start_server!(refresh_token: nil)

      assert :ok = TokenServer.set_refresh_token(server, "NEW_RT", access_token: "sl.NO_EXPIRY")

      assert %Token{access_token: nil, expires_at: nil} = TokenServer.token(server)
      assert {:ok, "sl.REFRESHED"} = TokenServer.fetch_token(server)
    end

    test "re-authorization drops the cached token of the previous grant" do
      stub_recording_refresh_token()

      server = start_server!(access_token: "sl.CACHED", expires_at: in_seconds(3600))

      assert {:ok, "sl.CACHED"} = TokenServer.fetch_token(server)
      assert :ok = TokenServer.set_refresh_token(server, "NEW_RT")

      assert %Token{access_token: nil, refresh_token: "NEW_RT"} = TokenServer.token(server)
      assert {:ok, "sl.minted-with-NEW_RT"} = TokenServer.fetch_token(server)
      assert_receive {:refresh_with, "NEW_RT"}
    end

    test "an in-flight refresh cannot clobber a token set while it ran" do
      test_pid = self()

      # The stub blocks inside the server process until the test releases it,
      # so the interleaving is deterministic — no sleeps involved.
      Req.Test.stub(Magpie, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        refresh_token = URI.decode_query(body)["refresh_token"]
        send(test_pid, {:refresh_with, refresh_token})

        receive do
          :continue -> :ok
        end

        Req.Test.json(conn, %{
          "access_token" => "sl.minted-with-#{refresh_token}",
          "expires_in" => 14_400
        })
      end)

      server = start_server!([])

      # 1. A fetch starts a refresh with the old token and blocks in the stub
      slow_fetch = Task.async(fn -> TokenServer.fetch_token(server) end)
      assert_receive {:refresh_with, "RT"}

      # 2. A re-authorization arrives while that refresh is in flight
      set = Task.async(fn -> TokenServer.set_refresh_token(server, "NEW_RT") end)
      wait_for_queued_call(server)

      # 3. Only now the old refresh completes
      send(server, :continue)

      assert Task.await(slow_fetch) == {:ok, "sl.minted-with-RT"}
      assert Task.await(set) == :ok

      # The late result must not survive: cache dropped, new token in place
      assert %Token{access_token: nil, refresh_token: "NEW_RT"} = TokenServer.token(server)

      next_fetch = Task.async(fn -> TokenServer.fetch_token(server) end)
      assert_receive {:refresh_with, "NEW_RT"}
      send(server, :continue)

      assert Task.await(next_fetch) == {:ok, "sl.minted-with-NEW_RT"}
    end
  end

  describe ":on_refresh" do
    test "is called with the new token" do
      stub_token("sl.REFRESHED")
      test_pid = self()

      server = start_server!(on_refresh: &send(test_pid, {:refreshed, &1}))

      assert {:ok, "sl.REFRESHED"} = TokenServer.fetch_token(server)

      assert_receive {:refreshed, %Token{access_token: "sl.REFRESHED", refresh_token: "RT"}}
    end

    test "a raising callback does not take the server down" do
      stub_token("sl.REFRESHED")

      server = start_server!(on_refresh: fn _token -> raise "boom" end)

      assert ExUnit.CaptureLog.capture_log(fn ->
               assert {:ok, "sl.REFRESHED"} = TokenServer.fetch_token(server)
             end) =~ "on_refresh callback raised"

      assert Process.alive?(server)
    end
  end

  defp start_server!(opts) do
    server = start_supervised!({TokenServer, Keyword.merge(@opts, opts)})
    # The refresh happens inside the server, so it needs access to the stub
    Req.Test.allow(Magpie, self(), server)

    server
  end

  defp stub_token(access_token) do
    test_pid = self()

    Req.Test.stub(Magpie, fn conn ->
      send(test_pid, :token_request)
      Req.Test.json(conn, %{"access_token" => access_token, "expires_in" => 14_400})
    end)
  end

  defp stub_recording_refresh_token do
    test_pid = self()

    Req.Test.stub(Magpie, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      refresh_token = URI.decode_query(body)["refresh_token"]
      send(test_pid, {:refresh_with, refresh_token})

      Req.Test.json(conn, %{
        "access_token" => "sl.minted-with-#{refresh_token}",
        "expires_in" => 14_400
      })
    end)
  end

  # Waits until the server has a pending GenServer call in its mailbox —
  # while its current call sits blocked inside the stub.
  defp wait_for_queued_call(server) do
    case Process.info(server, :message_queue_len) do
      {:message_queue_len, len} when len > 0 -> :ok
      _ -> wait_for_queued_call(server)
    end
  end

  defp in_seconds(seconds), do: DateTime.add(DateTime.utc_now(), seconds, :second)

  defp request_count(count \\ 0) do
    receive do
      :token_request -> request_count(count + 1)
    after
      0 -> count
    end
  end
end
