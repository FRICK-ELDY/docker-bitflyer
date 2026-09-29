defmodule Bitflyer.Startup.LiveCollateral do
  @moduledoc """
  live FX の証拠金検査。

  正本は `getcollateral`。建玉が無く必要証拠金が 0 のときは維持率 0 でも止めない
  （2026-09-29 の空口座）。必要証拠金があるのに維持率が下限未満、または追証が
  出ていれば `keep_rate_breached` / `margin_call`。
  """

  @default_min_keep_rate "1"

  @type collateral :: %{
          collateral: Decimal.t(),
          open_position_pnl: Decimal.t(),
          require_collateral: Decimal.t(),
          keep_rate: Decimal.t(),
          margin_call_amount: Decimal.t(),
          margin_call_due_date: term()
        }

  @doc """
  購読に FX が含まれるときだけ証拠金を検査する。spot だけの snapshot は通す。
  """
  @spec for_products(map(), [String.t()]) :: :ok | {:error, :reconcile_mismatch, map()}
  def for_products(snapshot, product_codes) when is_map(snapshot) and is_list(product_codes) do
    if Enum.any?(product_codes, &Bitflyer.Trading.Product.fx?/1) do
      case Map.get(snapshot, :collateral) do
        %{} = collateral ->
          check(collateral, positions: Map.get(snapshot, :positions, []))

        _ ->
          {:error, :reconcile_mismatch, %{kind: :collateral_missing}}
      end
    else
      :ok
    end
  end

  @doc """
  証拠金が live を続けてよいか。

  `min_keep_rate`（既定 1）は公式ロスカット線ではない。
  `(collateral + open_position_pnl) / require_collateral` が 1 を超える余力を、
  当方の停止線にする。1 ちょうども止める。取引所のロスカット比率は未実測。

  建玉があるのに必要証拠金が 0 以下なら止める。追証額または追証期限があれば止める。
  キーが欠けると `collateral_missing`。下限の形式が不正なら `invalid_min_keep_rate`。
  """
  @spec check(map(), keyword()) :: :ok | {:error, :reconcile_mismatch, map()}
  def check(collateral, opts \\ []) when is_map(collateral) do
    with {:ok, fields} <- fields(collateral),
         {:ok, min_keep} <- min_keep_rate(opts) do
      due =
        Map.get(collateral, :margin_call_due_date) || Map.get(collateral, "margin_call_due_date")

      judge(fields, min_keep, Keyword.get(opts, :positions, []), due)
    end
  end

  defp fields(collateral) do
    keys = [:collateral, :open_position_pnl, :require_collateral, :keep_rate, :margin_call_amount]

    Enum.reduce_while(keys, {:ok, %{}}, fn key, {:ok, acc} ->
      case Map.fetch(collateral, key) do
        {:ok, %Decimal{} = value} -> {:cont, {:ok, Map.put(acc, key, value)}}
        _ -> {:halt, {:error, :reconcile_mismatch, %{kind: :collateral_missing, field: key}}}
      end
    end)
  end

  defp judge(fields, min_keep, positions, due) do
    require_collateral = fields.require_collateral
    margin_call_amount = fields.margin_call_amount
    open? = open_position?(positions)

    cond do
      Decimal.compare(margin_call_amount, 0) == :gt or due_date?(due) ->
        halt(:margin_call, fields, min_keep)

      Decimal.compare(require_collateral, 0) != :gt and open? ->
        halt(:keep_rate_breached, fields, min_keep)

      Decimal.compare(require_collateral, 0) == :gt and
          Decimal.compare(effective_keep(fields), min_keep) != :gt ->
        halt(:keep_rate_breached, fields, min_keep)

      true ->
        :ok
    end
  end

  defp due_date?(nil), do: false
  defp due_date?(""), do: false
  defp due_date?(value) when is_binary(value), do: String.trim(value) != ""
  defp due_date?(_), do: true

  defp effective_keep(fields) do
    equity = Decimal.add(fields.collateral, fields.open_position_pnl)
    computed = Decimal.div(equity, fields.require_collateral)

    if Decimal.compare(fields.keep_rate, computed) == :lt do
      fields.keep_rate
    else
      computed
    end
  end

  defp open_position?(positions) when is_list(positions) do
    Enum.any?(positions, fn row ->
      code = Map.get(row, :product_code) || Map.get(row, "product_code")
      size = Map.get(row, :size) || Map.get(row, "size")

      fx_position?(code) and match?(%Decimal{}, size) and Decimal.compare(size, 0) == :gt
    end)
  end

  defp open_position?(_), do: false

  defp fx_position?(code) when is_binary(code), do: Bitflyer.Trading.Product.fx?(code)
  defp fx_position?(_), do: false

  defp halt(kind, fields, min_keep) do
    {:error, :reconcile_mismatch,
     %{
       kind: kind,
       keep_rate: fields.keep_rate,
       min_keep_rate: min_keep,
       require_collateral: fields.require_collateral,
       margin_call_amount: fields.margin_call_amount,
       open_position_pnl: fields.open_position_pnl
     }}
  end

  defp min_keep_rate(opts) do
    raw =
      Keyword.get_lazy(opts, :min_keep_rate, fn ->
        Application.get_env(:bitflyer, :fx_collateral, [])
        |> Keyword.get(:min_keep_rate, @default_min_keep_rate)
      end)

    case raw do
      %Decimal{} = value -> keep_positive(value)
      value when is_binary(value) -> parse_keep(value)
      value when is_integer(value) -> keep_positive(Decimal.new(value))
      _ -> {:error, :reconcile_mismatch, %{kind: :invalid_min_keep_rate}}
    end
  end

  defp parse_keep(value) do
    case Decimal.parse(String.trim(value)) do
      {%Decimal{} = decimal, ""} -> keep_positive(decimal)
      _ -> {:error, :reconcile_mismatch, %{kind: :invalid_min_keep_rate}}
    end
  end

  defp keep_positive(%Decimal{} = value) do
    if Decimal.compare(value, 0) == :gt do
      {:ok, value}
    else
      {:error, :reconcile_mismatch, %{kind: :invalid_min_keep_rate, min_keep_rate: value}}
    end
  end
end
