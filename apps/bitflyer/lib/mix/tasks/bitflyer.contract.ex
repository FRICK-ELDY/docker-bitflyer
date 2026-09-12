defmodule Mix.Tasks.Bitflyer.Contract do
  @moduledoc """
  bitFlyer の read-only 契約検査。発注・取消はしない。

      mix bitflyer.contract
      mix bitflyer.contract --product-code=BTC_JPY
      mix bitflyer.contract --corpus
      mix bitflyer.contract --write-corpus --corpus-dir=/tmp/bitflyer-contract-corpus
      mix bitflyer.contract --private

  公開 GET はキー不要。`--private` は署名 GET（権限・突合 snapshot）のみ。
  POST（send/cancel）は呼ばない。
  """

  use Mix.Task

  @shortdoc "Read-only bitFlyer API contract (no place/cancel)"

  @impl Mix.Task
  def run(args) do
    {parsed, _argv, invalid} =
      OptionParser.parse(args,
        strict: [
          product_code: :string,
          private: :boolean,
          write_corpus: :boolean,
          corpus: :boolean,
          base_url: :string,
          corpus_dir: :string
        ]
      )

    if invalid != [] do
      Mix.shell().error("invalid options: #{inspect(invalid)}")
      System.halt(1)
    end

    Mix.Task.run("app.start")

    cond do
      Keyword.get(parsed, :corpus, false) ->
        finish(Bitflyer.System.contract_corpus(corpus_opts(parsed)))

      true ->
        finish(Bitflyer.System.contract_probe(probe_opts(parsed)))
    end
  end

  defp probe_opts(parsed) do
    [
      product_code: Keyword.get(parsed, :product_code, "BTC_JPY"),
      private?: Keyword.get(parsed, :private, false),
      write_corpus?: Keyword.get(parsed, :write_corpus, false)
    ]
    |> maybe_put(:base_url, Keyword.get(parsed, :base_url))
    |> maybe_put(:corpus_dir, Keyword.get(parsed, :corpus_dir))
  end

  defp corpus_opts(parsed) do
    [product_code: Keyword.get(parsed, :product_code, "BTC_JPY")]
    |> maybe_put(:corpus_dir, Keyword.get(parsed, :corpus_dir))
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp finish({:ok, report}) do
    Mix.shell().info(format_report(report))
    :ok
  end

  defp finish({:error, report}) do
    Mix.shell().error(format_report(report))
    System.halt(1)
  end

  defp format_report(%{public: public} = report) do
    lines =
      [
        "contract product_code=#{report.product_code}",
        format_checks("public", public),
        format_private(Map.get(report, :private, :skipped))
      ]

    Enum.join(Enum.reject(lines, &is_nil/1), "\n")
  end

  defp format_report(checks) when is_list(checks) do
    format_checks("corpus", checks)
  end

  defp format_checks(label, checks) do
    rendered =
      Enum.map_join(checks, "\n", fn check ->
        case check.status do
          :ok -> "  ok   #{check.name}"
          :error -> "  fail #{check.name} reason=#{inspect(check.reason)}"
        end
      end)

    "#{label}:\n#{rendered}"
  end

  defp format_private(:skipped), do: "private: skipped"
  defp format_private(checks) when is_list(checks), do: format_checks("private", checks)
end
