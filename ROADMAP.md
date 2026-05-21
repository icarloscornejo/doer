# WK Roadmap

Documento vivo. Captura las decisiones de diseno congeladas y el orden de implementacion de features pendientes.

## Decisiones congeladas (no renegociar)

```
PLUGIN
  technical name:  wk
  display name:    Doer Work Kit
  version:         6.0.0 (continua linaje desde doer 5.0.0)
  license:         MIT
  repo remote:     github.com/icarloscornejo/doer (sin cambio)
  dir local:       ~/src/doer (sin cambio)

SKILLS (5)
  /wk:doer ABC-123     core, orquestador 9 etapas (mantiene SKILL.md adelgazado)
  /wk:load PROJ-42     importar de tracker externo (placeholder en Fase 0)
  /wk:advise           review con personas configurables (placeholder)
  /wk:review           review de PRs ajenos (placeholder)
  /wk:publish ABC-123  MR + Jira transition opt-in (placeholder)

ESTRUCTURA OBJETIVO
  .claude-plugin/{plugin,marketplace}.json
  skills/{doer,load,advise,review,publish}/SKILL.md
  lib/{heartbeat,migrations,narration,workspace-guard,memory-paths}.md
  lib/{lock,inbox,cost}.md           stubs vacios en Fase 0, contenido en Fase 1+
  lib/cost-rates.json                stub vacio en Fase 0
  lib/helpers/                       carpeta creada vacia en Fase 0
  scripts/refresh-rates.sh           stub en Fase 0
  lessons/*.md (global)
  preferences.md (raiz, formato .md)
  AGENTS.md (ritual install)
  README.md, CHANGELOG.md, ROADMAP.md, LICENSE

ACOPLAMIENTO ENTRE SKILLS
  Hibrido pragmatico:
    fuerte (lee/escribe metadata.json) para satelites internos al pipeline
    debil (CLI propia + flags) para satelites con vida standalone

CONVENCIONES
  JSON para configs (manifests, presets, data) - NO YAML
  Markdown para protocolos, prosa, lessons
  Referencias lib/ con ${CLAUDE_PLUGIN_ROOT}/lib/<archivo>.md
  Em-dashes prohibidos (regla heredada de Core Principle 9 de doer)
```

## Fase 0: Reorganizacion estructural

Status: completada en version 6.0.0 (este commit).

Ver `CHANGELOG.md` para el detalle.

## Fase 1+: Tickets `WK-N` planeados

Cada uno se ejecuta como `/wk:doer WK-N` despues de Fase 0. Pipeline 9 etapas completo, lessons capturadas.

| # | Ticket | Tipo | Descripcion |
|---|---|---|---|
| ~~WK-1~~ | ~~implement lib/lock.md + helper~~ | LIB | **Done in 6.1.0**: per-ticket lock con TTL 30 min, steal-if-stale, abort-if-fresh. PID + host + heartbeat para diagnosticos |
| WK-2 | implement lib/inbox.md + helper | LIB | Mensajeria entre etapas: advisory / blocker / fyi |
| WK-3 | implement lib/cost.md + cost-rates.json + scripts/refresh-rates.sh | LIB | Tracking de costos, TTL semanal, fallback lazy |
| WK-4 | integrate pre-flight assumptions into Stage 2 | CORE | Tabla de checks ejecutables en spec antes de despachar plan |
| WK-5 | integrate per-task review gate into Stage 4 | CORE | Gate humano `[a]ccept / [e]dit / [r]eject / [s]kip / [v]iew-full-diff` con git reset |
| WK-6 | integrate parallel subagents into Stage 4 | CORE | Subagents en paralelo para tareas independientes |
| WK-7 | implement skills/load (Jira / Linear / GitHub import) | SATELITE | Carga de ticket desde tracker |
| WK-8 | implement skills/advise (configurable personas) | SATELITE | Personas JSON. Security / perf / mobile / a11y |
| WK-9 | implement skills/review (MR review with personas) | SATELITE | Review de PRs ajenos con advisors |
| WK-10 | implement skills/publish (MR + Jira transition) | SATELITE | Opt-in: MR creation + Jira state change |

## Convenciones del plugin

- JSON para configs (manifests, presets, data files). NO YAML.
- Markdown para protocolos, prosa, lessons.
- Em-dashes prohibidos en cualquier output del orquestador o sus subagents.
- Referencias entre archivos del plugin via `${CLAUDE_PLUGIN_ROOT}/lib/<archivo>.md`.
- Acoplamiento entre skills: hibrido pragmatico (fuerte para satelites internos al pipeline, debil para satelites con vida standalone).
