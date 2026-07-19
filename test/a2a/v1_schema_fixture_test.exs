defmodule A2A.V1SchemaFixtureTest do
  use ExUnit.Case, async: true

  alias A2A.Protocol.V1_0.ProtoJSON

  @fixture_dir Path.expand("../fixtures/v1", __DIR__)

  test "AgentCard fixture round-trips through the stable v1 codec" do
    fixture = fixture("agent_card.json")
    card = ProtoJSON.decode(A2A.Types.AgentCard, fixture)

    assert :ok = A2A.AgentCard.validate(card, version: :v1_0)
    assert ProtoJSON.encode(A2A.Types.AgentCard, card) == fixture
  end

  test "SendMessageRequest fixture uses normative Part and configuration fields" do
    fixture = fixture("send_message_request.json")
    request = ProtoJSON.decode(A2A.Types.SendMessageRequest, fixture)

    assert Enum.all?(request.message.parts, &match?(%A2A.Types.Part{}, &1))
    assert request.configuration.return_immediately
    assert request.configuration.task_push_notification_config.authentication.scheme == "Bearer"
    assert ProtoJSON.encode(A2A.Types.SendMessageRequest, request) == fixture
  end

  test "ListTasksResponse fixture preserves required empty nextPageToken" do
    fixture = fixture("list_tasks_response.json")
    response = ProtoJSON.decode(A2A.Types.ListTasksResponse, fixture)

    assert hd(response.tasks).status.state == :canceled
    assert ProtoJSON.encode(A2A.Types.ListTasksResponse, response) == fixture
  end

  test "canonical HTTP and JSON-RPC details decode to the same A2A error" do
    fixture = fixture("error_responses.json")

    for envelope <- [fixture["jsonrpc"], fixture["http"]] do
      assert %A2A.Error{
               type: :task_not_found,
               message: "Task not found",
               data: %{"taskId" => "missing"}
             } = A2A.Error.from_map(envelope)
    end
  end

  defp fixture(name) do
    @fixture_dir
    |> Path.join(name)
    |> File.read!()
    |> Jason.decode!()
  end
end
