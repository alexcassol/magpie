defmodule OrderInbox.Journal do
  @moduledoc "Stores orders and receipts together in one local snapshot. Run one journal per file."
  use GenServer

  def start_link(path), do: GenServer.start_link(__MODULE__, Path.expand(path))
  def snapshot(pid), do: GenServer.call(pid, :snapshot)
  def record(pid, receipt, parsed), do: GenServer.call(pid, {:record, receipt, parsed})
  def delivered(pid, key), do: GenServer.call(pid, {:delivered, key})

  @impl true
  def init(path) do
    File.mkdir_p!(Path.dirname(path))

    data =
      case File.read(path) do
        {:ok, body} -> Jason.decode!(body)
        {:error, :enoent} -> %{"version" => 1, "orders" => %{}, "receipts" => %{}}
        {:error, reason} -> raise File.Error, reason: reason, action: "read journal", path: path
      end

    case data do
      %{"version" => 1, "orders" => orders, "receipts" => receipts}
      when is_map(orders) and is_map(receipts) ->
        {:ok, %{path: path, data: data}}

      _ ->
        {:stop, :invalid_journal}
    end
  end

  @impl true
  def handle_call(:snapshot, _from, state), do: {:reply, state.data, state}

  def handle_call({:record, receipt, parsed}, _from, state) do
    key = receipt["key"]

    case state.data["receipts"][key] do
      nil ->
        {receipt, orders} = import_orders(receipt, parsed, state.data["orders"])
        data = state.data |> Map.put("orders", orders) |> put_in(["receipts", key], receipt)
        save(state, data, receipt)

      existing ->
        {:reply, {:ok, existing}, state}
    end
  end

  def handle_call({:delivered, key}, _from, state) do
    receipt = Map.fetch!(state.data["receipts"], key) |> Map.put("delivered", true)
    save(state, put_in(state.data, ["receipts", key], receipt), receipt)
  end

  defp import_orders(receipt, {:ok, rows}, orders) do
    if Enum.any?(rows, &Map.has_key?(orders, &1["order_id"])) do
      import_orders(receipt, {:error, ["An order_id already exists in another import."]}, orders)
    else
      receipt =
        Map.merge(receipt, %{"outcome" => "imported", "count" => length(rows), "errors" => []})

      {receipt, Map.merge(orders, Map.new(rows, &{&1["order_id"], &1}))}
    end
  end

  defp import_orders(receipt, {:error, errors}, orders) do
    {Map.merge(receipt, %{"outcome" => "rejected", "count" => 0, "errors" => errors}), orders}
  end

  defp save(state, data, result) do
    # A receipt and its orders must survive a restart together.
    temporary = state.path <> ".pending"

    result_write =
      with :ok <- File.write(temporary, Jason.encode_to_iodata!(data), [:sync]),
           :ok <- File.rename(temporary, state.path),
           do: :ok

    case result_write do
      :ok -> {:reply, {:ok, result}, %{state | data: data}}
      {:error, reason} -> {:reply, {:error, {:journal_write, reason}}, state}
    end
  end
end
