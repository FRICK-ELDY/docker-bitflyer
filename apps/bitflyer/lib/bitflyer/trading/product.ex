defmodule Bitflyer.Trading.Product do
  @moduledoc """
  銘柄コードから基軸・決済通貨と市場種別を取り出す。

  live の残高モデルは現物（`getbalance`）のみ。FX/CFD（`getcollateral`）は未実装のため、
  live 対象は allowlist の `:spot` に限定する（improvement-plan P0 #2 B）。
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

  # Lightning 現物の公表上限（約定数量 × 0.15%）。口座の実レートはこれ以下。
  # 認可はこの率で base を多めに拘束し、全量売りが insufficient_funds になるのを拒む。
  # BTC_JPY の実測は 0.15%。他ペアの単位は未実測で、余白だけ先に天井へ揃える。
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

  - `:spot` — 当面 base。BTC_JPY は 2026-09-28 の実測で、買い `+S−C` / `−S·P`、
    売り `−(S+C)` / `+S·P`。`ETH_JPY` など他の spot はペア別の非ゼロ execution が
    無く、同じ式は仮定である。認可の売り余白は公表上限（`max_spot_fee_rate/0`）を使う
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

  @doc false
  def spot_products, do: MapSet.to_list(@spot_products)
end
