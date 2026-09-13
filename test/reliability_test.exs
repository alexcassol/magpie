defmodule Magpie.ReliabilityTest do
  use ExUnit.Case, async: true

  alias Magpie.{Client, Error, Files, Pager, Storage}

  @client Client.new("fake-token")

  @tag :tmp_dir
  test "verification does not mask an upload error when the source disappears", %{tmp_dir: dir} do
    path = Path.join(dir, "source.txt")
    File.write!(path, "data")

    Req.Test.stub(Magpie, fn conn ->
      File.rm!(path)
      conn |> Plug.Conn.put_status(409) |> Req.Test.json(%{"error_summary" => "path/conflict/.."})
    end)

    assert {:error, %Error{status: 409}} = Files.upload_file(@client, "/file", path, verify: true)
  end

  for {failure, exception} <- [api: Error, transport: Req.TransportError] do
    test "listing preserves #{failure} failures on continuation pages" do
      failure = unquote(failure)

      Req.Test.stub(Magpie, fn conn ->
        case conn.request_path do
          "/2/files/list_folder" ->
            Req.Test.json(conn, %{
              "entries" => [%{".tag" => "file", "name" => "first"}],
              "cursor" => "next",
              "has_more" => true
            })

          "/2/files/list_folder/continue" ->
            fail_page(conn, failure)
        end
      end)

      exception = unquote(exception)
      assert {:error, %{__struct__: ^exception}} = Storage.list(@client, "/folder")
      assert_raise exception, fn -> Storage.list!(@client, "/folder") end
      assert_raise exception, fn -> @client |> Storage.stream("/folder") |> Enum.to_list() end

      assert [%Magpie.FileMetadata{name: "first"}] =
               @client |> Storage.stream("/folder") |> Enum.take(1)
    end
  end

  defp fail_page(conn, :api) do
    conn |> Plug.Conn.put_status(409) |> Req.Test.json(%{"error_summary" => "reset/.."})
  end

  defp fail_page(conn, :transport), do: Req.Test.transport_error(conn, :timeout)

  test "generic pager preserves exception tuples from page callbacks" do
    error = %Req.TransportError{reason: :timeout}

    for first <- [
          fn -> {:error, error} end,
          fn -> {:ok, %{"entries" => [], "cursor" => "next", "has_more" => true}} end
        ] do
      stream = Pager.stream(first, fn "next" -> {:error, error} end)
      assert_raise Req.TransportError, fn -> Enum.to_list(stream) end
    end
  end

  @tag :tmp_dir
  test "failed downloads preserve the destination and clean temporary files", %{tmp_dir: dir} do
    destination = Path.join(dir, "target")
    File.write!(destination, "original")
    Req.Test.stub(Magpie, &Req.Test.transport_error(&1, :timeout))
    assert {:error, %Req.TransportError{}} = Storage.download(@client, "/file", destination)
    assert File.read!(destination) == "original"
    assert Path.wildcard(destination <> ".magpie-*.part") == []
  end
end
