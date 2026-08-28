#!/usr/bin/env python3
"""Stdlib tests for the controlled fake LLM scenarios."""

from __future__ import annotations

import json
import pathlib
import sys
import threading
import unittest
import urllib.error
import urllib.request

sys.path.insert(0, str(pathlib.Path(__file__).parent))

from fake_llm import (  # noqa: E402
    Handler,
    ScenarioConfigurationError,
    Server,
    Settings,
    Stats,
    build_completion,
)


WRITE_TOOL = {
    "type": "function",
    "function": {
        "name": "write",
        "parameters": {
            "type": "object",
            "properties": {
                "file_path": {"type": "string"},
                "content": {"type": "string"},
                "intent": {
                    "type": "string",
                    "description": "Required short label shown in the UI: why this call is being made.",
                },
            },
            "required": ["file_path", "content", "intent"],
        },
    },
}
LEGACY_WRITE_TOOL = {
    "type": "function",
    "function": {
        "name": "write",
        "parameters": {
            "type": "object",
            "properties": {
                "filePath": {"type": "string"},
                "content": {"type": "string"},
            },
            "required": ["filePath", "content"],
        },
    },
}
BASH_TOOL = {
    "type": "function",
    "function": {
        "name": "bash",
        "parameters": {
            "type": "object",
            "properties": {"command": {"type": "string"}},
            "required": ["command"],
        },
    },
}


class FakeLlmScenarioTests(unittest.TestCase):
    def test_python_hello_emits_one_exact_write_then_stops(self):
        first_body = {
            "messages": [{"role": "user", "content": "make the file"}],
            "tools": [BASH_TOOL, WRITE_TOOL],
        }
        settings = Settings(0, 0, 0, "fake-model", scenario="python-hello")

        first, reason = build_completion(first_body, settings)

        self.assertEqual(reason, "tool_calls")
        call = first["choices"][0]["message"]["tool_calls"][0]
        self.assertEqual(call["function"]["name"], "write")
        arguments = json.loads(call["function"]["arguments"])
        self.assertEqual(
            arguments["file_path"],
            "hello.py",
        )
        self.assertEqual(arguments["content"], 'print("Hello, World!")\n')
        required = WRITE_TOOL["function"]["parameters"]["required"]
        self.assertTrue(set(required).issubset(arguments))
        self.assertIn("intent", arguments)
        self.assertIsInstance(arguments["intent"], str)
        self.assertTrue(arguments["intent"])

        second_body = {
            "messages": [
                *first_body["messages"],
                first["choices"][0]["message"],
                {"role": "tool", "tool_call_id": call["id"], "content": ""},
            ],
            "tools": [BASH_TOOL, WRITE_TOOL],
        }
        _, second_reason = build_completion(second_body, settings)
        self.assertEqual(second_reason, "stop")

    def test_python_hello_stops_after_write_even_if_turns_is_set(self):
        body = {
            "messages": [{"role": "user", "content": "make the file"}],
            "tools": [WRITE_TOOL],
        }
        settings = Settings(0, 0, 2, "fake-model", scenario="python-hello")
        first, _ = build_completion(body, settings)
        next_body = {
            "messages": [
                *body["messages"],
                first["choices"][0]["message"],
                {"role": "tool", "content": "ok"},
            ],
            "tools": [WRITE_TOOL],
        }

        _, reason = build_completion(next_body, settings)

        self.assertEqual(reason, "stop")

    def test_python_hello_rejects_missing_write_tool(self):
        body = {
            "messages": [{"role": "user", "content": "make the file"}],
            "tools": [BASH_TOOL],
        }

        with self.assertRaisesRegex(
            ScenarioConfigurationError, "requires a write tool"
        ):
            build_completion(body, Settings(0, 0, 0, "fake-model", scenario="python-hello"))

    def test_python_hello_rejects_schema_without_exact_content_field(self):
        invalid_tool = {
            **WRITE_TOOL,
            "function": {
                **WRITE_TOOL["function"],
                "parameters": {
                    "type": "object",
                    "properties": {"file_path": {"type": "string"}},
                    "required": ["file_path", "intent"],
                },
            },
        }

        with self.assertRaisesRegex(
            ScenarioConfigurationError, "both a file path and content field"
        ):
            build_completion(
                {"messages": [], "tools": [invalid_tool]},
                Settings(0, 0, 0, "fake-model", scenario="python-hello"),
            )

    def test_python_hello_rejects_schema_that_cannot_carry_exact_content(self):
        invalid_tool = {
            **WRITE_TOOL,
            "function": {
                **WRITE_TOOL["function"],
                "parameters": {
                    "type": "object",
                    "properties": {
                        "file_path": {"type": "string"},
                        "content": {"type": "string", "maxLength": 1},
                        "intent": {"type": "string"},
                    },
                    "required": ["file_path", "content", "intent"],
                },
            },
        }

        with self.assertRaisesRegex(
            ScenarioConfigurationError, "cannot carry the required exact content"
        ):
            build_completion(
                {"messages": [], "tools": [invalid_tool]},
                Settings(0, 0, 0, "fake-model", scenario="python-hello"),
            )

    def test_handler_returns_configuration_error_and_stays_alive(self):
        Handler.settings = Settings(0, 0, 0, "fake-model", scenario="python-hello")
        Handler.stats = Stats()
        Handler.verbose = False
        server = Server(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        url = f"http://127.0.0.1:{server.server_port}/v1/chat/completions"

        try:
            request = urllib.request.Request(
                url,
                data=json.dumps({"messages": [], "tools": [BASH_TOOL]}).encode(),
                headers={"Content-Type": "application/json"},
                method="POST",
            )
            with self.assertRaises(urllib.error.HTTPError) as caught:
                urllib.request.urlopen(request, timeout=2)
            self.assertEqual(caught.exception.code, 500)
            error = json.loads(caught.exception.read())["error"]
            self.assertEqual(error["type"], "scenario_configuration_error")

            valid_request = urllib.request.Request(
                url,
                data=json.dumps({"messages": [], "tools": [WRITE_TOOL]}).encode(),
                headers={"Content-Type": "application/json"},
                method="POST",
            )
            with urllib.request.urlopen(valid_request, timeout=2) as response:
                payload = json.loads(response.read())
            self.assertEqual(
                payload["choices"][0]["finish_reason"], "tool_calls"
            )
        finally:
            server.shutdown()
            thread.join(timeout=2)
            server.server_close()

    def test_generic_defaults_still_use_existing_turn_behavior(self):
        body = {
            "messages": [{"role": "user", "content": "hello"}],
            "tools": [LEGACY_WRITE_TOOL],
        }

        response, reason = build_completion(body, Settings(0, 0, 0, "fake-model"))

        self.assertEqual(reason, "stop")
        self.assertEqual(
            response["choices"][0]["message"]["content"], "Hello world. Done."
        )

    def test_generic_tool_synthesis_is_unchanged_when_enabled(self):
        body = {
            "messages": [{"role": "user", "content": "hello"}],
            "tools": [LEGACY_WRITE_TOOL],
        }

        response, reason = build_completion(body, Settings(0, 0, 1, "fake-model"))

        self.assertEqual(reason, "tool_calls")
        self.assertEqual(
            json.loads(
                response["choices"][0]["message"]["tool_calls"][0]["function"][
                    "arguments"
                ]
            ),
            {"filePath": "hello.txt", "content": "hello world\n"},
        )


if __name__ == "__main__":
    unittest.main()
