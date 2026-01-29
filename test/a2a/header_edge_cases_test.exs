defmodule A2A.HeaderEdgeCasesTest do
  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn

  test "parses extension header with commas and whitespace" do
    header = " urn:one, urn:two  urn:three ,"
    assert A2A.Extension.parse_header(header) == ["urn:one", "urn:two", "urn:three"]
  end

  test "parses extension header list" do
    headers = ["urn:one,urn:two", "urn:three"]
    assert A2A.Extension.parse_header(headers) == ["urn:one", "urn:two", "urn:three"]
  end

  test "missing_required ignores duplicates" do
    requested = ["urn:one", "urn:one", "urn:two"]
    assert A2A.Extension.missing_required(requested, ["urn:two", "urn:three"]) == ["urn:three"]
  end

  test "accepts a2a-version 0.3 and 0.3.0" do
    conn = conn(:get, "/") |> put_req_header("a2a-version", "0.3")
    assert :ok = A2A.Server.Headers.validate_version(conn, :latest)

    conn = conn(:get, "/") |> put_req_header("a2a-version", "0.3.0")
    assert :ok = A2A.Server.Headers.validate_version(conn, :latest)
  end

  test "rejects a2a-version with unsupported patch" do
    conn = conn(:get, "/") |> put_req_header("a2a-version", "0.3.1")

    assert {:error, %A2A.Error{type: :version_not_supported}} =
             A2A.Server.Headers.validate_version(conn, :latest)
  end
end
