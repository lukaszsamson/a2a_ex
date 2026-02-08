defmodule A2A.ServerValidationTest do
  use ExUnit.Case, async: true

  test "accepts https URLs" do
    assert :ok == A2A.Server.Validation.validate_webhook_url("https://example.com/webhook", false)
  end

  test "rejects http URL when allow_http is false" do
    assert {:error,
            %A2A.Error{type: :invalid_agent_response, message: "Webhook URL must be https"}} =
             A2A.Server.Validation.validate_webhook_url("http://example.com/webhook", false)
  end

  test "accepts http URL when allow_http is true" do
    assert :ok == A2A.Server.Validation.validate_webhook_url("http://example.com/webhook", true)
  end

  test "returns missing URL error for nil and non-string input" do
    assert {:error, %A2A.Error{message: "Missing URL"}} =
             A2A.Server.Validation.validate_webhook_url(nil, false)

    assert {:error, %A2A.Error{message: "Missing URL"}} =
             A2A.Server.Validation.validate_webhook_url(123, false)
  end

  test "rejects unsupported scheme" do
    assert {:error,
            %A2A.Error{type: :invalid_agent_response, message: "Webhook URL must be https"}} =
             A2A.Server.Validation.validate_webhook_url("ftp://example.com/webhook", true)
  end
end
