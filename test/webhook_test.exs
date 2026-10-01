defmodule Magpie.WebhookTest do
  use ExUnit.Case, async: true
  alias Magpie.Webhook
  alias Magpie.Webhook.Plug, as: WebhookPlug
  @secret "fake-app-secret"
  @body "{\n  \"list_folder\": {\"accounts\": [\"dbid:a\", \"dbid:b\", \"dbid:a\"]}\n}"
  defp sign(body), do: :crypto.mac(:hmac, :sha256, @secret, body) |> Base.encode16(case: :lower)

  defp opts(extra \\ []) do
    pid = self()

    WebhookPlug.init(
      Keyword.merge(
        [
          path: "/webhook",
          app_secret: fn -> @secret end,
          notify: fn accounts ->
            send(pid, {:enqueue, accounts})
            :ok
          end
        ],
        extra
      )
    )
  end

  defp post(body, signature) do
    conn = Plug.Test.conn(:post, "/webhook", body)
    if signature, do: Plug.Conn.put_req_header(conn, "x-dropbox-signature", signature), else: conn
  end

  test "verification challenge headers and invalid challenges" do
    assert {:ok, %{body: "<hello>", status: 200, headers: headers}} = Webhook.challenge("<hello>")
    assert {"content-type", "text/plain"} in headers
    assert {"x-content-type-options", "nosniff"} in headers

    for invalid <- [nil, "", %{}, 42],
        do: assert({:error, :invalid_challenge} = Webhook.challenge(invalid))

    conn = WebhookPlug.call(Plug.Test.conn(:get, "/webhook?challenge=%3Chello%3E"), opts())
    assert conn.status == 200 and conn.halted and conn.resp_body == "<hello>"
    assert Plug.Conn.get_resp_header(conn, "content-type") == ["text/plain"]
    assert Plug.Conn.get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    assert WebhookPlug.call(Plug.Test.conn(:get, "/webhook"), opts()).status == 400
  end

  test "signature validates original bytes; rejects missing, invalid, malformed, changed body and wrong secret" do
    assert Webhook.valid_signature?(@body, sign(@body), @secret)
    assert Webhook.valid_signature?(@body, String.upcase(sign(@body)), @secret)

    for signature <- [nil, "", "abc", String.duplicate("z", 64), String.duplicate("0", 64)] do
      refute Webhook.valid_signature?(@body, signature, @secret)
      assert {:error, :invalid_signature} = Webhook.notification(@body, signature, @secret)
      assert WebhookPlug.call(post(@body, signature), opts()).status == 403
    end

    refute Webhook.valid_signature?(@body <> " ", sign(@body), @secret)
    refute Webhook.valid_signature?(@body, sign(@body), "other-secret")
    assert WebhookPlug.call(post(@body <> " ", sign(@body)), opts()).status == 403
    refute_received {:enqueue, _}
  end

  test "multiple accounts, duplicates and empty lists; rejects signed invalid JSON and payload shapes" do
    assert {:ok, ["dbid:a", "dbid:b", "dbid:a"]} =
             Webhook.notification(@body, sign(@body), @secret)

    empty = ~s({"list_folder":{"accounts":[]},"delta":{"users":[1]}})
    assert {:ok, []} = Webhook.notification(empty, sign(empty), @secret)

    for body <- [
          "not json",
          "null",
          "[]",
          ~s({"list_folder":{"accounts":"a"}}),
          ~s({"list_folder":{"accounts":[1]}}),
          ~s({"list_folder":{"accounts":[""]}})
        ] do
      assert {:error, :invalid_payload} = Webhook.notification(body, sign(body), @secret)
      assert WebhookPlug.call(post(body, sign(body)), opts()).status == 400
    end

    refute_received {:enqueue, _}
  end

  test "unknown signed notification objects are acknowledged and observable without enqueueing" do
    for body <- ["{}", ~s({"team":{"members":["id"]}}), ~s({"delta":{"users":[1]}})] do
      assert {:ok, :ignored} = Webhook.notification(body, sign(body), @secret)
      conn = WebhookPlug.call(post(body, sign(body)), opts())
      assert conn.status == 200 and conn.halted
      assert conn.private.magpie_webhook_notification == :ignored
      assert conn.private.magpie_webhook_raw_body == body
      assert WebhookPlug.call(post(body, nil), opts()).status == 403
    end

    refute_received {:enqueue, _}
  end

  test "empty accounts are acknowledged without invoking notify" do
    body = ~s({"list_folder":{"accounts":[]}})
    assert WebhookPlug.call(post(body, sign(body)), opts()).status == 200
    refute_received {:enqueue, _}
  end

  test "malformed recognized notifications fail even with valid signatures" do
    for body <- [~s({"list_folder":null}), ~s({"list_folder":{}})] do
      assert {:error, :invalid_payload} = Webhook.notification(body, sign(body), @secret)
      assert WebhookPlug.call(post(body, sign(body)), opts()).status == 400
    end

    refute_received {:enqueue, _}
  end

  test "invalid resolved secrets are explicit configuration errors without leaking values" do
    for secret <- [nil, "", 42, %{}, {:error, "private-value"}] do
      error =
        assert_raise ArgumentError, fn ->
          WebhookPlug.call(post(@body, sign(@body)), opts(app_secret: fn -> secret end))
        end

      assert Exception.message(error) == "webhook :app_secret must resolve to a non-empty binary"
    end

    refute_received {:enqueue, _}
  end

  test "unexpected notify return raises an explicit error without leaking returned data" do
    for result <- [nil, {:ok, "private-value"}, :unexpected] do
      error =
        assert_raise ArgumentError, fn ->
          WebhookPlug.call(post(@body, sign(@body)), opts(notify: fn _ -> result end))
        end

      assert Exception.message(error) == "webhook :notify must return :ok or {:error, reason}"
    end
  end

  test "integration retains original body across chunks and halts before parsers" do
    # Large whitespace prefix forces multiple read_body calls without changing JSON.
    body = String.duplicate(" ", 130_000) <> @body
    conn = WebhookPlug.call(post(body, sign(body)), opts())
    assert conn.status == 200 and conn.halted
    assert conn.private.magpie_webhook_raw_body == body
    assert_received {:enqueue, ["dbid:a", "dbid:b", "dbid:a"]}
    refute_received {:enqueue, _}
  end

  test "duplicate signature headers are rejected" do
    conn = post(@body, sign(@body))
    conn = %{conn | req_headers: [{"x-dropbox-signature", sign(@body)} | conn.req_headers]}
    assert WebhookPlug.call(conn, opts()).status == 403
    refute_received {:enqueue, _}
  end

  test "unrelated paths pass through, methods reject, size limits and enqueue failure" do
    conn = Plug.Test.conn(:post, "/other", "x")
    assert WebhookPlug.call(conn, opts()) == conn
    assert WebhookPlug.call(Plug.Test.conn(:put, "/webhook"), opts()).status == 405
    assert WebhookPlug.call(post(@body, sign(@body)), opts(max_body_bytes: 10)).status == 413
    refute_received {:enqueue, _}

    assert WebhookPlug.call(
             post(@body, sign(@body)),
             opts(notify: fn _ -> {:error, :queue_down} end)
           ).status == 503

    assert WebhookPlug.call(post(@body, sign(@body)), opts(max_body_bytes: byte_size(@body))).status ==
             200
  end

  test "invalid endpoint configuration raises without exposing secrets" do
    for extra <- [
          [notify: nil],
          [app_secret: ""],
          [path: nil],
          [max_body_bytes: 0],
          [unknown: true]
        ] do
      assert_raise ArgumentError, fn -> opts(extra) end
    end
  end
end
