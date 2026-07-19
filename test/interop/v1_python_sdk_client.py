import asyncio
import os

import httpx
from google.protobuf.json_format import ParseDict

from a2a.client import ClientConfig, ClientFactory
from a2a.types import (
    AgentCard,
    GetTaskRequest,
    Message,
    Part,
    Role,
    SendMessageRequest,
    TaskState,
)


async def exercise(binding: str, card: AgentCard) -> None:
    client = ClientFactory(
        ClientConfig(
            streaming=False,
            polling=False,
            supported_protocol_bindings=[binding],
            use_client_preference=True,
        )
    ).create(card)

    try:
        request = SendMessageRequest(
            message=Message(
                message_id=f"python-sdk-{binding.lower()}",
                role=Role.ROLE_USER,
                parts=[Part(text="hello from the official Python SDK")],
            )
        )
        responses = [response async for response in client.send_message(request)]
        assert len(responses) == 1
        assert responses[0].HasField("task")
        task_id = responses[0].task.id
        assert task_id

        fetched = await client.get_task(GetTaskRequest(id=task_id, history_length=1))
        assert fetched.id == task_id
        assert fetched.status.state == TaskState.TASK_STATE_COMPLETED
    finally:
        await client.close()


async def main() -> None:
    rest_port = os.environ.get("A2A_TCK_REST_PORT", "9999")
    card_url = f"http://127.0.0.1:{rest_port}/.well-known/agent-card.json"

    async with httpx.AsyncClient() as http:
        response = await http.get(card_url)
        response.raise_for_status()
        card = ParseDict(response.json(), AgentCard())

    await exercise("HTTP+JSON", card)
    await exercise("JSONRPC", card)


if __name__ == "__main__":
    asyncio.run(main())
