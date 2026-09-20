defmodule VerifiedBackup do
  @moduledoc "Publishes a snapshot manifest only after a complete restore drill."
  alias Magpie.{FolderMetadata, Metadata, Storage}

  def create(client, source, root \\ "/MagpieBackups") do
    root!(root)
    source = Path.expand(source)

    with {:ok, paths} <- source_files(source),
         :ok <- ensure_root(client, root) do
      id = DateTime.utc_now() |> DateTime.to_unix(:microsecond) |> Integer.to_string()
      id = id <> "-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
      directory = root <> "/" <> id

      with {:ok, _} <- Storage.mkdir(client, directory),
           {:ok, files} <- upload_files(client, source, paths, directory) do
        manifest = %{
          "version" => 1,
          "id" => id,
          "created_at" => DateTime.to_iso8601(DateTime.utc_now()),
          "files" => files
        }

        drill = Path.join(System.tmp_dir!(), "magpie-drill-" <> id)

        File.mkdir!(drill)

        try do
          with {:ok, _} <- restore(client, manifest, Path.join(drill, "restored")),
               {:ok, _} <-
                 Storage.put(
                   client,
                   directory <> "/manifest.json",
                   {:binary, Jason.encode_to_iodata!(manifest)},
                   autorename: false,
                   verify: true
                 ) do
            {:ok, directory <> "/manifest.json"}
          end
        after
          File.rm_rf(drill)
        end
      end
    end
  end

  def restore_from(client, manifest_path, destination) do
    with {:ok, body} <- Storage.get(client, manifest_path),
         {:ok, manifest} <- Jason.decode(body) do
      restore(client, manifest, destination)
    end
  end

  def restore(client, manifest, destination) do
    destination = Path.expand(destination)

    with :ok <- validate(manifest),
         :ok <- absent(destination),
         :ok <- File.mkdir_p(Path.dirname(destination)) do
      staging =
        destination <> ".restoring-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

      with :ok <- File.mkdir(staging) do
        try do
          with :ok <- download_files(client, manifest["files"], staging),
               :ok <- absent(destination),
               :ok <- File.rename(staging, destination) do
            {:ok, destination}
          end
        after
          File.rm_rf(staging)
        end
      end
    end
  end

  # A plan is useful for review; deletion belongs to an explicit operator action.
  def retention(client, root, keep) when is_integer(keep) and keep >= 1 do
    root!(root)

    with {:ok, entries} <- Storage.list(client, root) do
      Enum.filter(entries, &match?(%FolderMetadata{}, &1))
      |> Enum.reduce_while({:ok, [], []}, fn folder, {:ok, complete, incomplete} ->
        case read_manifest(client, folder.path_display <> "/manifest.json") do
          {:ok, manifest} ->
            {:cont, {:ok, [{manifest["created_at"], folder.path_display} | complete], incomplete}}

          {:error, :invalid_manifest} ->
            {:cont, {:ok, complete, [folder.path_display | incomplete]}}

          {:error, %Magpie.Error{} = error} ->
            if Magpie.Error.not_found?(error),
              do: {:cont, {:ok, complete, [folder.path_display | incomplete]}},
              else: {:halt, {:error, error}}

          error ->
            {:halt, error}
        end
      end)
      |> case do
        {:ok, complete, incomplete} ->
          ordered =
            complete
            |> Enum.sort_by(
              fn {at, path} ->
                {:ok, datetime, _} = DateTime.from_iso8601(at)
                {DateTime.to_unix(datetime, :microsecond), path}
              end,
              :desc
            )
            |> Enum.map(&elem(&1, 1))

          {:ok,
           %{
             keep: Enum.take(ordered, keep),
             delete_candidates: Enum.drop(ordered, keep),
             incomplete: Enum.sort(incomplete)
           }}

        error ->
          error
      end
    end
  end

  def validate(%{"version" => 1, "id" => id, "created_at" => at, "files" => files})
      when is_binary(id) and is_binary(at) and is_list(files) do
    valid_time = match?({:ok, _, _}, DateTime.from_iso8601(at))

    if id != "" and valid_time and Enum.all?(files, &valid_entry?/1) and unique_paths?(files),
      do: :ok,
      else: {:error, :invalid_manifest}
  end

  def validate(_), do: {:error, :invalid_manifest}

  defp valid_entry?(%{"path" => path, "rev" => rev, "size" => size, "content_hash" => hash})
       when is_binary(path) and is_binary(rev) and is_integer(size) and is_binary(hash) do
    safe_path?(path) and size >= 0 and Regex.match?(~r/\A[0-9a-f]{9,}\z/, rev) and
      Regex.match?(~r/\A[0-9a-f]{64}\z/, hash)
  end

  defp valid_entry?(_), do: false

  defp safe_path?(path) do
    String.valid?(path) and path != "" and
      not String.contains?(path, ["\\", ":", <<0>>]) and
      Enum.all?(String.split(path, "/"), &(&1 not in ["", ".", ".."] and String.trim(&1) == &1))
  end

  defp unique_paths?(files) do
    paths = Enum.map(files, &(String.normalize(&1["path"], :nfc) |> String.downcase()))
    set = MapSet.new(paths)

    length(paths) == MapSet.size(set) and
      Enum.all?(paths, fn path ->
        path
        |> Path.split()
        |> Enum.drop(-1)
        |> Enum.scan(&Path.join(&2, &1))
        |> Enum.all?(&(not MapSet.member?(set, &1)))
      end)
  end

  defp source_files(source) do
    with {:ok, %{type: :directory}} <- File.lstat(source),
         {:ok, paths} <- walk(source, "") do
      entries = Enum.map(paths, &%{"path" => &1})

      if Enum.all?(paths, &safe_path?/1) and unique_paths?(entries),
        do: {:ok, Enum.sort(paths)},
        else: {:error, :unsafe_source_paths}
    else
      {:ok, _} -> {:error, :source_must_be_a_directory}
      error -> error
    end
  end

  defp walk(source, relative) do
    with {:ok, names} <- File.ls(Path.join(source, relative)) do
      Enum.reduce_while(names, {:ok, []}, fn name, {:ok, acc} ->
        path = if relative == "", do: name, else: relative <> "/" <> name

        result =
          case File.lstat(Path.join(source, path)) do
            {:ok, %{type: :regular}} -> {:ok, [path]}
            {:ok, %{type: :directory}} -> walk(source, path)
            {:ok, _} -> {:error, {:unsupported_file, path}}
            error -> error
          end

        case result do
          {:ok, found} -> {:cont, {:ok, found ++ acc}}
          error -> {:halt, error}
        end
      end)
    end
  end

  defp upload_files(client, source, paths, directory) do
    Enum.reduce_while(paths, {:ok, []}, fn path, {:ok, acc} ->
      object = :crypto.hash(:sha256, path) |> Base.encode16(case: :lower)

      case Storage.put(
             client,
             directory <> "/" <> object <> ".blob",
             {:file, Path.join(source, path)},
             autorename: false,
             verify: true
           ) do
        {:ok, metadata} ->
          entry = %{
            "path" => path,
            "rev" => metadata.rev,
            "size" => metadata.size,
            "content_hash" => metadata.content_hash
          }

          {:cont, {:ok, acc ++ [entry]}}

        error ->
          {:halt, error}
      end
    end)
  end

  defp download_files(client, files, staging) do
    Enum.reduce_while(files, :ok, fn entry, :ok ->
      path = Path.join(staging, entry["path"])

      result =
        with {:ok, _} <- Storage.download(client, "rev:" <> entry["rev"], path, mkdir_p: true),
             {:ok, stat} <- File.stat(path) do
          hash = Metadata.content_hash(Magpie.Utils.file_stream(path, 65_536))

          if stat.size == entry["size"] and hash == entry["content_hash"],
            do: :ok,
            else: {:error, {:integrity_mismatch, entry["path"]}}
        end

      case result do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp read_manifest(client, path) do
    with {:ok, body} <- Storage.get(client, path) do
      case Jason.decode(body) do
        {:ok, manifest} -> with :ok <- validate(manifest), do: {:ok, manifest}
        {:error, _} -> {:error, :invalid_manifest}
      end
    end
  end

  defp absent(path) do
    case File.lstat(path) do
      {:error, :enoent} -> :ok
      {:ok, _} -> {:error, :destination_exists}
      error -> error
    end
  end

  defp ensure_root(client, root) do
    case Storage.stat(client, root) do
      {:ok, %FolderMetadata{}} ->
        :ok

      {:ok, _} ->
        {:error, :not_a_folder}

      {:error, %Magpie.Error{} = error} ->
        if Magpie.Error.not_found?(error) do
          case Storage.mkdir(client, root) do
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
      do: raise(ArgumentError, "use one dedicated top-level folder, such as /MagpieBackups")
  end
end
