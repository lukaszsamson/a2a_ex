defmodule A2A.ErrorJSONRPCMapTest do
  use ExUnit.Case, async: true

  test "maps jsonrpc error data" do
    error_map = %{
      "code" => -32000,
      "message" => "Error",
      "data" => %{"type" => "VersionNotSupportedError", "message" => "Unsupported"}
    }

    error = A2A.Error.from_map(error_map)
    assert error.type == :version_not_supported
  end

  test "unwraps nested error data" do
    error_map = %{
      "code" => -32000,
      "message" => "Error",
      "data" => %{"error" => %{"type" => "TaskNotFoundError", "message" => "Missing"}}
    }

    error = A2A.Error.from_map(error_map)
    assert error.type == :task_not_found
    assert error.message == "Missing"
  end

  test "extracts nested payload data" do
    error_map = %{
      "code" => -32000,
      "message" => "Error",
      "data" => %{
        "type" => "UnauthorizedError",
        "message" => "Unauthorized",
        "data" => %{"scope" => "tasks"},
        "retryable" => true
      }
    }

    error = A2A.Error.from_map(error_map)
    assert error.type == :unauthorized
    assert error.data == %{"scope" => "tasks"}
    assert error.retryable?
  end

  test "uses canonical v1 HTTP status mappings" do
    assert A2A.Error.http_status(A2A.Error.new(:task_not_found, "missing"), :v1_0) == 404
    assert A2A.Error.http_status(A2A.Error.new(:task_not_cancelable, "terminal"), :v1_0) == 400

    assert A2A.Error.http_status(
             A2A.Error.new(:content_type_not_supported, "unsupported"),
             :v1_0
           ) == 400

    assert A2A.Error.http_status(A2A.Error.new(:invalid_agent_response, "invalid"), :v1_0) ==
             500
  end
end
