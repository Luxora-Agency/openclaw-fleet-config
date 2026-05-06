# OpenClaw Fleet Config

Configuracion declarativa para una flota de agentes
[OpenClaw](https://github.com/openclaw/openclaw) desplegados en Coolify,
extendiendo la imagen oficial [`coollabsio/openclaw`](https://github.com/coollabsio/openclaw)
(la mantenida por los autores de Coolify, "production-ready").

> **Status:** alpha. **Solo agent01** habilitado para QA del flujo end-to-end.
> Los agentes 02–04 vuelven cuando este pase la revision.

## Estructura

```
.
├── Dockerfile                       # extiende coollabsio/openclaw:latest + ffmpeg/tesseract/poppler/Python venv
├── entrypoint.sh                    # init script que llama la imagen base via OPENCLAW_DOCKER_INIT_SCRIPT
├── docker-compose.coolify.yml       # 1 service (agent01) para Coolify
├── scripts/
│   └── compile.py                   # YAML merge + ${VAR} expansion → openclaw.json
├── profiles/
│   └── base.yaml                    # defaults heredados por todos los agentes
├── agents/
│   ├── _example.yaml                # template — copia, renombra, edita
│   └── agent01.yaml                 # slot de prueba
└── hooks/                           # hooks .ts (PreToolUse/PostToolUse/SessionStart)
    ├── secret-redaction.ts
    ├── path-scrubber.ts
    ├── sensitive-image-gate.ts
    ├── confirm-high-impact.ts
    ├── rate-limit.ts
    ├── structured-logger.ts
    └── crash-recovery.ts
```

## Arquitectura del runtime

```
Coolify Project
└── Resource (1 stack docker-compose)
    └── service: agent01
        └── container (imagen: build local sobre coollabsio/openclaw:latest)
            ├── /app/scripts/entrypoint.sh   ← entrypoint OFICIAL del base
            │     1. setup persistent /data
            │     2. valida OPENCLAW_GATEWAY_TOKEN + 1 LLM provider
            │     3. corre OPENCLAW_DOCKER_INIT_SCRIPT (= /opt/fleet-init.sh)  ← NUESTRO HOOK
            │           a. clone fleet-config (best-effort, fallback a copia horneada)
            │           b. compile.py → /app/config/openclaw.json
            │           c. wipe stale /data/.openclaw/openclaw.json
            │           d. clone fleet-skills (Luxora-Agency/openclaw-fleet-skills,
            │              best-effort) y cp /opt/skills/* → /data/.openclaw/skills/
            │           e. cp hooks/  → /opt/hooks/
            │     4. configure.js (custom JSON + env vars → /data/.openclaw/openclaw.json)
            │     5. openclaw doctor --fix
            │     6. nginx reverse proxy (8080 → 18789, basic auth opcional)
            │     7. exec openclaw gateway run
            └── volumes
                ├── agent01_data  → /data         (state, workspace, tools cache)
                └── agent01_logs  → /var/log/agente
```

## Crear el Resource

1. Coolify → **+ New Application** → **Public Repository**.
2. URL: `https://github.com/Luxora-Agency/openclaw-fleet-config`. Branch: `main`.
   Skills viven en repo aparte: `https://github.com/Luxora-Agency/openclaw-fleet-skills`.
3. **Build Pack: Docker Compose**.
4. Compose file location: `/docker-compose.coolify.yml`.
5. Save → Coolify auto-detecta los `${VAR_*}` y los muestra vacios.

### Setear env vars

**Globales** (Project env, una sola vez):

```
OPENCLAW_GATEWAY_TOKEN=<openssl rand -hex 32>   # REQUERIDA por la imagen base
AUTH_PASSWORD=<password para nginx basic auth>  # opcional pero recomendado para exposicion publica
MINIMAX_API_KEY=...
FIRECRAWL_API_KEY=...
ELEVENLABS_API_KEY=...
R2_BUCKET=...
R2_ACCESS_KEY_ID=...
R2_SECRET_ACCESS_KEY=...
```

**Per-agent** (Resource env, sufijo `_AGENT01`):

```
OPENAI_API_KEY_AGENT01=<la del participante>
GEMINI_API_KEY_AGENT01=<idem>
TELEGRAM_BOT_TOKEN_AGENT01=<bot del participante>
TELEGRAM_CHAT_ID_AGENT01=<chat del participante>
```

6. Deploy. Coolify buildea sobre la imagen oficial de Coollabs y arranca el
   container de agent01 con su `AGENT_ID=agent01`.

### Asignar a un participante

```bash
$EDITOR agents/agent01.yaml
# - identity.name → nombre del participante
# - identity.owner → email del participante
# - judgment_rules → memoria/personalidad inicial si quieres custom
git commit -am "fleet: assign agent01 to <participant>" && git push
```

Coolify recibe el webhook y redeploya en ~30s. El volume persiste, asi que
auth profiles + memoria de Telegram + credentials sobreviven al redeploy.

## Pipeline de cambios

```
edit agents/<id>.yaml → git push → Coolify webhook → redeploy → ~30s vivo
```

**Importante:** la imagen base persiste el config compilado en
`/data/.openclaw/openclaw.json`, pero nuestro init script lo wipea en cada
boot porque la fuente declarativa de verdad es el YAML del repo. Lo unico
que persiste real es lo que el harness escribe a runtime: `gateway.token`,
`credentials/`, `agents/<id>/auth-profiles.json`, `memory/`, `bindings/`.

## Secrets

Patron: **default global con override per-agent**. Coolify implementa la
herencia nativa — Resource env > Project env. La fuente de verdad real es
la UI de Coolify; este repo solo documenta la convencion en
`profiles/base.yaml -> secrets_ref` y warnea si una key per-agent
falta al compilar.

| Variable | Scope default | Donde la seteas | Override per-agent? |
|---|---|---|---|
| `OPENCLAW_GATEWAY_TOKEN` | global (o per-agent si quieres aislar) | Coolify Project env | si |
| `AUTH_PASSWORD` | global | Coolify Project env | si |
| `OPENAI_API_KEY` | **per-agent** | Coolify Resource env | siempre |
| `GEMINI_API_KEY` | **per-agent** | Coolify Resource env | siempre |
| `MINIMAX_API_KEY` | global | Coolify Project env | si |
| `FIRECRAWL_API_KEY` | global | Coolify Project env | si |
| `ELEVENLABS_API_KEY` | global | Coolify Project env | si |
| `R2_BUCKET`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY` | global | Coolify Project env | si |
| `TELEGRAM_BOT_TOKEN` | per-agent | Coolify Resource env | siempre (entrypoint lo renombra a `TELEGRAM_BOT_TOKEN_<UPPER(AGENT_ID)>`) |
| `TELEGRAM_CHAT_ID` | per-agent | Coolify Resource env | siempre (idem) |

**Mover una key entre scopes** son 30 segundos:

1. Borrar la var del Project env en Coolify.
2. Setear la var en cada Resource individualmente.
3. (Opcional) actualizar `secrets_ref` en `profiles/base.yaml`.

Sin rebuild, sin redeploy del image, sin tocar codigo.

**Nunca** commitees valores reales. Solo `${VAR_NAME}` en los YAML.

## Hooks: estado de wiring

Los `.ts` de `hooks/` son scripts standalone (PreToolUse/PostToolUse/SessionStart)
listos para ejecutar pero **el harness de OpenClaw todavia no los invoca**
automaticamente — se montan en `/opt/hooks/` y se referencian en
`fleet-policies.json` para que un futuro `extensions/fleet-hooks/` los registre.

## Validacion local

```bash
pip install pyyaml
python3 scripts/compile.py \
  --base profiles/base.yaml \
  --agent agents/agent01.yaml \
  --out-dir /tmp/test-compile
ls /tmp/test-compile/
# openclaw.json  fleet-policies.json  prompt.md
```

## Healthcheck

`/healthz` (puerto 8080) lo expone nginx del base sin pasar por basic auth,
asi que Coolify y cualquier load balancer externo pueden chequearlo sin
autenticarse. Internamente nginx hace bypass al gateway en `:18789`.

## Licencia

MIT. Ver `LICENSE`.
