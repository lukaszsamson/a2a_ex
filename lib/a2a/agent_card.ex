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
    version = Keyword.get(opts, :version, :v0_3)
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

  defp missing_fields(%A2A.Types.AgentCard{} = card, :latest) do
    []
    |> maybe_add_missing(is_nil(card.name), "name")
    |> maybe_add_missing(is_nil(card.capabilities), "capabilities")
    |> maybe_add_missing(
      !valid_supported_interfaces?(card.supported_interfaces),
      "supportedInterfaces"
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
    url = Map.get(interface, :url) || Map.get(interface, "url")
    is_binary(binding) and is_binary(url)
  end
end
