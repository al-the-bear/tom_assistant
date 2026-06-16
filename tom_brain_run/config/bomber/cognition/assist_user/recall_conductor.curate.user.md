Decide whether the memory surfaced so far is enough to answer the user's prompt, then either ask for more or curate the set the answer stage will use.

User prompt:
${prompt}

Surfaced memory (one per line, `nodeId :: summary`):
${surfaced}

Reply using ONLY these line directives, one per line, and nothing else:

- `SUFFICIENT: yes` or `SUFFICIENT: no` — your overall judgement (informational).
- `SEARCH: <kind> <query>` — request a targeted re-search. `<kind>` is one of: old, cold, prompts, answers, multi, recall. Use these when the surfaced set is missing something the prompt needs (e.g. older or rarely-used memory).
- `KEEP: <nodeId> | <one-line reason>` — curate a surfaced node into the final set. Use the exact id from the surfaced list.

Rules:
- If the surfaced set is enough, emit only `KEEP:` lines (one per node worth keeping) — this ends the curation.
- If it is not enough, emit `SEARCH:` lines instead; you will see the new results next round.
- Keep only nodes that genuinely help answer the prompt; prefer a small set over padding. Never invent an id that is not in the surfaced list.
