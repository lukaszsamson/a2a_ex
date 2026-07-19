defmodule A2A.Protocol do
  @moduledoc """
  Selects a stable protocol adapter.

  Wire compatibility flags are intentionally scoped to the v0.3 adapter. The
  v1.0 adapter always uses the normative ProtoJSON representation.
  """

  @spec adapter(A2A.Types.version()) :: module()
  def adapter(version) do
    case A2A.Types.normalize_version(version) do
      :v0_3 -> A2A.Protocol.V0_3
      :v1_0 -> A2A.Protocol.V1_0
    end
  end

  @spec type_opts(A2A.Types.version(), A2A.Types.wire_format()) :: keyword()
  def type_opts(version, wire_format \\ :spec_json) do
    adapter(version).type_opts(wire_format)
  end
end

defmodule A2A.Protocol.V0_3 do
  @moduledoc "Legacy v0.3 compatibility adapter."

  def type_opts(wire_format), do: [version: :v0_3, wire_format: wire_format]

  def encode(module, value, wire_format \\ :spec_json),
    do: module.to_map(value, type_opts(wire_format))

  def decode(module, value, wire_format \\ :spec_json),
    do: module.from_map(value, type_opts(wire_format))
end

defmodule A2A.Protocol.V1_0 do
  @moduledoc """
  Normative A2A v1.0 ProtoJSON adapter configuration.

  This adapter deliberately ignores SDK compatibility wire formats.
  """

  def type_opts(_wire_format), do: [version: :v1_0]

  def encode(module, value), do: A2A.Protocol.V1_0.ProtoJSON.encode(module, value)
  def decode(module, value), do: A2A.Protocol.V1_0.ProtoJSON.decode(module, value)
end

defmodule A2A.Protocol.V1_0.ProtoJSON do
  @moduledoc """
  Stable A2A v1.0 ProtoJSON codec.

  SDK compatibility modes are deliberately not accepted by this module.
  """

  @opts [version: :v1_0]

  @spec encode(module(), struct()) :: map()
  def encode(module, value) do
    Code.ensure_loaded!(module)

    if function_exported?(module, :to_map, 2) do
      module.to_map(value, @opts)
    else
      module.to_map(value)
    end
  end

  @spec decode(module(), map()) :: struct()
  def decode(module, value) do
    Code.ensure_loaded!(module)

    if function_exported?(module, :from_map, 2) do
      module.from_map(value, @opts)
    else
      module.from_map(value)
    end
  end
end
