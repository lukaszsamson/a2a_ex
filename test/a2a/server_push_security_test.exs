defmodule A2A.Server.Push.SecurityTest do
  use ExUnit.Case, async: true

  alias A2A.Server.Push.Security

  test "blocked host takes precedence over allowed host" do
    assert {:error, %A2A.Error{message: "Webhook host blocked"}} =
             Security.validate_destination("https://example.com/webhook",
               allowed_hosts: [~r/example\.com$/],
               blocked_hosts: ["example.com"]
             )
  end

  test "rejects ipv6 loopback host in strict mode" do
    assert {:error, %A2A.Error{message: "Webhook URL resolves to a private address"}} =
             Security.validate_destination("https://[::1]/webhook", strict: true)
  end

  test "returns resolution error for unresolvable host in strict mode" do
    assert {:error, %A2A.Error{message: "Unable to resolve webhook host"}} =
             Security.validate_destination("https://a2a-test-host.invalid/webhook", strict: true)
  end

  test "custom signer callback can attach custom signature header" do
    headers =
      Security.add_security_headers([], "{}",
        signer: fn headers, _body, _opts -> headers ++ [{"x-custom-signature", "signed"}] end
      )

    assert {"x-custom-signature", "signed"} in headers
  end

  test "verify_signature fails when required headers are missing" do
    assert {:error, %A2A.Error{message: "Missing x-a2a-timestamp header"}} =
             Security.verify_signature("{}", [{"x-a2a-signature", "abc"}], signing_key: "secret")
  end

  test "verify_signature fails for invalid signature" do
    headers = [
      {"x-a2a-timestamp", "1700000000"},
      {"x-a2a-nonce", "abcdef"},
      {"x-a2a-signature", "not-valid"}
    ]

    assert {:error, %A2A.Error{message: "Invalid signature"}} =
             Security.verify_signature("{}", headers, signing_key: "secret")
  end

  test "verify_signature succeeds with generated signature headers" do
    body = "{\"hello\":\"world\"}"

    headers =
      Security.add_security_headers([], body,
        replay_protection: true,
        signing_key: "secret"
      )

    assert :ok == Security.verify_signature(body, headers, signing_key: "secret")
  end
end
