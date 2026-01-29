defmodule A2A.Server.Push.Security do
  @moduledoc """
  Webhook validation and optional replay/signature helpers.
  """

  import Bitwise

  @spec validate_destination(String.t() | nil, keyword()) :: :ok | {:error, A2A.Error.t()}
  def validate_destination(url, opts \\ []) do
    allow_http = Keyword.get(opts, :allow_http, false)
    strict = Keyword.get(opts, :strict, false)

    with :ok <- A2A.Server.Validation.validate_webhook_url(url, allow_http),
         {:ok, uri} <- parse_uri(url),
         :ok <- validate_host(uri, opts),
         :ok <- maybe_validate_ips(uri, opts, strict) do
      :ok
    end
  end

  @spec add_security_headers(list(), String.t(), keyword()) :: list()
  def add_security_headers(headers, body, opts) when is_binary(body) do
    headers
    |> maybe_add_replay_headers(opts)
    |> maybe_add_signature(body, opts)
  end

  @spec verify_signature(String.t(), list(), keyword()) :: :ok | {:error, A2A.Error.t()}
  def verify_signature(body, headers, opts) when is_binary(body) do
    signing_key = Keyword.get(opts, :signing_key)
    signature_header = Keyword.get(opts, :signature_header, "x-a2a-signature")

    if is_binary(signing_key) do
      with {:ok, timestamp} <-
             fetch_header(headers, Keyword.get(opts, :timestamp_header, "x-a2a-timestamp")),
           {:ok, nonce} <- fetch_header(headers, Keyword.get(opts, :nonce_header, "x-a2a-nonce")),
           {:ok, signature} <- fetch_header(headers, signature_header) do
        expected = sign_payload(body, signing_key, timestamp, nonce)

        if secure_compare(signature, expected) do
          :ok
        else
          {:error, A2A.Error.new(:invalid_agent_response, "Invalid signature")}
        end
      end
    else
      {:error, A2A.Error.new(:invalid_agent_response, "Signing key not configured")}
    end
  end

  defp parse_uri(url) when is_binary(url) do
    uri = URI.parse(url)

    if is_binary(uri.host) and uri.host != "" do
      {:ok, uri}
    else
      {:error, A2A.Error.new(:invalid_agent_response, "Webhook URL missing host")}
    end
  end

  defp parse_uri(_url),
    do: {:error, A2A.Error.new(:invalid_agent_response, "Webhook URL missing host")}

  defp validate_host(%URI{host: host}, opts) do
    allowed = Keyword.get(opts, :allowed_hosts)
    blocked = Keyword.get(opts, :blocked_hosts, [])

    cond do
      host_matches?(blocked, host) ->
        {:error, A2A.Error.new(:invalid_agent_response, "Webhook host blocked")}

      allowed == nil ->
        :ok

      host_matches?(allowed, host) ->
        :ok

      true ->
        {:error, A2A.Error.new(:invalid_agent_response, "Webhook host not allowed")}
    end
  end

  defp host_matches?(hosts, host) when is_list(hosts) do
    Enum.any?(hosts, fn
      %Regex{} = regex -> Regex.match?(regex, host)
      entry when is_binary(entry) -> entry == host
      _ -> false
    end)
  end

  defp host_matches?(_hosts, _host), do: false

  defp maybe_validate_ips(%URI{host: host}, opts, strict) do
    resolve_ips = Keyword.get(opts, :resolve_ips, strict)
    allow_private = Keyword.get(opts, :allow_private, not strict)

    if resolve_ips do
      with {:ok, addresses} <- resolve_host(host) do
        if allow_private or Enum.all?(addresses, &public_ip?/1) do
          :ok
        else
          {:error,
           A2A.Error.new(:invalid_agent_response, "Webhook URL resolves to a private address")}
        end
      end
    else
      :ok
    end
  end

  defp resolve_host(host) when is_binary(host) do
    charlist = String.to_charlist(host)

    case :inet.parse_address(charlist) do
      {:ok, ip} ->
        {:ok, [ip]}

      {:error, _} ->
        addresses = get_addrs(charlist, :inet) ++ get_addrs(charlist, :inet6)

        if addresses == [] do
          {:error, A2A.Error.new(:invalid_agent_response, "Unable to resolve webhook host")}
        else
          {:ok, addresses}
        end
    end
  end

  defp get_addrs(charlist, family) do
    case :inet.getaddrs(charlist, family) do
      {:ok, addrs} -> addrs
      {:error, _} -> []
    end
  end

  defp public_ip?({a, _b, _c, _d}) when a == 10, do: false
  defp public_ip?({a, _b, _c, _d}) when a == 127, do: false
  defp public_ip?({a, b, _c, _d}) when a == 172 and b in 16..31, do: false
  defp public_ip?({a, b, _c, _d}) when a == 192 and b == 168, do: false
  defp public_ip?({a, b, _c, _d}) when a == 169 and b == 254, do: false
  defp public_ip?({a, b, _c, _d}) when a == 100 and b in 64..127, do: false
  defp public_ip?({0, _b, _c, _d}), do: false
  defp public_ip?({_, _, _, _}), do: true

  defp public_ip?({0, 0, 0, 0, 0, 0, 0, 0}), do: false
  defp public_ip?({0, 0, 0, 0, 0, 0, 0, 1}), do: false

  defp public_ip?({first, _second, _third, _fourth, _fifth, _sixth, _seventh, _eighth})
       when first in 0xFC00..0xFDFF,
       do: false

  defp public_ip?({first, _second, _third, _fourth, _fifth, _sixth, _seventh, _eighth})
       when first in 0xFE80..0xFEBF,
       do: false

  defp public_ip?({_a, _b, _c, _d, _e, _f, _g, _h}), do: true

  defp maybe_add_replay_headers(headers, opts) do
    if Keyword.get(opts, :replay_protection, false) or is_binary(Keyword.get(opts, :signing_key)) do
      timestamp_header = Keyword.get(opts, :timestamp_header, "x-a2a-timestamp")
      nonce_header = Keyword.get(opts, :nonce_header, "x-a2a-nonce")

      headers
      |> put_header_if_missing(timestamp_header, Integer.to_string(System.system_time(:second)))
      |> put_header_if_missing(nonce_header, random_nonce())
    else
      headers
    end
  end

  defp maybe_add_signature(headers, body, opts) do
    cond do
      is_function(Keyword.get(opts, :signer), 3) ->
        Keyword.get(opts, :signer).(headers, body, opts)

      is_binary(Keyword.get(opts, :signing_key)) ->
        signature_header = Keyword.get(opts, :signature_header, "x-a2a-signature")
        signing_key = Keyword.get(opts, :signing_key)

        {:ok, timestamp} =
          fetch_header(headers, Keyword.get(opts, :timestamp_header, "x-a2a-timestamp"))

        {:ok, nonce} = fetch_header(headers, Keyword.get(opts, :nonce_header, "x-a2a-nonce"))

        signature = sign_payload(body, signing_key, timestamp, nonce)
        headers ++ [{signature_header, signature}]

      true ->
        headers
    end
  end

  defp sign_payload(body, signing_key, timestamp, nonce) do
    data = [timestamp, nonce, body] |> Enum.join(":")
    signing_key = :erlang.iolist_to_binary(signing_key)
    Base.encode64(:crypto.mac(:hmac, :sha256, signing_key, data))
  end

  defp secure_compare(left, right) when byte_size(left) == byte_size(right) do
    left
    |> :binary.bin_to_list()
    |> Enum.zip(:binary.bin_to_list(right))
    |> Enum.reduce(0, fn {a, b}, acc -> acc ||| Bitwise.bxor(a, b) end)
    |> Kernel.==(0)
  end

  defp secure_compare(_left, _right), do: false

  defp random_nonce do
    :crypto.strong_rand_bytes(12) |> Base.encode16(case: :lower)
  end

  defp put_header_if_missing(headers, name, value) do
    if header_present?(headers, name) do
      headers
    else
      headers ++ [{name, value}]
    end
  end

  defp header_present?(headers, name) do
    header_value(headers, name) != nil
  end

  defp fetch_header(headers, name) do
    case header_value(headers, name) do
      nil -> {:error, A2A.Error.new(:invalid_agent_response, "Missing #{name} header")}
      value -> {:ok, value}
    end
  end

  defp header_value(headers, name) do
    downcased = String.downcase(name)

    headers
    |> Enum.find_value(fn {key, value} ->
      if String.downcase(key) == downcased, do: value, else: nil
    end)
  end
end
