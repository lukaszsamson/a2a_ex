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

  test "metadata helpers read and write extension metadata" do
    metadata =
      %{}
      |> A2A.Extension.metadata_put("urn:example:ext", "enabled", true)
      |> A2A.Extension.metadata_put("urn:example:ext", "mode", "strict")

    assert A2A.Extension.metadata_get(metadata, "urn:example:ext", "enabled") == true
    assert A2A.Extension.metadata_get(metadata, "urn:example:ext", "mode") == "strict"
    assert A2A.Extension.metadata_get(metadata, "urn:missing", "value", "default") == "default"
  end

  test "format_header trims blanks and is idempotent with parse_header" do
    extensions = [" urn:one ", "", "urn:two", "  "]

    formatted = A2A.Extension.format_header(extensions)

    assert formatted == "urn:one, urn:two"
    assert A2A.Extension.parse_header(formatted) == ["urn:one", "urn:two"]
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
