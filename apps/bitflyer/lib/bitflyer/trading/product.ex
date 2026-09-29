defmodule Bitflyer.Trading.Product do
  @moduledoc """
  銘柄コードから基軸・決済通貨と市場種別を取り出す。

  live の残高モデルは現物（`getbalance`）のみ。FX/CFD の資金正本は `getcollateral`。
  1 単位あたりの必要証拠金は未実測なので、live の FX 発注は出さない。
  起動と認可は、さらに手数料単位の一次証跡がある銘柄（`live_evidenced?/1`）だけを通す。
  当面は `BTC_JPY` と `ETH_JPY`。spot allowlist の他ペアは paper の手数料モデル用で、
  実測表を足すまで live では通さない。
  発注数量の刻みと最小数量は残高・commission の桁とは別（`check_order_size/2`）である。
  """

  @type market_type :: :spot | :fx | :unsupported

  # bitFlyer Lightning 現物。ここに無い BASE_QUOTE は :unsupported（安易に spot 扱いしない）。
  @spot_products MapSet.new([
                   "BTC_JPY",
                   "ETH_JPY",
                   "XRP_JPY",
                   "XLM_JPY",
                   "MONA_JPY",
                   "BCH_JPY",
                   "ETH_BTC",
                   "BCH_BTC"
                 ])

  @spec quote_currency(String.t()) :: String.t()
  def quote_currency("FX_BTC_JPY"), do: "JPY"
  def quote_currency("BTC_JPY"), do: "JPY"

  def quote_currency(product_code) when is_binary(product_code) do
    product_code
    |> String.split("_")
    |> List.last()
    |> String.split("-")
    |> List.first()
  end

  @spec base_currency(String.t()) :: String.t()
  def base_currency("FX_BTC_JPY"), do: "BTC"
  def base_currency("BTC_JPY"), do: "BTC"

  def base_currency(product_code) when is_binary(product_code) do
    parts = String.split(product_code, "_")

    parts
    |> Enum.at(max(length(parts) - 2, 0))
    |> String.split("-")
    |> List.first()
  end

  @doc """
  銘柄の市場種別。

  - `:spot` — allowlist の現物（残高は getbalance）。既定運用は `BTC_JPY`
  - `:fx` — `FX_*`（証拠金。live 未対応）
  - `:unsupported` — 先物・未登録ペア等
  """
  @spec market_type(String.t()) :: market_type()
  def market_type(<<"FX_", _::binary>>), do: :fx

  def market_type(product_code) when is_binary(product_code) do
    if MapSet.member?(@spot_products, product_code) do
      :spot
    else
      :unsupported
    end
  end

  @spec spot?(String.t()) :: boolean()
  def spot?(product_code) when is_binary(product_code), do: market_type(product_code) == :spot

  # 買い・売りの commission 実測（commission-unit-evidence.md）がある銘柄。
  # 他ペアは実測表を足してからこの集合へ入れる。spot? 全体は live で通さない。
  @live_evidenced_products MapSet.new(["BTC_JPY", "ETH_JPY"])

  # ETH_JPY の売り下限は取引所最小 0.01、刻みは 2026-09-29 の拒否文（0.0000001）。
  # 買い下限は公表手数料 0.15% のあと、刻みへ切った売りが 0.01 以上になる最小。0.01 ちょうどは売れ残る。
  # BTC_JPY の建玉 / 1.0015 は循環小数で、拒否単位は未測定。ゲートには入れない。
  @eth_step Decimal.new("0.0000001")
  @eth_sell_min Decimal.new("0.01")
  @eth_buy_min Decimal.new("0.0100301")
  @order_grids %{
    "ETH_JPY" => %{step: @eth_step, min: @eth_sell_min, buy_min: @eth_buy_min}
  }

  @doc """
  live 起動と認可で通す銘柄か。

  `spot?/1` より狭い。手数料の一次証跡がある `BTC_JPY` と `ETH_JPY`。
  """
  @spec live_evidenced?(String.t()) :: boolean()
  def live_evidenced?(product_code) when is_binary(product_code) do
    MapSet.member?(@live_evidenced_products, product_code)
  end

  # Lightning 現物の公表上限（約定数量 × 0.15%）。口座の実レートはこれ以下。
  # 認可はこの率で base を多めに拘束し、全量売りが insufficient_funds になるのを拒む。
  # BTC_JPY と ETH_JPY の実測は 0.15%。他ペアの単位は未実測で、余白だけ先に天井へ揃える。
  @max_spot_fee_rate Decimal.new("0.0015")

  @doc """
  現物の公表手数料率の上限（0.15%）。認可の売り余白に使う。
  """
  @spec max_spot_fee_rate() :: Decimal.t()
  def max_spot_fee_rate, do: @max_spot_fee_rate

  @doc """
  売りが base 残高から落とす量。

  spot で手数料通貨が base のとき `size + size × 公表上限`。
  約定前は実 commission が無いので、不足側に倒す。FX と quote 建は `size`。

  口座レートが 0.15% 未満だと、約定はそれより小さい `size + 実手数料` しか建玉を減らさない。
  残りが最小数量（BTC_JPY は 0.001）を下回ると次の売りは余白不足で通らず、long が残る。
  2026-09-28 の実測口座はちょうど 0.15% なので、`size = 建玉 / 1.0015` で平坦にできる。
  """
  @spec sell_base_debit(String.t(), Decimal.t()) :: Decimal.t()
  def sell_base_debit(product_code, %Decimal{} = size) when is_binary(product_code) do
    if spot?(product_code) and fee_currency(product_code) == base_currency(product_code) do
      Decimal.add(size, Decimal.mult(size, @max_spot_fee_rate))
    else
      size
    end
  end

  @spec fx?(String.t()) :: boolean()
  def fx?(product_code) when is_binary(product_code), do: market_type(product_code) == :fx

  @doc """
  getexecutions の `commission` の通貨。

  公式手数料表は Lightning 現物を「単位は通貨ペアで異なる / Unit varies by Crypto Assets」
  とし、かんたん取引所の BTC は Unit: BTC。API 自体は単位を返さないため product で決める。

  - `:spot` — 当面 base。BTC_JPY は 2026-09-28、ETH_JPY は 2026-09-29 の実測で、
    買い `+S−C` / `−S·P`、売り `−(S+C)` / `+S·P`。ほかの spot はペア別の非ゼロ
    execution が無く、同じ式は仮定である。認可の売り余白は公表上限（`max_spot_fee_rate/0`）を使う
  - `:fx` — quote（証拠金。live 未対応。paper 経路の互換）
  - その他 — quote
  """
  @spec fee_currency(String.t()) :: String.t()
  def fee_currency(product_code) when is_binary(product_code) do
    case market_type(product_code) do
      :spot -> base_currency(product_code)
      _ -> quote_currency(product_code)
    end
  end

  @doc """
  発注数量が銘柄の刻み上にあり、最小数量以上か。

  規則の無い銘柄は `:ok`（未実測。BTC_JPY の建玉割り数量もここ）。
  刻みから外れた数量は切り詰めず `:off_order_step`。
  """
  @spec check_order_size(String.t(), Decimal.t()) ::
          :ok | {:error, :invalid_order_size | :off_order_step | :below_min_order_size}
  def check_order_size(product_code, %Decimal{} = size) when is_binary(product_code) do
    cond do
      not Decimal.positive?(size) ->
        {:error, :invalid_order_size}

      grid = order_grid(product_code) ->
        check_grid(size, grid)

      true ->
        :ok
    end
  end

  @doc """
  発注数量を銘柄の刻みへ切り捨てる。

  結果が最小数量未満なら `{:error, :below_min_order_size}`。規則の無い銘柄は
  `{:error, :order_grid_missing}`。
  """
  @spec align_order_size(String.t(), Decimal.t()) ::
          {:ok, Decimal.t()}
          | {:error, :invalid_order_size | :below_min_order_size | :order_grid_missing}
  def align_order_size(product_code, %Decimal{} = size) when is_binary(product_code) do
    cond do
      not Decimal.positive?(size) ->
        {:error, :invalid_order_size}

      grid = order_grid(product_code) ->
        aligned = floor_to_step(size, grid.step)

        if Decimal.compare(aligned, grid.min) == :lt do
          {:error, :below_min_order_size}
        else
          {:ok, aligned}
        end

      true ->
        {:error, :order_grid_missing}
    end
  end

  defp order_grid(product_code) when is_binary(product_code) do
    Map.get(@order_grids, product_code)
  end

  defp check_grid(size, %{step: step, min: min}) do
    cond do
      Decimal.compare(size, min) == :lt ->
        {:error, :below_min_order_size}

      not Decimal.equal?(floor_to_step(size, step), size) ->
        {:error, :off_order_step}

      true ->
        :ok
    end
  end

  defp floor_to_step(%Decimal{} = size, %Decimal{} = step) do
    size
    |> Decimal.div_int(step)
    |> Decimal.mult(step)
  end

  @doc """
  建玉から、手数料余白を残して刻みへ切り捨てた売り数量。

  `held / 1.0015` を `align_order_size/2` する。規則の無い銘柄は
  `{:error, :order_grid_missing}`。
  """
  @spec sellable_size(String.t(), Decimal.t()) ::
          {:ok, Decimal.t()}
          | {:error, :invalid_order_size | :below_min_order_size | :order_grid_missing}
  def sellable_size(product_code, %Decimal{} = held) when is_binary(product_code) do
    raw = Decimal.div(held, Decimal.add(Decimal.new("1"), @max_spot_fee_rate))
    align_order_size(product_code, raw)
  end

  @doc """
  買いが、公表上限の手数料のあと売れる建玉を残すか。

  `size × (1 − 0.15%)` を `sellable_size/2` する。刻みの無い銘柄と売りは `:ok`。
  見るのは発注した全量だけ。部分約定で売り最小を下回った余りは、この認可では止めない。
  その余りの売りは刻みと最小で拒否する。
  """
  @spec ensure_buy_can_flatten(String.t(), :buy | :sell, Decimal.t()) ::
          :ok | {:error, :below_min_order_size | :invalid_order_size | :order_grid_missing}
  def ensure_buy_can_flatten(product_code, side, %Decimal{} = size)
      when is_binary(product_code) and side in [:buy, :sell] do
    cond do
      side != :buy ->
        :ok

      order_grid(product_code) ->
        held = Decimal.mult(size, Decimal.sub(Decimal.new("1"), @max_spot_fee_rate))

        case sellable_size(product_code, held) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, reason}
        end

      true ->
        :ok
    end
  end

  @doc """
  購読銘柄の base / quote。live の必須残高へ足す。
  """
  @spec balance_currencies([String.t()]) :: [String.t()]
  def balance_currencies(product_codes) when is_list(product_codes) do
    Enum.flat_map(product_codes, fn code ->
      code = to_string(code)
      [base_currency(code), quote_currency(code)]
    end)
  end

  @doc false
  def spot_products, do: MapSet.to_list(@spot_products)

  @doc false
  def live_evidenced_products, do: Enum.sort(@live_evidenced_products)
end
