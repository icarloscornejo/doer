# Doer Work Kit (`wk`)

Plugin de Claude Code para ejecucion end-to-end de tickets de desarrollo. Toma un ticket pre-definido y lo lleva desde acceptance criteria hasta codigo listo en una rama feature, justo antes del PR.

## Instalacion

```bash
# 1. Registrar el marketplace
claude plugin marketplace add https://github.com/icarloscornejo/doer.git

# 2. Instalar el plugin
claude plugin install wk@wk

# 3. Verificar
claude plugin list
```

Tras instalar, las 5 skills estan disponibles:

```
/wk:doer ABC-123       # orquestador del pipeline 9 etapas (skill core)
/wk:load PROJ-42       # importar ticket desde Jira / Linear / GitHub
/wk:advise             # revisar specs/AC/codigo con personas configurables
/wk:review             # revisar PRs ajenos
/wk:publish ABC-123    # crear MR + transicion Jira (opt-in)
```

Las 4 skills satelite (`load`, `advise`, `review`, `publish`) son placeholders en la version 6.0.0; sus implementaciones llegan en tickets `WK-7` a `WK-10` (ver ROADMAP.md).

## Setup inicial

Despues de instalar, edita estos archivos en `~/.claude/plugins/cache/wk/` (o donde Claude Code haya cacheado el plugin):

- `preferences.md`: locale (`es` / `en`) y otras preferencias personales.
- `lessons/`: las 5 lessons iniciales se incluyen. El plugin las acumula al cerrar tickets.

## Estructura del repo

```
doer/
|- .claude-plugin/plugin.json     # manifest oficial
|- .claude-plugin/marketplace.json
|- skills/                        # 5 skills
|  |- doer/                       # orquestador (la unica operacional en 6.0.0)
|  |- load/                       # placeholder
|  |- advise/                     # placeholder
|  |- review/                     # placeholder
|  |- publish/                    # placeholder
|- lib/                           # protocolos compartidos
|  |- heartbeat.md                # anti-compactacion
|  |- migrations.md               # versioning + auto-migrate
|  |- narration.md                # Core Principle 1, em-dash rule, locale
|  |- workspace-guard.md          # check de instalacion + .doer/ exclude
|  |- memory-paths.md             # paths canonicos + schema metadata.json
|  |- lock.md                     # stub (WK-1)
|  |- inbox.md                    # stub (WK-2)
|  |- cost.md                     # stub (WK-3)
|  |- cost-rates.json             # stub (WK-3)
|  |- helpers/                    # scripts ejecutables (vacio en 6.0.0)
|- scripts/refresh-rates.sh       # stub (WK-3)
|- lessons/                       # global, cross-project (5 archivos)
|- preferences.md                 # config personal
|- ROADMAP.md                     # decisiones de diseno + roadmap Fase 1+
```

## Para Claude que recibe este repo

Si el usuario te pega la URL de este repo y dice "instala esto", ejecuta el ritual de arriba.

Si pide "ayudame a usarlo", lee `skills/doer/SKILL.md` (es el orquestador, contiene el flujo completo de 9 etapas).

Si pide "agrega una feature al plugin", revisa `ROADMAP.md` para ver el orden de tickets `WK-N` planeados.

## Licencia

MIT. Ver `LICENSE`.
