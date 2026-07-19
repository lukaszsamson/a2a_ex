defmodule A2A.Server.Push do
  @moduledoc """
  Sends push notifications to task subscribers.
  """

  @spec deliver(A2A.Types.PushNotificationConfig.t(), term(), keyword()) ::
          :ok | {:error, A2A.Error.t()}
  def deliver(%A2A.Types.PushNotificationConfig{} = config, payload, opts \\ []) do
    version = opts |> Keyword.get(:version, :v0_3) |> A2A.Types.normalize_version()
    allow_http = Keyword.get(opts, :allow_http, false)
    security_opts = Keyword.get(opts, :security, [])
    security_opts = Keyword.put_new(security_opts, :allow_http, allow_http)

    with :ok <- A2A.Server.Push.Security.validate_destination(config.url, security_opts),
         {:ok, body} <- encode_payload(payload, version) do
      headers = build_headers(config, version)
      headers = A2A.Server.Push.Security.add_security_headers(headers, body, security_opts)
      metadata = %{transport: :push, url: config.url}
      sender = Keyword.get(opts, :sender, &Req.request/1)

      A2A.Telemetry.span([:a2a, :push, :deliver], metadata, fn ->
        resp = sender.(method: :post, url: config.url, headers: headers, body: body)

        case resp do
          {:ok, %{status: status}} when status in 200..299 -> :ok
          {:ok, %{status: status}} -> {:error, A2A.Error.new(:http_error, "HTTP #{status}")}
          {:error, reason} -> {:error, A2A.Error.new(:transport_error, inspect(reason))}
        end
      end)
    end
  end

  defp encode_payload(%A2A.Types.StreamResponse{} = response, :v1_0) do
    {:ok, Jason.encode!(A2A.Types.StreamResponse.to_map(response, version: :v1_0))}
  end

  defp encode_payload(%A2A.Types.Task{} = task, :v1_0) do
    {:ok,
     Jason.encode!(
       A2A.Types.StreamResponse.to_map(%A2A.Types.StreamResponse{task: task}, version: :v1_0)
     )}
  end

  defp encode_payload(%A2A.Types.Task{} = task, _version) do
    {:ok, Jason.encode!(A2A.Types.Task.to_map(task, version: :v0_3))}
  end

  defp encode_payload(%A2A.Types.StreamResponse{task: %A2A.Types.Task{} = task}, _version) do
    {:ok, Jason.encode!(A2A.Types.Task.to_map(task, version: :v0_3))}
  end

  defp encode_payload(map, _version) when is_map(map) do
    {:ok, Jason.encode!(map)}
  end

  defp encode_payload(_payload, _version) do
    {:error, A2A.Error.new(:invalid_agent_response, "Invalid push payload")}
  end

  defp build_headers(%A2A.Types.PushNotificationConfig{} = config, version) do
    []
    |> maybe_put_token(config.token)
    |> maybe_put_auth(config.authentication)
    |> ensure_content_type(version)
  end

  defp maybe_put_token(headers, nil), do: headers
  defp maybe_put_token(headers, token), do: headers ++ [{"x-a2a-notification-token", token}]

  defp maybe_put_auth(headers, nil), do: headers

  defp maybe_put_auth(headers, %A2A.Types.AuthenticationInfo{
         credentials: credentials,
         scheme: scheme,
         schemes: schemes
       })
       when is_binary(credentials) do
    header =
      case if(scheme, do: [scheme], else: schemes || []) do
        [scheme | _] -> "#{scheme} #{credentials}"
        _ -> credentials
      end

    headers ++ [{"authorization", header}]
  end

  defp maybe_put_auth(headers, _), do: headers

  defp ensure_content_type(headers, version) do
    if Enum.any?(headers, fn {key, _} -> String.downcase(key) == "content-type" end) do
      headers
    else
      value = if A2A.Types.v1?(version), do: "application/a2a+json", else: "application/json"
      headers ++ [{"content-type", value}]
    end
  end
end
