.PHONY: verify syntax bootstrap scan

verify: syntax scan

syntax:
	bash -n scripts/*.sh scripts/lib/*.sh
	node --check bridges/openai-compatible-responses-bridge.mjs
	node --check bridges/codex-automations-mcp.mjs
	node --check bridges/codex-automations-runner.mjs

bootstrap:
	./scripts/bootstrap.sh

scan:
	! rg -n 'sk-[A-Za-z0-9_-]{20,}|/home/adem|Belgeler|statmerce|MINIMAX_API_KEY="sk-' . --glob '!Makefile'
