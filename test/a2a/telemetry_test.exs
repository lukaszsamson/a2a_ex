defmodule A2A.TelemetryTest do
  use ExUnit.Case, async: false

  setup do
    handler_id = "a2a-telemetry-test-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach_many(
        handler_id,
        [
          [:a2a, :client, :request, :start],
          [:a2a, :client, :request, :stop],
          [:a2a, :client, :request, :exception]
        ],
        fn event, measurements, metadata, _ ->
          send(test_pid, {:telemetry_event, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end

  test "emits start and stop events for successful span" do
    result = A2A.Telemetry.span([:a2a, :client, :request], %{transport: :rest}, fn -> :ok end)

    assert result == :ok

    assert_receive {:telemetry_event, [:a2a, :client, :request, :start],
                    %{system_time: system_time}, %{transport: :rest}}

    assert is_integer(system_time)

    assert_receive {:telemetry_event, [:a2a, :client, :request, :stop], %{duration: duration},
                    %{transport: :rest}}

    assert is_integer(duration)
    assert duration >= 0
  end

  test "emits exception event and reraises" do
    assert_raise RuntimeError, "boom", fn ->
      A2A.Telemetry.span([:a2a, :client, :request], %{transport: :jsonrpc}, fn ->
        raise "boom"
      end)
    end

    assert_receive {:telemetry_event, [:a2a, :client, :request, :start], _measurements,
                    %{transport: :jsonrpc}}

    assert_receive {:telemetry_event, [:a2a, :client, :request, :exception],
                    %{duration: duration},
                    %{transport: :jsonrpc, error: %RuntimeError{message: "boom"}}}

    assert is_integer(duration)
    assert duration >= 0
  end
end
