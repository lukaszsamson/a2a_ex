defmodule A2A.Telemetry do
  @moduledoc """
  Minimal telemetry helper for recording spans.
  """

  @spec span([atom()], map(), (-> term())) :: term()
  def span(prefix, metadata, fun) when is_list(prefix) and is_function(fun, 0) do
    start_time = System.monotonic_time()

    :telemetry.execute(prefix ++ [:start], %{system_time: System.system_time()}, metadata)

    try do
      result = fun.()
      duration = System.monotonic_time() - start_time
      :telemetry.execute(prefix ++ [:stop], %{duration: duration}, metadata)
      result
    rescue
      exception ->
        duration = System.monotonic_time() - start_time

        :telemetry.execute(
          prefix ++ [:exception],
          %{duration: duration},
          Map.put(metadata, :error, exception)
        )

        reraise exception, __STACKTRACE__
    end
  end
end
