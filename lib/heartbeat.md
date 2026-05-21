# Context Continuity (Anti-Compaction)

Status: protocol shared by all skills in the `wk` plugin.


### Why the old conditional self-check failed

The previous design asked the orchestrator to self-assess whether its context was fresh by trying to recall a known anchor string. This is unreliable: after compaction the anchor string appears verbatim in the conversation summary, so the model always answers "yes, I can recall it" and skips re-hydration even when SKILL.md rules are gone from context. A self-referential freshness test cannot detect its own staleness.

### Transition Sync (unconditional)

**At every stage transition AND at every `/doer continue` invocation (including implicit resumes after natural-language messages), the orchestrator MUST perform a Transition Sync as its FIRST action, before any stage logic. No exceptions. No skip path.**

The sync is three Read calls. Total cost: ~3 tool calls per transition, which the orchestrator already makes to read metadata anyway.

**Transition Sync steps:**

1. Narrate: *"Transition Sync."* (one line; signals to the dev that the sync ran)
2. Read `${CLAUDE_PLUGIN_ROOT}/preferences.md` → re-establish operating locale. Immediately commit ALL output to that locale for the rest of the session. Narrate the locale confirmation IN that language as the very next sentence (e.g. `"Locale: es. Todo el output de ahora en adelante en español."`). If the next output line is in the wrong language, that is a VIOLATION.
3. Read `./.doer/tickets/<TICKET-ID>/metadata.json` → re-establish ticket state, `current_stage`, prior `changelog` / `code_review` entries.
4. Read the relevant section of `SKILL.md` for `metadata.current_stage` (e.g. if `current_stage` is 4, re-read the "Stage 4. Code" section). One section, not the whole file.
5. Narrate in the locale language: *"Sync complete. Stage <N> (<name>), locale <locale>."*
6. Run Migration Check Phase 1 + Phase 2 (see `${CLAUDE_PLUGIN_ROOT}/lib/migrations.md`). If `metadata.skill_version` is behind the SKILL frontmatter, apply migrations now.
7. Continue with the stage logic.

> **DOER-HEARTBEAT-v3: every action narrated, every field validated, every SHA full-length, every Migration Check explicit.**

(This anchor line is kept for historical reference in lesson notes. It is no longer used as a freshness test — the Transition Sync is unconditional.)

**Locale re-check:** At the next stage transition after any sync, the orchestrator MUST verify its output language matches `preferences.md`. Locale drift after a sync is prohibited.

