defmodule OrderInbox do
  @moduledoc "Imports CSV orders from a Dropbox inbox and retries unfinished report/archive work."
  alias Magpie.{FileMetadata, FolderMetadata, Storage}
  alias OrderInbox.{CSV, Journal}
  @max_bytes 2 * 1024 * 1024

  def setup(client, root) do
    root = root!(root)

    Enum.reduce_while(
      [
        root
        | Enum.map(
            ["Incoming", "Processing", "Processed", "Rejected", "Reports"],
            &(root <> "/" <> &1)
          )
      ],
      :ok,
      fn path, :ok ->
        case ensure_folder(client, path) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end
    )
  end

  def run(client, journal, root) do
    root = root!(root)

    pending =
      Journal.snapshot(journal)["receipts"] |> Map.values() |> Enum.reject(& &1["delivered"])

    retries = Enum.map(pending, &{&1["key"], finalize(client, journal, root, &1)})
    attempted = MapSet.new(pending, & &1["key"])

    with {:ok, processing} <- Storage.list(client, root <> "/Processing"),
         {:ok, incoming} <- Storage.list(client, root <> "/Incoming") do
      results =
        for file <- processing ++ incoming,
            match?(%FileMetadata{}, file),
            String.downcase(Path.extname(file.name)) == ".csv",
            not MapSet.member?(attempted, key(file)) do
          {file.name, process(client, journal, root, file)}
        end

      {:ok, retries ++ results}
    end
  end

  def process(client, journal, root, %FileMetadata{} = file) do
    root = root!(root)

    with {:ok, claimed} <- claim(client, root, file),
         {:ok, receipt} <- receipt(client, journal, claimed) do
      finalize(client, journal, root, receipt)
    end
  end

  def key(file),
    do: :crypto.hash(:sha256, file.id <> ":" <> file.rev) |> Base.encode16(case: :lower)

  defp claim(client, root, file) do
    parent = String.downcase(Path.dirname(file.path_display || ""))

    cond do
      parent == String.downcase(root <> "/Incoming") ->
        Storage.move(client, file.id, root <> "/Processing/" <> key(file) <> ".csv")

      parent == String.downcase(root <> "/Processing") ->
        {:ok, file}

      true ->
        {:error, :outside_inbox}
    end
  end

  defp receipt(client, journal, file) do
    case Journal.snapshot(journal)["receipts"][key(file)] do
      nil ->
        with {:ok, parsed} <- read_orders(client, file) do
          Journal.record(
            journal,
            %{
              "key" => key(file),
              "file_id" => file.id,
              "rev" => file.rev,
              "source" => file.path_display,
              "delivered" => false
            },
            parsed
          )
        end

      existing ->
        {:ok, existing}
    end
  end

  defp read_orders(_client, %{size: size}) when size > @max_bytes,
    do: {:ok, {:error, ["CSV files must be at most 2 MiB."]}}

  defp read_orders(client, file) do
    with {:ok, body} <- Storage.get(client, "rev:" <> file.rev) do
      if byte_size(body) <= @max_bytes,
        do: {:ok, CSV.parse(body)},
        else: {:ok, {:error, ["CSV files must be at most 2 MiB."]}}
    end
  end

  defp finalize(_client, _journal, _root, %{"delivered" => true} = receipt), do: {:ok, receipt}

  defp finalize(client, journal, root, receipt) do
    folder = if receipt["outcome"] == "imported", do: "Processed", else: "Rejected"
    destination = root <> "/" <> folder <> "/" <> receipt["key"] <> ".csv"
    report = Map.take(receipt, ["key", "file_id", "rev", "outcome", "count", "errors"])

    with {:ok, _} <-
           Storage.put(
             client,
             root <> "/Reports/" <> receipt["key"] <> ".json",
             {:binary, Jason.encode_to_iodata!(report)},
             mode: "overwrite",
             autorename: false,
             verify: true
           ),
         {:ok, current} <- Storage.stat(client, receipt["file_id"]),
         :ok <- archive(client, current, receipt, destination),
         {:ok, delivered} <- Journal.delivered(journal, receipt["key"]) do
      {:ok, delivered}
    end
  end

  defp archive(client, file, receipt, destination) do
    cond do
      file.rev != receipt["rev"] ->
        {:error, :revision_changed}

      same_path?(file.path_display, destination) ->
        :ok

      not same_path?(file.path_display, receipt["source"]) ->
        {:error, :file_moved_elsewhere}

      true ->
        case Storage.move(client, file.id, destination) do
          {:ok, _} -> :ok
          error -> error
        end
    end
  end

  defp same_path?(left, right),
    do: is_binary(left) and is_binary(right) and String.downcase(left) == String.downcase(right)

  defp ensure_folder(client, path) do
    case Storage.stat(client, path) do
      {:ok, %FolderMetadata{}} ->
        :ok

      {:ok, _} ->
        {:error, :not_a_folder}

      {:error, %Magpie.Error{} = error} ->
        if Magpie.Error.not_found?(error) do
          case Storage.mkdir(client, path) do
            {:ok, _} -> :ok
            error -> error
          end
        else
          {:error, error}
        end

      error ->
        error
    end
  end

  defp root!(root) do
    unless is_binary(root) and Regex.match?(~r{\A/[A-Za-z0-9_-]+\z}, root),
      do: raise(ArgumentError, "use one dedicated top-level folder, such as /MagpieOrders")

    root
  end
end
