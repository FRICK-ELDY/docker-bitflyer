defmodule Bitflyer.OrderExecutor.Paper.FillPricing do
  @moduledoc """
  paper 約定価格の不利化（スリッページ + 手数料）。

  1 bps = 0.01%。買いは上方向、売りは下方向に適用し、過大楽観な損益を抑える。
  live / dry_run では使わない。

  - 成行: slippage + fee
  - 指値: 交差後の指値に **fee のみ**（スリッページ無し。指値より悪い約定を避ける）
  """

  require Logger

  @type side :: :buy | :sell

  # 片道 50% 超は設定ミスとみなす（sell が非正になりうる）
  @max_bps Decimal.new("5000")

  @doc """
  基準価格に bps を重ねた約定価格。

  オプションで `:slippage_bps` / `:fee_bps` を渡せる。省略時は Application env。
  """
  @spec effective_price(side(), Decimal.t(), keyword()) ::
          {:ok, Decimal.t()} | {:error, atom(), map()}
  def effective_price(side, base_price, opts \\ [])

  def effective_price(side, %Decimal{} = base_price, opts) when side in [:buy, :sell] do
    with :ok <- validate_base(base_price),
         {:ok, slippage_bps} <- resolve_bps(opts, :slippage_bps),
         {:ok, fee_bps} <- resolve_bps(opts, :fee_bps),
         {:ok, after_slip} <- adverse_adjust(base_price, side, slippage_bps),
         {:ok, after_fee} <- adverse_adjust(after_slip, side, fee_bps) do
      {:ok, after_fee}
    end
  end

  def effective_price(_side, _base_price, _opts) do
    {:error, :invalid_fill_pricing, %{reason: :invalid_base}}
  end

  @doc """
  指値交差後の約定価格（fee のみ。スリッページは掛けない）。
  """
  @spec limit_fill_price(side(), Decimal.t(), keyword()) ::
          {:ok, Decimal.t()} | {:error, atom(), map()}
  def limit_fill_price(side, %Decimal{} = limit_price, opts \\ []) when side in [:buy, :sell] do
    effective_price(side, limit_price, Keyword.put(opts, :slippage_bps, Decimal.new(0)))
  end

  @doc false
  @spec slippage_bps() :: Decimal.t()
  def slippage_bps do
    case resolve_bps([], :slippage_bps) do
      {:ok, d} -> d
      {:error, _, _} -> Decimal.new(0)
    end
  end

  @doc false
  @spec fee_bps() :: Decimal.t()
  def fee_bps do
    case resolve_bps([], :fee_bps) do
      {:ok, d} -> d
      {:error, _, _} -> Decimal.new(0)
    end
  end

  defp validate_base(%Decimal{} = base_price) do
    if Decimal.positive?(base_price) do
      :ok
    else
      {:error, :invalid_fill_pricing, %{reason: :non_positive_base, base: base_price}}
    end
  end

  defp adverse_adjust(price, side, %Decimal{} = bps) do
    if Decimal.compare(bps, Decimal.new(0)) == :eq do
      {:ok, price}
    else
      rate = Decimal.div(bps, Decimal.new(10_000))

      factor =
        case side do
          :buy -> Decimal.add(Decimal.new(1), rate)
          :sell -> Decimal.sub(Decimal.new(1), rate)
        end

      if Decimal.positive?(factor) do
        {:ok, Decimal.mult(price, factor)}
      else
        {:error, :invalid_fill_pricing, %{reason: :non_positive_factor, side: side, bps: bps}}
      end
    end
  end

  defp resolve_bps(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, raw} ->
        parse_bps(raw, key)

      :error ->
        Application.get_env(:bitflyer, Bitflyer.OrderExecutor.Paper, [])
        |> Keyword.get(key, "0")
        |> parse_bps(key)
    end
  end

  defp parse_bps(%Decimal{} = d, key), do: validate_bps_range(d, key)

  defp parse_bps(v, key) when is_binary(v) do
    case Decimal.parse(v) do
      {d, ""} ->
        validate_bps_range(d, key)

      _ ->
        Logger.warning("invalid paper #{key}=#{inspect(v)}; refusing fill pricing")
        {:error, :invalid_fill_pricing, %{reason: :invalid_bps, key: key, value: v}}
    end
  end

  defp parse_bps(v, key) when is_integer(v), do: parse_bps(Decimal.new(v), key)

  defp parse_bps(v, key) do
    Logger.warning("invalid paper #{key}=#{inspect(v)}; refusing fill pricing")
    {:error, :invalid_fill_pricing, %{reason: :invalid_bps, key: key, value: v}}
  end

  defp validate_bps_range(%Decimal{} = d, key) do
    cond do
      Decimal.compare(d, Decimal.new(0)) == :lt ->
        Logger.warning("negative paper #{key}=#{Decimal.to_string(d)}; refusing fill pricing")
        {:error, :invalid_fill_pricing, %{reason: :negative_bps, key: key, value: d}}

      Decimal.compare(d, @max_bps) == :gt ->
        Logger.warning(
          "paper #{key}=#{Decimal.to_string(d)} exceeds max #{Decimal.to_string(@max_bps)}; refusing"
        )

        {:error, :invalid_fill_pricing, %{reason: :bps_too_large, key: key, value: d}}

      true ->
        {:ok, d}
    end
  end
end
