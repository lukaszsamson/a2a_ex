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
end
