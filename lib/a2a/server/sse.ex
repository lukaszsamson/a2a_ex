defmodule A2A.Server.SSE do
  @moduledoc """
  Helpers for encoding Server-Sent Events payloads.
  """

  @spec encode_event(map()) :: String.t()
  def encode_event(payload) do
    json = Jason.encode!(payload)
    "data: " <> json <> "\n\n"
  end

  @spec encode_struct(struct(), keyword()) :: String.t()
  def encode_struct(struct, opts) do
    payload =
      case struct do
        %A2A.Types.StreamResponse{} ->
          A2A.Types.StreamResponse.to_map(struct, opts)

        %A2A.Types.Task{} ->
          A2A.Types.Task.to_map(struct, opts)

        %A2A.Types.Message{} ->
          A2A.Types.Message.to_map(struct, opts)

        %A2A.Types.TaskStatusUpdateEvent{} ->
          A2A.Types.TaskStatusUpdateEvent.to_map(struct, opts)

        %A2A.Types.TaskArtifactUpdateEvent{} ->
          A2A.Types.TaskArtifactUpdateEvent.to_map(struct, opts)

        map when is_map(map) ->
          map
      end

    encode_event(payload)
  end
end
