defmodule A2A.Client.Config do
  @moduledoc """
  Client configuration for transport requests.
  """

  defstruct [
    :base_url,
    :transport,
    :version,
    :headers,
    :extensions,
    :legacy_extensions_header,
    :rest_base_path,
    :agent_card_path,
    :subscribe_verb,
    :wire_format,
    :auth,
    :req_options,
    :transport_opts,
    :tenant,
    :cancel_metadata
  ]

  @type t :: %__MODULE__{}

  @spec new(String.t() | nil, keyword()) :: t()
  def new(target, opts \\ []) do
    version = opts |> Keyword.get(:version, :v0_3) |> A2A.Types.normalize_version()
    base_url = if is_binary(target), do: target, else: nil

    %__MODULE__{
      base_url: base_url,
      transport: Keyword.get(opts, :transport, A2A.Transport.REST),
      version: version,
      headers: Keyword.get(opts, :headers, []),
      extensions: Keyword.get(opts, :extensions, []),
      legacy_extensions_header: Keyword.get(opts, :legacy_extensions_header, false),
      rest_base_path:
        Keyword.get(
          opts,
          :rest_base_path,
          Keyword.get(opts, :base_path, default_base_path(version))
        ),
      agent_card_path: Keyword.get(opts, :agent_card_path, "/.well-known/agent-card.json"),
      subscribe_verb: Keyword.get(opts, :subscribe_verb, default_subscribe_verb(version)),
      wire_format: Keyword.get(opts, :wire_format, :spec_json),
      auth: Keyword.get(opts, :auth),
      req_options: Keyword.get(opts, :req_options, []),
      transport_opts: Keyword.get(opts, :transport_opts, []),
      tenant: Keyword.get(opts, :tenant),
      cancel_metadata: Keyword.get(opts, :metadata)
    }
  end

  @spec from_agent_card(A2A.Types.AgentCard.t(), keyword()) :: t()
  def from_agent_card(%A2A.Types.AgentCard{} = card, opts \\ []) do
    interface = A2A.Client.select_interface(card, opts)

    if is_nil(interface) and (card.supported_interfaces || []) != [] do
      raise ArgumentError,
            "agent card has no interface matching the requested protocol version and binding"
    end

    base_url = (interface && interface.url) || card.url
    transport = interface && A2A.Client.transport_for_binding(interface.protocol_binding)

    opts =
      opts
      |> Keyword.put_new(:version, version_from_interface(interface, card))
      |> Keyword.put_new(:transport, transport || A2A.Transport.REST)
      |> Keyword.put_new(:tenant, interface && interface.tenant)

    config = new(base_url, opts)
    %{config | transport_opts: Keyword.get(opts, :transport_opts, [])}
  end

  @spec request_headers(t(), keyword()) :: list({String.t(), String.t()})
  def request_headers(%__MODULE__{} = config, opts \\ []) do
    headers = config.headers ++ Keyword.get(opts, :headers, [])
    extensions = Keyword.get(opts, :extensions, config.extensions) || []
    headers = maybe_add_extensions(headers, extensions, config)
    headers = maybe_add_version(headers, config)
    headers = maybe_add_auth(headers, config)
    headers
  end

  @spec auth_challenge_headers(t(), String.t() | nil) ::
          {:ok, list({String.t(), String.t()})} | :skip
  def auth_challenge_headers(%__MODULE__{auth: {module, opts}}, challenge)
      when is_atom(module) do
    if function_exported?(module, :on_auth_challenge, 2) do
      normalize_auth_challenge_result(apply(module, :on_auth_challenge, [challenge, opts]))
    else
      :skip
    end
  end

  def auth_challenge_headers(%__MODULE__{auth: fun}, challenge) when is_function(fun, 1) do
    normalize_auth_challenge_result(fun.(challenge))
  end

  def auth_challenge_headers(_config, _challenge), do: :skip

  defp normalize_auth_challenge_result({:ok, headers}) when is_list(headers), do: {:ok, headers}
  defp normalize_auth_challenge_result(headers) when is_list(headers), do: {:ok, headers}
  defp normalize_auth_challenge_result(_), do: :skip

  defp maybe_add_extensions(headers, [], _config), do: headers

  defp maybe_add_extensions(headers, extensions, config) do
    header_name =
      if config.legacy_extensions_header, do: "x-a2a-extensions", else: "a2a-extensions"

    header_value = A2A.Extension.format_header(extensions)
    headers ++ [{header_name, header_value}]
  end

  defp maybe_add_version(headers, %__MODULE__{version: :v1_0}) do
    put_header_unless_present(headers, "a2a-version", "1.0")
  end

  defp maybe_add_version(headers, _config), do: headers

  defp maybe_add_auth(headers, %__MODULE__{auth: {module, opts}}) do
    case apply(module, :headers, [opts]) do
      list when is_list(list) -> headers ++ list
      _ -> headers
    end
  end

  defp maybe_add_auth(headers, %__MODULE__{auth: fun}) when is_function(fun, 0) do
    case fun.() do
      list when is_list(list) -> headers ++ list
      _ -> headers
    end
  end

  defp maybe_add_auth(headers, _config), do: headers

  defp default_base_path(:v1_0), do: ""
  defp default_base_path(_), do: "/v1"

  defp version_from_interface(%A2A.Types.AgentInterface{protocol_version: version}, _card)
       when is_binary(version) do
    parse_protocol_version(version)
  end

  defp version_from_interface(_interface, card), do: version_from_card(card)

  defp version_from_card(%A2A.Types.AgentCard{protocol_versions: [version | _]})
       when is_binary(version) do
    parse_protocol_version(version)
  end

  defp version_from_card(%A2A.Types.AgentCard{protocol_version: "0.3.0"}), do: :v0_3
  defp version_from_card(_card), do: :v0_3

  defp parse_protocol_version(version) do
    case String.split(version, ".") do
      ["1", "0" | _] -> :v1_0
      ["0", "3" | _] -> :v0_3
      _ -> raise ArgumentError, "unsupported A2A protocol version #{inspect(version)}"
    end
  end

  defp default_subscribe_verb(:v1_0), do: :get
  defp default_subscribe_verb(_), do: :post

  defp put_header_unless_present(headers, name, value) do
    if Enum.any?(headers, fn {key, _} -> String.downcase(key) == name end) do
      headers
    else
      headers ++ [{name, value}]
    end
  end
end
