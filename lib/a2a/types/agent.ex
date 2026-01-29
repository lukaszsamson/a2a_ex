defmodule A2A.Types.AgentExtension do
  @moduledoc """
  Agent extension descriptor.
  """

  defstruct [:uri, :version, :required, :metadata, :raw]

  @type t :: %__MODULE__{}

  @spec from_map(map()) :: %__MODULE__{}
  def from_map(map) do
    %__MODULE__{
      uri: map["uri"],
      version: map["version"],
      required: map["required"],
      metadata: map["metadata"],
      raw: A2A.Types.drop_raw(map, ["uri", "version", "required", "metadata"])
    }
  end

  @spec to_map(%__MODULE__{}) :: map()
  def to_map(%__MODULE__{} = extension) do
    %{}
    |> A2A.Types.put_if("uri", extension.uri)
    |> A2A.Types.put_if("version", extension.version)
    |> A2A.Types.put_if("required", extension.required)
    |> A2A.Types.put_if("metadata", extension.metadata)
    |> A2A.Types.merge_raw(extension.raw)
  end
end

defmodule A2A.Types.AgentCapabilities do
  @moduledoc """
  Capabilities advertised by an agent.
  """

  defstruct [:streaming, :push_notifications, :extended_agent_card, :extensions, :raw]

  @type t :: %__MODULE__{}

  @spec from_map(nil | map()) :: %__MODULE__{} | nil
  def from_map(nil), do: nil

  def from_map(map) do
    %__MODULE__{
      streaming: map["streaming"],
      push_notifications: map["pushNotifications"],
      extended_agent_card: map["extendedAgentCard"],
      extensions: decode_extensions(map["extensions"]),
      raw:
        A2A.Types.drop_raw(map, [
          "streaming",
          "pushNotifications",
          "extendedAgentCard",
          "extensions"
        ])
    }
  end

  @spec to_map(nil | %__MODULE__{}) :: map() | nil
  def to_map(nil), do: nil

  def to_map(%__MODULE__{} = capabilities) do
    %{}
    |> A2A.Types.put_if("streaming", capabilities.streaming)
    |> A2A.Types.put_if("pushNotifications", capabilities.push_notifications)
    |> A2A.Types.put_if("extendedAgentCard", capabilities.extended_agent_card)
    |> A2A.Types.put_if("extensions", encode_extensions(capabilities.extensions))
    |> A2A.Types.merge_raw(capabilities.raw)
  end

  defp decode_extensions(nil), do: nil
  defp decode_extensions(list), do: Enum.map(list, &A2A.Types.AgentExtension.from_map/1)

  defp encode_extensions(nil), do: nil
  defp encode_extensions(list), do: Enum.map(list, &A2A.Types.AgentExtension.to_map/1)
end

defmodule A2A.Types.AgentInterface do
  @moduledoc """
  Transport binding metadata for an agent.
  """

  defstruct [:protocol_binding, :url, :tenant, :raw]

  @type t :: %__MODULE__{}

  @spec from_map(map()) :: %__MODULE__{}
  def from_map(map) do
    %__MODULE__{
      protocol_binding: map["protocolBinding"],
      url: map["url"],
      tenant: map["tenant"],
      raw: A2A.Types.drop_raw(map, ["protocolBinding", "url", "tenant"])
    }
  end

  @spec to_map(%__MODULE__{}) :: map()
  def to_map(%__MODULE__{} = interface) do
    %{}
    |> A2A.Types.put_if("protocolBinding", interface.protocol_binding)
    |> A2A.Types.put_if("url", interface.url)
    |> A2A.Types.put_if("tenant", interface.tenant)
    |> A2A.Types.merge_raw(interface.raw)
  end
end

defmodule A2A.Types.AgentSkill do
  @moduledoc """
  Agent skill metadata.
  """

  defstruct [
    :id,
    :name,
    :description,
    :tags,
    :examples,
    :input_modes,
    :output_modes,
    :security,
    :raw
  ]

  @type t :: %__MODULE__{}

  @spec from_map(map()) :: %__MODULE__{}
  def from_map(map) do
    %__MODULE__{
      id: map["id"],
      name: map["name"],
      description: map["description"],
      tags: map["tags"],
      examples: map["examples"],
      input_modes: map["inputModes"],
      output_modes: map["outputModes"],
      security: map["security"],
      raw:
        A2A.Types.drop_raw(map, [
          "id",
          "name",
          "description",
          "tags",
          "examples",
          "inputModes",
          "outputModes",
          "security"
        ])
    }
  end

  @spec to_map(%__MODULE__{}) :: map()
  def to_map(%__MODULE__{} = skill) do
    %{}
    |> A2A.Types.put_if("id", skill.id)
    |> A2A.Types.put_if("name", skill.name)
    |> A2A.Types.put_if("description", skill.description)
    |> A2A.Types.put_if("tags", skill.tags)
    |> A2A.Types.put_if("examples", skill.examples)
    |> A2A.Types.put_if("inputModes", skill.input_modes)
    |> A2A.Types.put_if("outputModes", skill.output_modes)
    |> A2A.Types.put_if("security", skill.security)
    |> A2A.Types.merge_raw(skill.raw)
  end
end

defmodule A2A.Types.AgentProvider do
  @moduledoc """
  Provider metadata for an agent.
  """

  defstruct [:organization, :url, :raw]

  @type t :: %__MODULE__{}

  @spec from_map(nil | map()) :: %__MODULE__{} | nil
  def from_map(nil), do: nil

  def from_map(map) do
    %__MODULE__{
      organization: map["organization"],
      url: map["url"],
      raw: A2A.Types.drop_raw(map, ["organization", "url"])
    }
  end

  @spec to_map(nil | %__MODULE__{}) :: map() | nil
  def to_map(nil), do: nil

  def to_map(%__MODULE__{} = provider) do
    %{}
    |> A2A.Types.put_if("organization", provider.organization)
    |> A2A.Types.put_if("url", provider.url)
    |> A2A.Types.merge_raw(provider.raw)
  end
end

defmodule A2A.Types.AgentCardSignature do
  @moduledoc """
  JWS signature metadata for agent cards.
  """

  defstruct [:protected, :signature, :header, :raw]

  @type t :: %__MODULE__{}

  @spec from_map(map()) :: %__MODULE__{}
  def from_map(map) do
    %__MODULE__{
      protected: map["protected"],
      signature: map["signature"],
      header: map["header"],
      raw: A2A.Types.drop_raw(map, ["protected", "signature", "header"])
    }
  end

  @spec to_map(%__MODULE__{}) :: map()
  def to_map(%__MODULE__{} = signature) do
    %{}
    |> A2A.Types.put_if("protected", signature.protected)
    |> A2A.Types.put_if("signature", signature.signature)
    |> A2A.Types.put_if("header", signature.header)
    |> A2A.Types.merge_raw(signature.raw)
  end
end

defmodule A2A.Types.AuthenticationInfo do
  @moduledoc """
  Authentication metadata for push config.
  """

  defstruct [:schemes, :credentials, :raw]

  @type t :: %__MODULE__{}

  @spec from_map(nil | map()) :: %__MODULE__{} | nil
  def from_map(nil), do: nil

  def from_map(map) do
    %__MODULE__{
      schemes: map["schemes"],
      credentials: map["credentials"],
      raw: A2A.Types.drop_raw(map, ["schemes", "credentials"])
    }
  end

  @spec to_map(nil | %__MODULE__{}) :: map() | nil
  def to_map(nil), do: nil

  def to_map(%__MODULE__{} = auth) do
    %{}
    |> A2A.Types.put_if("schemes", auth.schemes)
    |> A2A.Types.put_if("credentials", auth.credentials)
    |> A2A.Types.merge_raw(auth.raw)
  end
end

defmodule A2A.Types.AgentCard do
  @moduledoc """
  Agent card document.
  """

  defstruct [
    :name,
    :description,
    :version,
    :capabilities,
    :default_input_modes,
    :default_output_modes,
    :skills,
    :security_schemes,
    :security,
    :documentation_url,
    :icon_url,
    :provider,
    :signatures,
    :protocol_version,
    :url,
    :preferred_transport,
    :additional_interfaces,
    :supports_authenticated_extended_card,
    :supported_interfaces,
    :protocol_versions,
    :raw
  ]

  @type t :: %__MODULE__{}

  @spec from_map(map(), keyword()) :: %__MODULE__{}
  def from_map(map, _opts \\ []) do
    %__MODULE__{
      name: map["name"],
      description: map["description"],
      version: map["version"],
      capabilities: A2A.Types.AgentCapabilities.from_map(map["capabilities"] || %{}),
      default_input_modes: map["defaultInputModes"],
      default_output_modes: map["defaultOutputModes"],
      skills: decode_list(map["skills"], &A2A.Types.AgentSkill.from_map/1),
      security_schemes: map["securitySchemes"],
      security: map["security"],
      documentation_url: map["documentationUrl"],
      icon_url: map["iconUrl"],
      provider: A2A.Types.AgentProvider.from_map(map["provider"]),
      signatures: decode_list(map["signatures"], &A2A.Types.AgentCardSignature.from_map/1),
      protocol_version: map["protocolVersion"],
      url: map["url"],
      preferred_transport: map["preferredTransport"],
      additional_interfaces:
        decode_list(map["additionalInterfaces"], &A2A.Types.AgentInterface.from_map/1),
      supports_authenticated_extended_card: map["supportsAuthenticatedExtendedCard"],
      supported_interfaces:
        decode_list(map["supportedInterfaces"], &A2A.Types.AgentInterface.from_map/1),
      protocol_versions: map["protocolVersions"],
      raw:
        A2A.Types.drop_raw(map, [
          "name",
          "description",
          "version",
          "capabilities",
          "defaultInputModes",
          "defaultOutputModes",
          "skills",
          "securitySchemes",
          "security",
          "documentationUrl",
          "iconUrl",
          "provider",
          "signatures",
          "protocolVersion",
          "url",
          "preferredTransport",
          "additionalInterfaces",
          "supportsAuthenticatedExtendedCard",
          "supportedInterfaces",
          "protocolVersions"
        ])
    }
  end

  @spec to_map(%__MODULE__{}, keyword()) :: map()
  def to_map(%__MODULE__{} = card, opts \\ []) do
    version = A2A.Types.version_from_opts(opts)

    %{}
    |> A2A.Types.put_if("name", card.name)
    |> A2A.Types.put_if("description", card.description)
    |> A2A.Types.put_if("version", card.version)
    |> A2A.Types.put_if("capabilities", A2A.Types.AgentCapabilities.to_map(card.capabilities))
    |> A2A.Types.put_if("defaultInputModes", card.default_input_modes)
    |> A2A.Types.put_if("defaultOutputModes", card.default_output_modes)
    |> A2A.Types.put_if("skills", encode_list(card.skills, &A2A.Types.AgentSkill.to_map/1))
    |> A2A.Types.put_if("securitySchemes", card.security_schemes)
    |> A2A.Types.put_if("security", card.security)
    |> A2A.Types.put_if("documentationUrl", card.documentation_url)
    |> A2A.Types.put_if("iconUrl", card.icon_url)
    |> A2A.Types.put_if("provider", A2A.Types.AgentProvider.to_map(card.provider))
    |> A2A.Types.put_if(
      "signatures",
      encode_list(card.signatures, &A2A.Types.AgentCardSignature.to_map/1)
    )
    |> maybe_put_v0_3(card, version)
    |> maybe_put_latest(card, version)
    |> A2A.Types.merge_raw(card.raw)
  end

  defp decode_list(nil, _fun), do: nil
  defp decode_list(list, fun), do: Enum.map(list, fun)
  defp encode_list(nil, _fun), do: nil
  defp encode_list(list, fun), do: Enum.map(list, fun)

  defp maybe_put_v0_3(map, _card, :latest), do: map

  defp maybe_put_v0_3(map, card, _version) do
    map
    |> A2A.Types.put_if("protocolVersion", card.protocol_version || "0.3.0")
    |> A2A.Types.put_if("url", card.url)
    |> A2A.Types.put_if("preferredTransport", card.preferred_transport)
    |> A2A.Types.put_if(
      "additionalInterfaces",
      encode_list(card.additional_interfaces, &A2A.Types.AgentInterface.to_map/1)
    )
    |> A2A.Types.put_if(
      "supportsAuthenticatedExtendedCard",
      card.supports_authenticated_extended_card
    )
  end

  defp maybe_put_latest(map, card, :latest) do
    map
    |> A2A.Types.put_if(
      "supportedInterfaces",
      encode_list(card.supported_interfaces, &A2A.Types.AgentInterface.to_map/1)
    )
    |> A2A.Types.put_if("protocolVersions", card.protocol_versions)
  end

  defp maybe_put_latest(map, _card, _version), do: map
end
