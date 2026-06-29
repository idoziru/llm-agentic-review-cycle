# Documentation — llm-agentic-review-cycle (for AI developers)

These documents are written for an AI agent that will **maintain and extend**
the `llm-agentic-review-cycle` project. They describe internal structure and invariants,
not user-facing scenarios.

Sources of truth (not duplicated here):
- User installation and usage → [../README.md](../README.md)
- Implementation → [../arc](../arc), prompts → [../prompts/](../prompts/),
  models → [../models.md](../models.md)

## Documentation map

| File | About |
|---|---|
| [architecture.md](architecture.md) | Execution model: orchestrator + stateless agents, data and control flows |
| [code-map.md](code-map.md) | Structure of `arc`: functions, responsibilities, navigation |
| [contracts.md](contracts.md) | Invariants that must not be broken: verdict, placeholders, file schemas |
| [extending.md](extending.md) | How to add a model / prompt / phase / new CLI |
| [testing.md](testing.md) | How to verify without spending tokens; mock agent; `.pyc` trap |
| [gotchas.md](gotchas.md) | Known limitations and pitfalls |

## Where to start

1. Read [architecture.md](architecture.md) and [code-map.md](code-map.md) — how it works.
2. Before making changes, cross-check with [contracts.md](contracts.md).
3. Extending functionality — follow [extending.md](extending.md).
4. Verify any change using [testing.md](testing.md) (without real CLI calls).
