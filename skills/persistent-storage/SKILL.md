---
name: persistent-storage
description: Consultar SIEMPRE antes de instalar dependencias, descargar modelos, cachear archivos pesados o escribir artefactos de larga vida. Establece donde van las cosas para que sobrevivan al reinicio del contenedor — solo `/data/` persiste. Aplica a presentations, audio-transcribe, image-generate, file-deliver y cualquier skill que `npm install`, `pip install`, `brew install`, descargue modelos, o genere PDFs/audios/imagenes que el usuario pueda volver a pedir.
metadata:
  visibility: private
  scope: agentes-fleet
---

# persistent-storage

**Toda la skill se trata de UNA pregunta: ¿esto sobrevive al reinicio del contenedor?**

Si la respuesta debe ser "sí" — `node_modules`, modelos, caches, presentations, decks, audios, transcripts, PDFs entregables, perfiles de auth, memoria — entonces el archivo debe vivir bajo `/data/`. Cualquier otra ruta se pierde cuando Coolify redeploya, cuando se reinicia el contenedor, o cuando el host hace pull de una imagen nueva.

## Layout del volumen `/data/`

El runtime monta `/data/` como volumen Docker persistente del agente (uno por agente, ej. `agent01_data`). El init-script de OpenClaw establece estas variables — usalas, no hardcodees rutas:

```
OPENCLAW_STATE_DIR=/data/.openclaw         # estado del harness
OPENCLAW_WORKSPACE_DIR=/data/workspace     # artefactos del usuario
```

Layout recomendado dentro de `/data/`:

```
/data/
├── .openclaw/
│   ├── skills/<skill-name>/              # node_modules, venvs, blobs de la skill
│   │   ├── node_modules/                 # ej. presentations
│   │   ├── .venv/                        # ej. pdf-read-with-ocr-fallback
│   │   └── cache/                        # caches privados de la skill
│   ├── cache/                            # caches compartidos entre skills
│   │   ├── huggingface/                  # HF_HOME / TRANSFORMERS_CACHE
│   │   ├── puppeteer/                    # PUPPETEER_CACHE_DIR
│   │   └── pip/                          # PIP_CACHE_DIR
│   ├── agents/<agent-id>/                # auth profiles, memoria — gestionado por el harness
│   ├── credentials/                      # creds del harness — no tocar
│   └── openclaw.json                     # config compilada — re-escrita en cada boot
└── workspace/
    ├── decks/<deck-id>/                  # presentations: project + PDFs entregables
    ├── audio/<request-id>/               # tts-emit / audio-transcribe outputs
    ├── images/<request-id>/              # image-generate outputs
    ├── pdfs/<doc-id>/                    # pdf-read-with-ocr-fallback intermedios
    └── downloads/                        # web-fetch / file-deliver scratch
```

`/data/.openclaw/` lo gestiona principalmente el harness (state, perfiles, openclaw.json) — **no hagas `rm -rf` ahí**. Para tus dependencias y caches usá `/data/.openclaw/skills/<tu-skill>/` y `/data/.openclaw/cache/<bucket>/`. Para artefactos que el usuario podría volver a descargar, `/data/workspace/<categoria>/<id>/`.

## Anti-patrones — NUNCA usar para nada que importe

| Ruta | Por qué se pierde |
|---|---|
| `/tmp`, `/var/tmp` | Borrado al reinicio. Algunos sistemas lo limpian periódicamente incluso en runtime. |
| `~`, `/root`, `/home/*` | Capa de imagen base — se pierde con cada `docker pull` / rebuild. |
| `/app` y subpaths | Mismo problema — capa de imagen, no del volumen. |
| Working directory del proceso (`process.cwd()`) | Suele ser `/app` o `/`; ver arriba. |
| Globales del runtime: `~/.npm`, `~/.cache`, `~/.local`, `~/.cargo`, `~/.brew` | Capa de imagen. |
| Defaults de Puppeteer (`/root/.cache/puppeteer`), HuggingFace (`~/.cache/huggingface`), pip (`~/.cache/pip`) | Capa de imagen — **redirigir con env vars** (ver tabla abajo). |

Si una herramienta insiste en escribir a una ruta no persistente: o le pasás un argumento explícito apuntando a `/data/...`, o le seteás la env var de cache que respete (ver siguiente sección), o creás un symlink desde la ruta default hacia `/data/...` al primer arranque.

## Env vars de cache que tu skill puede setear

Antes de instalar/descargar, exportá las que apliquen para que las herramientas escriban directo a `/data/`:

```bash
# Node / npm / pnpm
export NPM_CONFIG_CACHE=/data/.openclaw/cache/npm
export PNPM_HOME=/data/.openclaw/cache/pnpm
export PUPPETEER_CACHE_DIR=/data/.openclaw/cache/puppeteer

# Python / pip / uv
export PIP_CACHE_DIR=/data/.openclaw/cache/pip
export UV_CACHE_DIR=/data/.openclaw/cache/uv
export PYTHONUSERBASE=/data/.openclaw/cache/python-user

# Hugging Face / Transformers / Sentence-Transformers
export HF_HOME=/data/.openclaw/cache/huggingface
export TRANSFORMERS_CACHE=/data/.openclaw/cache/huggingface/transformers

# General
export XDG_CACHE_HOME=/data/.openclaw/cache/xdg
```

## Patrón canónico — instalar dependencias dentro de una skill

Antes de cualquier `npm install` / `pip install` / descarga de modelo, garantizar que el destino existe en `/data/` y luego instalar **ahí**:

```bash
SKILL_DIR=/data/.openclaw/skills/<skill-name>
mkdir -p "$SKILL_DIR"
cd "$SKILL_DIR"

# Node (presentations, image-generate con node libs, etc.)
export NPM_CONFIG_CACHE=/data/.openclaw/cache/npm
export PUPPETEER_CACHE_DIR=/data/.openclaw/cache/puppeteer
[ -f package.json ] || npm init -y
npm install --no-fund --no-audit reveal.js puppeteer

# Python (pdf-read-with-ocr-fallback, audio-transcribe, etc.)
export PIP_CACHE_DIR=/data/.openclaw/cache/pip
[ -d .venv ] || python3 -m venv .venv
. .venv/bin/activate
pip install --upgrade pip
pip install pytesseract pdf2image
```

**Detección de instalación previa**: si `node_modules/` o `.venv/` ya existe en `$SKILL_DIR`, NO reinstalar. Skip directo a usar las dependencias. Solo reinstalar si una versión específica de una librería falla al cargar (mensaje claro de error que no es un MODULE_NOT_FOUND simple).

## Patrón canónico — escribir artefactos del usuario

Cualquier archivo que el usuario podría volver a pedir ("mandame el deck que generamos ayer", "reenviame ese audio") va en `/data/workspace/<categoria>/<id>/`:

```
/data/workspace/decks/<deck-id>/build/<name>_v<N>.pdf
/data/workspace/audio/<request-id>/<name>.mp3
/data/workspace/images/<request-id>/<name>.png
```

Si la skill ya tiene una version "vN" del artefacto, computar `N+1` listando el directorio del usuario — no sobrescribir. Asi el usuario puede pedir "mandame la version 2" si la 3 quedo peor.

## Aplicado a las skills actuales del fleet

Mapeo de los paths que las skills usan hoy (algunos hardcoded en `/tmp/...`) al lugar correcto en `/data/`. Si tu skill todavía escribe a `/tmp`, migrar:

| Skill | Antes (efímero) | Despues (persistente) |
|---|---|---|
| `presentations` | `/tmp/agente-<id>/decks/<name>_v<N>/` (project + node_modules) | **deps**: `/data/.openclaw/skills/presentations/node_modules/` (compartido entre decks) · **project + PDF**: `/data/workspace/decks/<deck-id>_v<N>/` |
| `audio-transcribe` | `/tmp/...` | `/data/workspace/audio/<request-id>/` (transcripts y audios fuente) · cache de modelos en `$HF_HOME` (= `/data/.openclaw/cache/huggingface`) |
| `tts-emit` (minimax / openai / elevenlabs) | `/tmp/...` | `/data/workspace/audio/<request-id>/` |
| `image-generate` | `/tmp/...` | `/data/workspace/images/<request-id>/` · cache de modelos en `$HF_HOME` |
| `image-preprocess` | `/tmp/...` | `/data/workspace/images/<request-id>/preprocessed/` |
| `pdf-read-with-ocr-fallback` | `/tmp/...` y `~/.local/...` | **venv + tesseract data**: `/data/.openclaw/skills/pdf-read-with-ocr-fallback/.venv/` · **PDFs intermedios**: `/data/workspace/pdfs/<doc-id>/` |
| `file-deliver` | scratch en `/tmp` | scratch en `/data/workspace/downloads/` |
| `web-fetch` | sin estado | si necesita cache de pagina, `/data/.openclaw/cache/web-fetch/` |

**Nota especial sobre `presentations`**: la version actual escribe `project_dir = /tmp/agente-<id>/decks/<name>_v<version>/` y corre `npm install` ahí adentro. Eso reinstala reveal.js + puppeteer + chromium binary cada vez que el contenedor reinicia (varios cientos de MB de descarga). Migracion correcta:

1. **deps de la skill** — un solo `node_modules` compartido en `/data/.openclaw/skills/presentations/node_modules/`. Instalar una vez en el primer uso, reusar para todos los decks. `chromium` de puppeteer queda cacheado en `/data/.openclaw/cache/puppeteer/`.
2. **proyecto del deck** — copiar templates a `/data/workspace/decks/<deck-id>_v<N>/` y enlazar (`ln -s` o `npm link`) a `node_modules` de la skill, o ejecutar `npm install --offline` apuntando al cache.
3. **PDF entregable** — `/data/workspace/decks/<deck-id>_v<N>/build/<name>.pdf`. `file-deliver` lee de ahi.

## Healthcheck que tu skill puede correr al primer arranque

Para verificar que `/data/` esta montado y escribible antes de hacer nada destructivo:

```bash
test -d /data || { echo "FATAL: /data not mounted — refusing to install"; exit 1; }
test -w /data || { echo "FATAL: /data not writable as $(id -un)"; exit 1; }
df -h /data | tail -1
```

Si falla, **NO** caer back a `/tmp` — eso esconde el problema. Reportar al usuario que el volumen no esta disponible.

## Cuando dudes

Regla mnemonica: **"Si lo va a pedir el usuario otra vez, va a `/data/workspace/`. Si la skill lo necesita la próxima vez, va a `/data/.openclaw/skills/<skill>/`."** Cualquier otra ruta es scratch y se pierde.
