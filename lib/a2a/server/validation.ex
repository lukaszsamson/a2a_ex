defmodule A2A.Server.Validation do
  @moduledoc false

  @spec validate_webhook_url(term(), boolean()) :: :ok | {:error, A2A.Error.t()}
  def validate_webhook_url(url, allow_http) do
    uri = URI.parse(to_string(url || ""))

    cond do
      uri.scheme == "https" ->
        :ok

      allow_http and uri.scheme == "http" ->
        :ok

      is_nil(uri.scheme) ->
        {:error, A2A.Error.new(:invalid_agent_response, "Missing URL")}

      true ->
        {:error, A2A.Error.new(:invalid_agent_response, "Webhook URL must be https")}
    end
  end
end
