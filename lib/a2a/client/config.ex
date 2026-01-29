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
    :auth,
    :req_options,
    :transport_opts
  ]

  @type t :: %__MODULE__{}

  @spec new(String.t() | nil, keyword()) :: t()
  def new(target, opts \\ []) do
    version = Keyword.get(opts, :version, :v0_3)
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
      subscribe_verb: Keyword.get(opts, :subscribe_verb, :post),
      auth: Keyword.get(opts, :auth),
      req_options: Keyword.get(opts, :req_options, []),
      transport_opts: Keyword.get(opts, :transport_opts, [])
    }
  end

  @spec from_agent_card(A2A.Types.AgentCard.t(), keyword()) :: t()
  def from_agent_card(%A2A.Types.AgentCard{} = card, opts \\ []) do
    interface = A2A.Client.select_interface(card, opts)
    base_url = (interface && interface.url) || card.url
    transport = interface && A2A.Client.transport_for_binding(interface.protocol_binding)

    opts =
      opts
      |> Keyword.put_new(:version, version_from_card(card))
      |> Keyword.put_new(:transport, transport || A2A.Transport.REST)

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

  defp maybe_add_extensions(headers, [], _config), do: headers

  defp maybe_add_extensions(headers, extensions, config) do
    header_name =
      if config.legacy_extensions_header, do: "x-a2a-extensions", else: "a2a-extensions"

    header_value = A2A.Extension.format_header(extensions)
    headers ++ [{header_name, header_value}]
  end

  defp maybe_add_version(headers, %__MODULE__{version: :latest}) do
    headers ++ [{"a2a-version", "0.3"}]
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

  defp default_base_path(:latest), do: ""
  defp default_base_path(_), do: "/v1"

  defp version_from_card(%A2A.Types.AgentCard{protocol_versions: [version | _]})
       when is_binary(version) do
    if String.starts_with?(version, "0.3"), do: :v0_3, else: :latest
  end

  defp version_from_card(%A2A.Types.AgentCard{protocol_version: "0.3.0"}), do: :v0_3
  defp version_from_card(_card), do: :v0_3
end
