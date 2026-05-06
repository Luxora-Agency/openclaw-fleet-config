#!/usr/bin/env bash
# fleet-init.sh — hook que corre la imagen base coollabsio/openclaw via
# OPENCLAW_DOCKER_INIT_SCRIPT. Se ejecuta DESPUES del setup de /data y la
# validacion de gateway token + provider keys, pero ANTES de:
#   - configure.js (env → /data/.openclaw/openclaw.json)
#   - openclaw doctor --fix
#   - nginx + openclaw gateway run
#
# Por eso solo nos toca:
#   1) Resolver AGENT_ID (1er arg del compose command, o env var).
#   2) Re-exportar TELEGRAM_BOT_TOKEN/CHAT_ID con sufijo _<UPPER(ID)> para
#      que compile.py pueda expandir ${TELEGRAM_BOT_TOKEN_AGENT01}.
#   3) Clonar fleet-config (best-effort: si falla, usar la copia horneada).
#   4) Correr compile.py → escribir openclaw.json a $OPENCLAW_CUSTOM_CONFIG
#      (default /app/config/openclaw.json). configure.js del base lo lee
#      como capa base y le aplica env-driven overrides encima.
#   5) Materializar skills privadas en $OPENCLAW_BUNDLED_SKILLS_DIR.
#   6) Materializar hooks en $HOOKS_DIR.
#   7) Crear sandbox dirs.
#
# Vars (Coolify):
#   AGENT_ID                  ej. "agent01" — debe existir agents/${AGENT_ID}.yaml
#   FLEET_REF                 branch o tag (default: main)
#   FLEET_REPO_URL            default: https://github.com/Luxora-Agency/openclaw-fleet-config.git
#   SKILLS_REPO_URL           default: https://github.com/Luxora-Agency/openclaw-fleet-skills.git
#   SKILLS_REF                branch o tag del skills repo (default: main)
#   OPENCLAW_CUSTOM_CONFIG    default: /app/config/openclaw.json
#   OPENCLAW_BUNDLED_SKILLS_DIR  default: /data/.openclaw/skills
#   + todos los ${VAR} referenciados desde el YAML del agente

set -euo pipefail

# ── 1) Resolver AGENT_ID ─────────────────────────────────────────────────────
# La base entrypoint nos pasa los argumentos del compose `command`.
# Por eso `command: ["agent01"]` llega aqui como $1.
AGENT_ID="${1:-${AGENT_ID:-}}"
: "${AGENT_ID:?AGENT_ID is required (set via compose command: [\"agent01\"] or env var AGENT_ID)}"
: "${FLEET_REF:=main}"
: "${FLEET_REPO_URL:=https://github.com/Luxora-Agency/openclaw-fleet-config.git}"
: "${FLEET_DIR:=/opt/fleet}"
: "${SKILLS_REF:=main}"
: "${SKILLS_REPO_URL:=https://github.com/Luxora-Agency/openclaw-fleet-skills.git}"
: "${SKILLS_DIR:=/opt/skills}"
: "${HOOKS_DIR:=/opt/hooks}"
: "${OPENCLAW_CUSTOM_CONFIG:=/app/config/openclaw.json}"
: "${OPENCLAW_STATE_DIR:=/data/.openclaw}"
: "${OPENCLAW_BUNDLED_SKILLS_DIR:=$OPENCLAW_STATE_DIR/skills}"
: "${VENV_DIR:=/opt/venv}"

PYTHON_BIN="${VENV_DIR}/bin/python3"
[ -x "$PYTHON_BIN" ] || PYTHON_BIN="$(command -v python3)"

log() { printf '{"ts":"%s","level":"INFO","event":"fleet-init","agent":"%s","msg":"%s"}\n' "$(date -u +%FT%TZ)" "$AGENT_ID" "$1"; }
err() { printf '{"ts":"%s","level":"ERROR","event":"fleet-init","agent":"%s","msg":"%s"}\n' "$(date -u +%FT%TZ)" "$AGENT_ID" "$1" >&2; }

log "starting fleet init for agent=${AGENT_ID}"

# ── 2) Re-exportar env vars con sufijo _<UPPER(ID)> ──────────────────────────
# Coolify pasa TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID con nombres fijos (no puede
# interpolar dentro de keys YAML). El YAML del agente referencia
# ${TELEGRAM_BOT_TOKEN_AGENT01} — aqui lo creamos.
upper=$(printf '%s' "$AGENT_ID" | tr '[:lower:]-' '[:upper:]_')
if [ -n "${TELEGRAM_BOT_TOKEN:-}" ]; then
  export "TELEGRAM_BOT_TOKEN_${upper}=${TELEGRAM_BOT_TOKEN}"
fi
if [ -n "${TELEGRAM_CHAT_ID:-}" ]; then
  export "TELEGRAM_CHAT_ID_${upper}=${TELEGRAM_CHAT_ID}"
fi

# ── 3) Clonar fleet config (best-effort) ─────────────────────────────────────
# Si el repo es publico y la red esta arriba, clonar nos garantiza la version
# mas reciente. Si falla (red caida, repo privado sin token), caemos a la copia
# que el Dockerfile horneo en /opt/fleet-{scripts,profiles,agents,skills,hooks}.
SOURCE_DIR=""
if git ls-remote --exit-code "$FLEET_REPO_URL" "$FLEET_REF" >/dev/null 2>&1; then
  if [ ! -d "$FLEET_DIR/.git" ]; then
    log "cloning ${FLEET_REPO_URL}@${FLEET_REF}"
    rm -rf "$FLEET_DIR"
    git clone --depth 1 --branch "$FLEET_REF" "$FLEET_REPO_URL" "$FLEET_DIR"
  else
    log "fleet dir exists; pulling ${FLEET_REF}"
    git -C "$FLEET_DIR" fetch --depth 1 origin "$FLEET_REF"
    git -C "$FLEET_DIR" checkout -B "$FLEET_REF" "origin/${FLEET_REF}"
  fi
  SOURCE_DIR="$FLEET_DIR"
else
  err "git remote unreachable; falling back to baked-in copy at /opt/fleet-*"
  # Reconstruimos el layout esperado en $FLEET_DIR usando la copia horneada.
  rm -rf "$FLEET_DIR"
  mkdir -p "$FLEET_DIR"
  for sub in scripts profiles agents skills hooks; do
    [ -d "/opt/fleet-${sub}" ] && cp -r "/opt/fleet-${sub}" "$FLEET_DIR/${sub}"
  done
  SOURCE_DIR="$FLEET_DIR"
fi

# ── 4) Validar que el agente existe ──────────────────────────────────────────
AGENT_YAML="$SOURCE_DIR/agents/${AGENT_ID}.yaml"
if [ ! -f "$AGENT_YAML" ]; then
  err "agent file not found: agents/${AGENT_ID}.yaml in source=${SOURCE_DIR}"
  exit 2
fi

# ── 5) Compilar YAML → openclaw.json + fleet-policies.json + prompt.md ──────
# Escribimos al custom config mount (/app/config/openclaw.json) — la imagen
# base lo carga como capa baja y aplica env-driven overrides arriba.
# fleet-policies.json y prompt.md van al state dir para que skills/hooks
# privados los lean.
mkdir -p "$(dirname "$OPENCLAW_CUSTOM_CONFIG")" "$OPENCLAW_STATE_DIR"
log "compiling agent ${AGENT_ID} → $OPENCLAW_CUSTOM_CONFIG"
"$PYTHON_BIN" "$SOURCE_DIR/scripts/compile.py" \
  --base "$SOURCE_DIR/profiles/base.yaml" \
  --agent "$AGENT_YAML" \
  --out-dir "$OPENCLAW_STATE_DIR"

# El compile.py escribe openclaw.json en --out-dir; lo movemos al custom
# config path que la imagen base lee como capa baja.
if [ -f "$OPENCLAW_STATE_DIR/openclaw.json" ]; then
  mv "$OPENCLAW_STATE_DIR/openclaw.json" "$OPENCLAW_CUSTOM_CONFIG"
  chmod 600 "$OPENCLAW_CUSTOM_CONFIG"
  log "openclaw.json placed at $OPENCLAW_CUSTOM_CONFIG"
fi

# Borramos la copia persistida del boot anterior. configure.js del base hace
# deepMerge(custom, persisted) — sin este wipe, valores del boot pasado
# (e.g., voice_id antigua, modelo viejo) sobreescriben los del YAML nuevo
# y los cambios git push → redeploy no surten efecto hasta que el operador
# wipea el volume. Nuestra fuente de verdad es el YAML; la persistencia es
# solo cache de runtime (gateway.token, credentials/, agents/auth-profiles).
PERSISTED_CONFIG="${OPENCLAW_CONFIG_PATH:-$OPENCLAW_STATE_DIR/openclaw.json}"
if [ -f "$PERSISTED_CONFIG" ]; then
  rm -f "$PERSISTED_CONFIG"
  log "wiped stale persisted config at $PERSISTED_CONFIG (fleet redeploys are declarative)"
fi

# ── 6) Clonar skills repo y copiar al dir bundled ───────────────────────────
# Skills viven en un repo separado (Luxora-Agency/openclaw-fleet-skills) con
# las skills en la raiz. Si el clon falla, fallback al directorio horneado
# /opt/fleet-skills (poblado por el Dockerfile en build time desde el mismo
# repo). Si el fleet-config legacy todavia tiene un directorio skills/
# (durante transicion), tambien lo aceptamos como fallback adicional.
#
# Importante: cp -r y NO symlink. OpenClaw rechaza symlinks que apunten fuera
# del root bundled (security check bundled-symlink-escape en
# src/agents/skills/workspace.ts).
SKILLS_SOURCE_DIR=""
if git ls-remote --exit-code "$SKILLS_REPO_URL" "$SKILLS_REF" >/dev/null 2>&1; then
  if [ ! -d "$SKILLS_DIR/.git" ]; then
    log "cloning skills ${SKILLS_REPO_URL}@${SKILLS_REF}"
    rm -rf "$SKILLS_DIR"
    git clone --depth 1 --branch "$SKILLS_REF" "$SKILLS_REPO_URL" "$SKILLS_DIR"
  else
    log "skills dir exists; pulling ${SKILLS_REF}"
    git -C "$SKILLS_DIR" fetch --depth 1 origin "$SKILLS_REF"
    git -C "$SKILLS_DIR" checkout -B "$SKILLS_REF" "origin/${SKILLS_REF}"
  fi
  SKILLS_SOURCE_DIR="$SKILLS_DIR"
elif [ -d "/opt/fleet-skills" ]; then
  err "skills repo unreachable; falling back to baked-in /opt/fleet-skills"
  SKILLS_SOURCE_DIR="/opt/fleet-skills"
elif [ -d "$SOURCE_DIR/skills" ]; then
  err "skills repo unreachable; using legacy ${SOURCE_DIR}/skills (fleet-config inline)"
  SKILLS_SOURCE_DIR="$SOURCE_DIR/skills"
fi

mkdir -p "$OPENCLAW_BUNDLED_SKILLS_DIR"
mounted=0
if [ -n "$SKILLS_SOURCE_DIR" ]; then
  # The skills repo has skill directories at its root. Copy each subdirectory
  # that contains a SKILL.md file — skip anything else (.git, README.md, etc).
  for skill_dir in "$SKILLS_SOURCE_DIR"/*/; do
    [ -d "$skill_dir" ] || continue
    [ -f "$skill_dir/SKILL.md" ] || continue
    name=$(basename "$skill_dir")
    # Guard contra rm -rf con dir vacio.
    rm -rf "${OPENCLAW_BUNDLED_SKILLS_DIR:?}/${name}"
    cp -r "$skill_dir" "$OPENCLAW_BUNDLED_SKILLS_DIR/$name"
    mounted=$((mounted + 1))
  done
fi
log "copied $mounted private skills into $OPENCLAW_BUNDLED_SKILLS_DIR (source=${SKILLS_SOURCE_DIR:-none})"

# ── 7) Montar hooks (.ts) en /opt/hooks ─────────────────────────────────────
if [ -d "$SOURCE_DIR/hooks" ]; then
  for hook in "$SOURCE_DIR/hooks/"*.ts; do
    [ -f "$hook" ] || continue
    cp "$hook" "$HOOKS_DIR/"
    chmod +x "$HOOKS_DIR/$(basename "$hook")" 2>/dev/null || true
  done
fi
hooks_count=$(ls "$HOOKS_DIR"/*.ts 2>/dev/null | wc -l | tr -d ' ')
log "mounted $hooks_count hooks in $HOOKS_DIR"

# ── 8) Sandbox dir del agente ────────────────────────────────────────────────
SANDBOX="/tmp/agente-${AGENT_ID}"
mkdir -p "$SANDBOX"/{img,img-gen,tts,decks}
log "sandbox ready at $SANDBOX"

log "fleet init complete; handing back to base entrypoint"

# El base entrypoint continua: configure.js → doctor --fix → nginx → gateway.
# No exec aqui — solo retorno 0.
exit 0
