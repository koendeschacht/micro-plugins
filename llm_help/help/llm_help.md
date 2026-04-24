# llm_help

`llm_help` opens a chat buffer for asking an LLM for editor-side help.
Responses stream into the buffer as tokens arrive.

Commands:

* `llmhelp`: open the chat buffer in a horizontal split.
* `llmhelpsend`: send the current conversation to OpenAI.
* `llmhelpclear`: reset the conversation.

Settings:

* `llm_help.model`: OpenAI chat model to use.
  Default: `gpt-4.1-mini`

Environment:

* `OPENAI_API_KEY` must be set.
* `curl` must be available.

Conversation format:

Write prompts under `# User` headers. Responses are appended under `# Assistant`.

Suggested bindings:

* `<leader>hc`: open chat
* `Ctrl-Enter`: send prompt from the chat buffer
