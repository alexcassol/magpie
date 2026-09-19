defmodule Magpie.Options do
  @moduledoc false

  @config [:req_options, :retry, :timeout, :base_url, :upload_url, :account_id, :scopes]
  @write [:mode, :if_rev, :autorename, :mute]
  @upload @write ++ [:chunk_size, :session_threshold, :verify, :skip_unchanged, :progress]
  @listing [
    :recursive,
    :include_media_info,
    :include_deleted,
    :include_has_explicit_shared_members,
    :include_mounted_folders,
    :limit,
    :shared_link,
    :include_property_groups,
    :include_non_downloadable_files
  ]
  @booleans [
    :autorename,
    :mute,
    :verify,
    :skip_unchanged,
    :with_headers,
    :mkdir_p,
    :recursive,
    :include_media_info,
    :include_deleted,
    :include_has_explicit_shared_members,
    :include_mounted_folders,
    :include_non_downloadable_files
  ]

  def config_keys, do: @config

  def keyword!(opts) do
    unless is_list(opts) and Keyword.keyword?(opts),
      do: raise(ArgumentError, "expected options to be a keyword list")

    if length(Keyword.keys(opts)) != length(Enum.uniq(Keyword.keys(opts))),
      do: raise(ArgumentError, "duplicate options are not supported")

    opts
  end

  def config!(opts) do
    allowed!(opts, @config)

    Enum.each(opts, fn
      {:req_options, value} ->
        keyword!(value)

        Enum.each(value, fn
          {key, timeout} when key in [:receive_timeout, :request_timeout, :pool_timeout] ->
            timeout!(key, timeout)

          _ ->
            :ok
        end)

      {:retry, value} ->
        retry!(value)

      {:timeout, value} ->
        timeout!(:timeout, value)

      {:scopes, nil} ->
        :ok

      {:scopes, value} ->
        check!(:scopes, is_list(value) and Enum.all?(value, &is_binary/1))

      {:account_id, value} ->
        check!(:account_id, is_nil(value) or is_binary(value))

      {key, value} when key in [:base_url, :upload_url] ->
        check!(
          key,
          is_binary(value) and
            match?(
              %URI{scheme: scheme, host: host}
              when scheme in ["http", "https"] and is_binary(host),
              URI.parse(value)
            )
        )
    end)

    opts
  end

  def retry!(false), do: false

  def retry!(opts) do
    allowed!(opts, [:max_retries, :delay, :log_level])

    Enum.each(opts, fn
      {:max_retries, n} ->
        check!(:max_retries, is_integer(n) and n >= 0)

      {:delay, n} ->
        check!(:delay, (is_integer(n) and n >= 0) or is_function(n, 1))

      {:log_level, level} ->
        check!(
          :log_level,
          level in [
            false,
            :debug,
            :info,
            :notice,
            :warning,
            :error,
            :critical,
            :alert,
            :emergency
          ]
        )
    end)

    opts
  end

  def storage!(operation, opts) do
    allowed =
      case operation do
        :put -> @upload
        :get -> [:with_headers]
        :download -> [:mkdir_p, :progress, :size]
        :delete -> [:parent_rev]
        :stat -> [:include_media_info, :include_deleted, :include_has_explicit_shared_members]
        :list -> @listing
        :upload_url -> @write ++ [:duration]
        op when op in [:url, :copy, :move, :mkdir] -> []
      end

    allowed!(opts, [:request | allowed])
    values!(opts)
    if Keyword.has_key?(opts, :request), do: config!(opts[:request])
    opts
  end

  def upload!(opts) do
    allowed!(opts, (@upload -- [:skip_unchanged]) ++ [:expected_hash])
    values!(opts)
    opts
  end

  def batch!(operation, opts) do
    keyword!(opts)
    storage!(operation, Keyword.drop(opts, [:max_concurrency, :timeout, :on_progress]))

    if Keyword.has_key?(opts, :max_concurrency),
      do:
        check!(
          :max_concurrency,
          is_integer(opts[:max_concurrency]) and opts[:max_concurrency] > 0
        )

    if Keyword.has_key?(opts, :timeout), do: timeout!(:timeout, opts[:timeout])
    callback!(:on_progress, opts[:on_progress])
    opts
  end

  def write_mode(opts) do
    case Keyword.fetch(opts, :if_rev) do
      {:ok, rev} ->
        check!(:if_rev, is_binary(rev) and byte_size(rev) > 0)
        %{".tag" => "update", "update" => rev}

      :error ->
        mode = Keyword.get(opts, :mode, "add")
        check!(:mode, valid_mode?(mode))
        mode
    end
  end

  defp valid_mode?(mode) when mode in ["add", "overwrite"], do: true

  defp valid_mode?(%{".tag" => "update", "update" => rev}),
    do: is_binary(rev) and byte_size(rev) > 0

  defp valid_mode?(%{".tag" => tag}) when tag in ["add", "overwrite"], do: true
  defp valid_mode?(_), do: false

  defp values!(opts) do
    Enum.each(opts, fn
      {key, value} when key in @booleans ->
        check!(key, is_boolean(value))

      {:chunk_size, value} ->
        check!(:chunk_size, is_integer(value) and value > 0 and value <= 150 * 1024 * 1024)

      {:session_threshold, value} ->
        check!(
          :session_threshold,
          is_integer(value) and value >= 0 and value <= 150 * 1024 * 1024
        )

      {:size, value} ->
        check!(:size, is_nil(value) or (is_integer(value) and value >= 0))

      {:limit, value} ->
        check!(:limit, is_integer(value) and value in 1..2000)

      {:duration, value} ->
        check!(:duration, is_number(value) and value > 0 and value <= 14_400)

      {:parent_rev, value} ->
        check!(:parent_rev, is_binary(value) and byte_size(value) > 0)

      {:progress, value} ->
        callback!(:progress, value)

      _ ->
        :ok
    end)

    if Keyword.has_key?(opts, :mode) or Keyword.has_key?(opts, :if_rev), do: write_mode(opts)
    :ok
  end

  defp callback!(key, value), do: check!(key, is_nil(value) or is_function(value, 2))

  defp timeout!(key, value),
    do: check!(key, value == :infinity or (is_integer(value) and value >= 0))

  defp check!(_key, true), do: :ok
  defp check!(key, false), do: raise(ArgumentError, "invalid value for :#{key}")

  defp allowed!(opts, allowed) do
    keyword!(opts)

    if Enum.any?(Keyword.keys(opts), &(&1 not in allowed)),
      do: raise(ArgumentError, "unsupported option; supported keys: #{Enum.join(allowed, ", ")}")

    opts
  end
end
