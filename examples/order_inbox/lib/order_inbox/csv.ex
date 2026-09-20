defmodule OrderInbox.CSV do
  @moduledoc "Parses one order per CSV row. A bad row rejects the whole file."
  @header ["order_id", "sku", "quantity"]

  def parse(body) do
    case NimbleCSV.RFC4180.parse_string(body, skip_headers: false) do
      [@header | [_ | _] = rows] -> validate(rows)
      [@header] -> {:error, ["The file contains no orders."]}
      _ -> {:error, ["Expected header: order_id,sku,quantity."]}
    end
  rescue
    _ in [NimbleCSV.ParseError, ArgumentError] -> {:error, ["Invalid CSV encoding or quoting."]}
  end

  defp validate(rows) do
    Enum.with_index(rows, 2)
    |> Enum.reduce_while({:ok, [], MapSet.new()}, fn {row, line}, {:ok, orders, ids} ->
      case order(row) do
        {:ok, order} ->
          if MapSet.member?(ids, order["order_id"]) do
            {:halt, {:error, ["Row #{line}: repeated order_id."]}}
          else
            {:cont, {:ok, [order | orders], MapSet.put(ids, order["order_id"])}}
          end

        :error ->
          {:halt,
           {:error,
            [
              "Row #{line}: use nonempty order_id and sku, and an integer quantity from 1 to 10000."
            ]}}
      end
    end)
    |> case do
      {:ok, orders, _} -> {:ok, Enum.reverse(orders)}
      error -> error
    end
  end

  defp order([id, sku, quantity]) do
    with true <- valid_text?(id) and valid_text?(sku),
         {number, ""} when number in 1..10_000 <- Integer.parse(quantity) do
      {:ok, %{"order_id" => id, "sku" => sku, "quantity" => number}}
    else
      _ -> :error
    end
  end

  defp order(_), do: :error

  defp valid_text?(text),
    do: String.valid?(text) and String.trim(text) != "" and byte_size(text) <= 100
end
