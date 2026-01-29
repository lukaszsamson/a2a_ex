defmodule A2A.PushTest do
  use ExUnit.Case, async: true

  test "builds push payload and headers" do
    config = %A2A.Types.PushNotificationConfig{
      url: "https://example.com/webhook",
      token: "token-1",
      authentication: %A2A.Types.AuthenticationInfo{credentials: "abc", schemes: ["Bearer"]}
    }

    task = %A2A.Types.Task{
      id: "task-1",
      context_id: "ctx-1",
      status: %A2A.Types.TaskStatus{state: :working}
    }

    parent = self()

    sender = fn opts ->
      send(parent, {:push_request, opts})
      {:ok, %{status: 200}}
    end

    assert :ok == A2A.Server.Push.deliver(config, task, sender: sender)

    assert_received {:push_request, opts}
    assert opts[:method] == :post
    assert opts[:url] == "https://example.com/webhook"
    assert {"x-a2a-notification-token", "token-1"} in opts[:headers]
    assert {"authorization", "Bearer abc"} in opts[:headers]
    assert opts[:body] =~ "\"id\":\"task-1\""
  end

  test "rejects http webhook without allow_http" do
    config = %A2A.Types.PushNotificationConfig{
      url: "http://example.com/webhook"
    }

    assert {:error, %A2A.Error{type: :invalid_agent_response}} =
             A2A.Server.Push.deliver(config, %{}, [])
  end

  test "allows http webhook when enabled" do
    config = %A2A.Types.PushNotificationConfig{
      url: "http://example.com/webhook"
    }

    parent = self()

    sender = fn opts ->
      send(parent, {:push_request, opts})
      {:ok, %{status: 200}}
    end

    assert :ok == A2A.Server.Push.deliver(config, %{}, allow_http: true, sender: sender)
    assert_received {:push_request, opts}
    assert opts[:url] == "http://example.com/webhook"
  end

  test "rejects private webhook when security strict" do
    config = %A2A.Types.PushNotificationConfig{
      url: "https://127.0.0.1/webhook"
    }

    assert {:error, %A2A.Error{type: :invalid_agent_response}} =
             A2A.Server.Push.deliver(config, %{}, security: [strict: true])
  end

  test "adds replay and signature headers" do
    config = %A2A.Types.PushNotificationConfig{
      url: "https://example.com/webhook"
    }

    parent = self()

    sender = fn opts ->
      send(parent, {:push_request, opts})
      {:ok, %{status: 200}}
    end

    security = [
      strict: true,
      allowed_hosts: ["example.com"],
      resolve_ips: false,
      replay_protection: true,
      signing_key: "secret"
    ]

    assert :ok == A2A.Server.Push.deliver(config, %{}, sender: sender, security: security)

    assert_received {:push_request, opts}

    assert header_value(opts[:headers], "x-a2a-timestamp")
    assert header_value(opts[:headers], "x-a2a-nonce")
    assert header_value(opts[:headers], "x-a2a-signature")

    assert :ok ==
             A2A.Server.Push.Security.verify_signature(opts[:body], opts[:headers],
               signing_key: "secret"
             )
  end

  test "returns error on non-2xx response" do
    config = %A2A.Types.PushNotificationConfig{
      url: "https://example.com/webhook"
    }

    sender = fn _opts -> {:ok, %{status: 500}} end

    assert {:error, %A2A.Error{type: :http_error}} =
             A2A.Server.Push.deliver(config, %{}, sender: sender)
  end

  test "returns error on transport failure" do
    config = %A2A.Types.PushNotificationConfig{
      url: "https://example.com/webhook"
    }

    sender = fn _opts -> {:error, :timeout} end

    assert {:error, %A2A.Error{type: :transport_error}} =
             A2A.Server.Push.deliver(config, %{}, sender: sender)
  end

  test "encodes task payload for latest version" do
    config = %A2A.Types.PushNotificationConfig{
      url: "https://example.com/webhook"
    }

    task = %A2A.Types.Task{
      id: "task-1",
      context_id: "ctx-1",
      status: %A2A.Types.TaskStatus{state: :working}
    }

    parent = self()

    sender = fn opts ->
      send(parent, {:push_request, opts})
      {:ok, %{status: 200}}
    end

    assert :ok == A2A.Server.Push.deliver(config, task, version: :latest, sender: sender)
    assert_received {:push_request, opts}
    assert opts[:body] =~ "\"task\""
  end

  defp header_value(headers, name) do
    name = String.downcase(name)

    Enum.find_value(headers, fn {key, value} ->
      if String.downcase(key) == name, do: value, else: nil
    end)
  end
end
