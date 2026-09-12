defmodule ClassifyDepsAuditTest do
  use ExUnit.Case, async: true

  @script Path.expand("../../../../bin/classify-deps-audit.sh", __DIR__)
  @moduletag skip:
               is_nil(System.find_executable("bash")) &&
                 "bash is required; run via docker compose"

  test "clean json does not fail the gate" do
    {out, status} = classify(%{"pass" => true, "vulnerabilities" => []}, 0)
    assert status == 0
    assert out =~ "outcome=clean"
    assert out =~ "json_exit=0"
  end

  test "advisory detection fails the gate" do
    {out, status} =
      classify(%{"pass" => false, "vulnerabilities" => [%{"package" => "demo"}]}, 1)

    assert status == 1
    assert out =~ "outcome=vulnerabilities_found"
  end

  test "pass false with exit 0 still fails the gate" do
    {out, status} = classify(%{"pass" => false, "vulnerabilities" => []}, 0)
    assert status == 1
    assert out =~ "outcome=vulnerabilities_found"
  end

  test "pretty spaced json still detects advisories" do
    {out, status} =
      classify(
        """
        {
          "pass": false,
          "vulnerabilities": []
        }
        """,
        1
      )

    assert status == 1
    assert out =~ "outcome=vulnerabilities_found"
  end

  test "pretty spaced json still detects clean" do
    {out, status} =
      classify(
        """
        {
          "pass": true,
          "vulnerabilities": []
        }
        """,
        0
      )

    assert status == 0
    assert out =~ "outcome=clean"
  end

  test "empty file is tool failure and does not fail the gate" do
    {out, status} = classify("", 0)
    assert status == 0
    assert out =~ "outcome=audit_tool_or_fetch_failed"
  end

  test "missing file is tool failure and does not abort" do
    dir = Path.join(System.tmp_dir!(), "deps-audit-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    missing = Path.join(dir, "missing.json")
    meta = Path.join(dir, "meta.txt")

    {out, status} =
      System.cmd("bash", [@script, missing, "0", meta], stderr_to_stdout: true)

    assert status == 0
    assert out =~ "outcome=audit_tool_or_fetch_failed"
  end

  test "pass after other keys still fails the gate" do
    {out, status} =
      classify(~s({"vulnerabilities":[{"note":"mentions pass"}],"pass":false}), 0)

    assert status == 1
    assert out =~ "outcome=vulnerabilities_found"
  end

  test "pass false only inside a string is not an advisory" do
    {out, status} = classify(~s({"note":"{\\"pass\\":false}"}), 0)
    assert status == 0
    assert out =~ "outcome=audit_tool_or_fetch_failed"
  end

  test "tool or fetch failure does not fail the gate" do
    {out, status} = classify("not-json", 2)
    assert status == 0
    assert out =~ "outcome=audit_tool_or_fetch_failed"
    assert out =~ "json_exit=2"
  end

  test "usage error is exit 2" do
    {_, status} = System.cmd("bash", [@script], stderr_to_stdout: true)
    assert status == 2
  end

  defp classify(body, json_exit) do
    dir = Path.join(System.tmp_dir!(), "deps-audit-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    json_path = Path.join(dir, "deps-audit.json")
    meta_path = Path.join(dir, "deps-audit-meta.txt")

    bin = if is_binary(body), do: body, else: Jason.encode!(body)
    File.write!(json_path, bin)

    System.cmd(
      "bash",
      [@script, json_path, Integer.to_string(json_exit), meta_path],
      stderr_to_stdout: true
    )
  end
end
