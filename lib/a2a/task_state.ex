defmodule A2A.TaskState do
  @moduledoc """
  Encodes and decodes task status values.
  """

  @type t ::
          :submitted
          | :working
          | :input_required
          | :auth_required
          | :completed
          | :canceled
          | :rejected
          | :failed
          | :unknown
          | {:unknown, String.t()}

  @v0_3_map %{
    submitted: "submitted",
    working: "working",
    input_required: "input-required",
    auth_required: "auth-required",
    completed: "completed",
    canceled: "canceled",
    rejected: "rejected",
    failed: "failed",
    unknown: "unknown"
  }

  @latest_map %{
    submitted: "TASK_STATE_SUBMITTED",
    working: "TASK_STATE_WORKING",
    input_required: "TASK_STATE_INPUT_REQUIRED",
    auth_required: "TASK_STATE_AUTH_REQUIRED",
    completed: "TASK_STATE_COMPLETED",
    canceled: "TASK_STATE_CANCELLED",
    rejected: "TASK_STATE_REJECTED",
    failed: "TASK_STATE_FAILED",
    unknown: "TASK_STATE_UNKNOWN"
  }

  @spec encode(t() | nil, keyword()) :: String.t() | nil
  def encode(state, opts \\ [])
  def encode(nil, _opts), do: nil

  def encode({:unknown, value}, _opts), do: value

  def encode(state, opts) do
    version = A2A.Types.version_from_opts(opts)

    case version do
      :latest -> Map.get(@latest_map, state, Atom.to_string(state))
      _ -> Map.get(@v0_3_map, state, Atom.to_string(state))
    end
  end

  @spec decode(String.t() | nil, keyword()) :: t() | nil
  def decode(value, opts \\ [])
  def decode(nil, _opts), do: nil

  def decode(value, _opts) when value in ["canceled", "cancelled", "TASK_STATE_CANCELLED"] do
    :canceled
  end

  def decode(value, _opts) when value in ["auth-required", "TASK_STATE_AUTH_REQUIRED"] do
    :auth_required
  end

  def decode(value, _opts) when value in ["input-required", "TASK_STATE_INPUT_REQUIRED"] do
    :input_required
  end

  def decode(value, _opts) when value in ["submitted", "TASK_STATE_SUBMITTED"] do
    :submitted
  end

  def decode(value, _opts) when value in ["working", "TASK_STATE_WORKING"] do
    :working
  end

  def decode(value, _opts) when value in ["completed", "TASK_STATE_COMPLETED"] do
    :completed
  end

  def decode(value, _opts) when value in ["rejected", "TASK_STATE_REJECTED"] do
    :rejected
  end

  def decode(value, _opts) when value in ["failed", "TASK_STATE_FAILED"] do
    :failed
  end

  def decode("unknown", _opts), do: :unknown
  def decode("TASK_STATE_UNKNOWN", _opts), do: :unknown
  def decode(value, _opts), do: {:unknown, value}

  @spec terminal?(t()) :: boolean()
  def terminal?(state) when state in [:completed, :canceled, :rejected, :failed], do: true
  def terminal?({:unknown, _}), do: false
  def terminal?(_), do: false
end
