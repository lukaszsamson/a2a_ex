defmodule A2A.AgentCard do
  @moduledoc """
  Helpers for verifying agent card signatures.
  """

  @spec verify_signatures(A2A.Types.AgentCard.t(), keyword()) :: :ok | {:error, A2A.Error.t()}
  def verify_signatures(%A2A.Types.AgentCard{signatures: nil}, _opts), do: :ok
  def verify_signatures(%A2A.Types.AgentCard{signatures: []}, _opts), do: :ok

  def verify_signatures(%A2A.Types.AgentCard{} = card, opts) do
    verifier = Keyword.get(opts, :verifier)

    if verifier do
      verify_with(card, verifier)
    else
      {:error, A2A.Error.new(:invalid_agent_response, "Signature verifier not configured")}
    end
  end

  defp verify_with(card, verifier) when is_function(verifier, 2) do
    verify_any(card, verifier)
  end

  defp verify_with(card, {module, fun}) do
    verify_any(card, fn card, signature -> apply(module, fun, [card, signature]) end)
  end

  defp verify_any(%A2A.Types.AgentCard{signatures: signatures} = card, verifier) do
    results = Enum.map(signatures, &verifier.(card, &1))

    if Enum.any?(results, &ok_result?/1) do
      :ok
    else
      {:error, A2A.Error.new(:invalid_agent_response, "Agent card signature verification failed")}
    end
  end

  defp ok_result?(:ok), do: true
  defp ok_result?({:ok, _}), do: true
  defp ok_result?(true), do: true
  defp ok_result?(_), do: false

  @spec validate(A2A.Types.AgentCard.t(), keyword()) :: :ok | {:error, A2A.Error.t()}
  def validate(%A2A.Types.AgentCard{} = card, opts \\ []) do
    version = opts |> Keyword.get(:version, :v0_3) |> A2A.Types.normalize_version()
    missing = missing_fields(card, version)

    if missing == [] do
      :ok
    else
      {:error,
       A2A.Error.new(
         :invalid_agent_response,
         "Agent card missing required fields: #{Enum.join(Enum.reverse(missing), ", ")}"
       )}
    end
  end

  defp missing_fields(%A2A.Types.AgentCard{} = card, :v1_0) do
    []
    |> maybe_add_missing(is_nil(card.name), "name")
    |> maybe_add_missing(is_nil(card.description), "description")
    |> maybe_add_missing(is_nil(card.version), "version")
    |> maybe_add_missing(is_nil(card.capabilities), "capabilities")
    |> maybe_add_missing(is_nil(card.default_input_modes), "defaultInputModes")
    |> maybe_add_missing(is_nil(card.default_output_modes), "defaultOutputModes")
    |> maybe_add_missing(is_nil(card.skills), "skills")
    |> maybe_add_missing(
      !valid_supported_interfaces?(card.supported_interfaces),
      "supportedInterfaces"
    )
    |> maybe_add_missing(
      !supports_v1?(card.supported_interfaces),
      "supportedInterfaces.protocolVersion=1.0"
    )
  end

  defp missing_fields(%A2A.Types.AgentCard{} = card, _version) do
    []
    |> maybe_add_missing(is_nil(card.name), "name")
    |> maybe_add_missing(is_nil(card.capabilities), "capabilities")
    |> maybe_add_missing(is_nil(card.url), "url")
  end

  defp maybe_add_missing(list, true, value), do: [value | list]
  defp maybe_add_missing(list, false, _), do: list

  defp valid_supported_interfaces?(interfaces) when is_list(interfaces) and interfaces != [] do
    Enum.all?(interfaces, &valid_interface?/1)
  end

  defp valid_supported_interfaces?(_), do: false

  defp valid_interface?(interface) do
    binding = Map.get(interface, :protocol_binding) || Map.get(interface, "protocolBinding")
    version = Map.get(interface, :protocol_version) || Map.get(interface, "protocolVersion")
    url = Map.get(interface, :url) || Map.get(interface, "url")
    uri = if is_binary(url), do: URI.parse(url), else: nil

    is_binary(binding) and binding != "" and is_binary(version) and
      Regex.match?(~r/^\d+\.\d+(?:\.\d+)?$/, version) and is_binary(url) and
      uri.scheme in ["http", "https"] and is_binary(uri.host)
  end

  defp supports_v1?(interfaces) when is_list(interfaces) do
    Enum.any?(interfaces, fn interface ->
      version = Map.get(interface, :protocol_version) || Map.get(interface, "protocolVersion")
      is_binary(version) and Regex.match?(~r/^1\.0(?:\.\d+)?$/, version)
    end)
  end

  defp supports_v1?(_), do: false
end
