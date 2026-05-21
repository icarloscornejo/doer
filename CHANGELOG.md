# Changelog

Todas las versiones siguen SemVer. Para detalles de migraciones, ver `lib/migrations.md`.

## 6.1.0 (WK-1: per-ticket lock)

**Tipo:** MINOR (additive, no schema change).

### Cambios

- `lib/lock.md` operacional: spec del lock per-ticket (file en `.doer/tickets/<ID>/lock.json`, TTL 30 min, steal-if-stale, abort-if-fresh).
- `lib/helpers/lock.sh` ejecutable: subcomandos `acquire`, `touch`, `release`, `check`. Sin dependencias mas alla de bash + opcionalmente jq.
- Workspace Guard: nuevo step 7 invoca `lock.sh acquire`. Si retorna != 0, el orquestador detiene el run.
- Stage 9 wrapup: nuevo step 10 invoca `lock.sh release`.
- Narration Protocol: cada stage transition invoca `lock.sh touch` para refrescar el heartbeat.

### Runtime

- Sesiones concurrentes en el mismo ticket fallan fast con un mensaje claro (PID + host + last touched). El user resuelve manualmente.
- Override del TTL por env var `WK_LOCK_TTL_SECONDS=<segundos>`.

### Migracion automatica

Tickets con `skill_version: "6.0.0"` bumpean a `6.1.0` al primer `/wk:doer continue <ID>`. Sin rewrites de archivos. Ver bloque `6.0.0 -> 6.1.0` en `lib/migrations.md`.

## 6.0.0 (Fase 0 plugin migration)

**Tipo:** MAJOR (estructural, no de runtime).

### Cambios

- Repo reorganizado como plugin formal de Claude Code (`wk`).
- Skill `doer` movida a `skills/doer/SKILL.md`. Invocacion ahora es `/wk:doer ABC-123` (compat: `/doer ABC-123` sigue funcionando).
- Manifest oficial agregado en `.claude-plugin/plugin.json` y catalogo en `.claude-plugin/marketplace.json`.
- Protocolos compartidos extraidos del SKILL.md a `lib/`:
  - `lib/heartbeat.md` (anti-compactacion)
  - `lib/migrations.md` (versioning + auto-migrate)
  - `lib/narration.md` (Core Principle 1, em-dash rule, locale)
  - `lib/workspace-guard.md`
  - `lib/memory-paths.md` (paths + schema metadata.json)
- Placeholders agregados para 4 satelites planeados: `load`, `advise`, `review`, `publish`. Sus implementaciones llegan en `WK-7` a `WK-10`.
- Stubs agregados para 3 lib futuros: `lock.md`, `inbox.md`, `cost.md`. Implementaciones en `WK-1` a `WK-3`.
- AGENTS.md agregado para ritual de install via marketplace.
- ROADMAP.md agregado con decisiones congeladas + tickets pendientes Fase 1+.
- README.md actualizado para formato plugin.

### Runtime

- Sin cambio en el comportamiento del pipeline 9 etapas.
- `metadata.json` schema sin cambio.
- Lessons globales: mismo path en disco, resolver actualizado a `${CLAUDE_PLUGIN_ROOT}/lessons/`.

### Migracion automatica

Tickets en flight con `skill_version: "5.0.0"` migran al primer `/wk:doer continue <ID>` despues de actualizar el plugin. Ver bloque `5.0.0 -> 6.0.0` en `lib/migrations.md`.

## Versiones anteriores

(documentadas inline en el bloque `## Versioning & Migrations` del `skills/doer/SKILL.md`, que a partir de 6.0.0 referencia `lib/migrations.md`)
