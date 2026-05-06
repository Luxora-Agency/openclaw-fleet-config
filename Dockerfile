# OpenClaw Fleet — extiende la imagen oficial Coolify-friendly.
#
# Base: coollabsio/openclaw:latest (DockerHub) — la imagen "production-ready"
# que mantiene Coollabs (los autores de Coolify). Provee:
#   - openclaw CLI + bundled skills/plugins
#   - nginx reverse proxy (8080) → openclaw gateway (18789)
#   - basic auth opcional (AUTH_USERNAME/AUTH_PASSWORD)
#   - hook OPENCLAW_DOCKER_INIT_SCRIPT para correr nuestra logica del fleet
#     antes de configure.js + nginx + gateway
#   - Linuxbrew, Go, uv, build-essential ya horneados en /home/linuxbrew
#
# Todo lo que añadimos aqui es delta: ffmpeg/tesseract/poppler/imagemagick/
# python venv para nuestras skills privadas, mas el script de init que
# clona el fleet repo y corre compile.py.
#
# El mismo container corre cualquier agente declarado en `agents/<id>.yaml`,
# diferenciado por el primer arg del comando (compose: command: ["agent01"])
# o la env var AGENT_ID.

FROM coollabsio/openclaw:latest

# La imagen base corre como root; no cambiamos eso.

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    VENV_DIR=/opt/venv \
    FLEET_DIR=/opt/fleet \
    HOOKS_DIR=/opt/hooks

# Sistema: ffmpeg (audio/concat), tesseract+spa+eng (OCR), poppler (pdftoppm),
# imagemagick (identify para sensitive-image-gate), python+venv, jq, curl.
# git + ca-certificates + nginx ya estan en la imagen base.
RUN apt-get update && apt-get install -y --no-install-recommends \
      ffmpeg \
      tesseract-ocr tesseract-ocr-spa tesseract-ocr-eng \
      poppler-utils \
      imagemagick \
      python3 python3-venv python3-pip \
      jq \
      curl \
    && rm -rf /var/lib/apt/lists/*

# Permitir que ImageMagick lea PDFs (algunas distros lo deshabilitan por CVE-2016-3714).
# Probamos ambas rutas porque la base puede traer ImageMagick-6 o 7.
RUN for f in /etc/ImageMagick-6/policy.xml /etc/ImageMagick-7/policy.xml; do \
      [ -f "$f" ] && sed -i 's|<policy domain="coder" rights="none" pattern="PDF" />|<policy domain="coder" rights="read\|write" pattern="PDF" />|' "$f" || true; \
    done

# Venv para deps Python (limpio, no toca system Python). Recomendado en prod.
RUN python3 -m venv $VENV_DIR && \
    $VENV_DIR/bin/pip install --no-cache-dir --upgrade pip && \
    $VENV_DIR/bin/pip install --no-cache-dir \
      pyyaml \
      pillow \
      pillow-heif \
      pdfplumber \
      pymupdf \
      langdetect

ENV PATH="$VENV_DIR/bin:$PATH"

# Pre-creamos los dirs que nuestro init usa. /data lo crea el entrypoint base
# despues de montar el volume; aqui solo dejamos los dirs que NO viven en /data.
RUN mkdir -p $FLEET_DIR $HOOKS_DIR /var/log/agente /app/config && \
    chmod 755 $FLEET_DIR $HOOKS_DIR /app/config && \
    chmod 700 /var/log/agente

# Copiamos:
#   - el init hook (lo que el base llama via OPENCLAW_DOCKER_INIT_SCRIPT)
#   - una copia local del compile.py + scripts (sirve si FLEET_REPO_URL falla
#     o si querés correr la imagen sin acceso a git)
COPY entrypoint.sh /opt/fleet-init.sh
COPY scripts/ /opt/fleet-scripts/
COPY profiles/ /opt/fleet-profiles/
COPY agents/ /opt/fleet-agents/
COPY hooks/ /opt/fleet-hooks/

# Skills viven en un repo aparte (Luxora-Agency/openclaw-fleet-skills). En
# runtime el entrypoint clona la version mas reciente; aqui horneamos una
# copia como fallback para cuando la red runtime falle. ARGs permiten apuntar
# a un fork o un tag especifico al construir la imagen.
ARG SKILLS_REPO_URL=https://github.com/Luxora-Agency/openclaw-fleet-skills.git
ARG SKILLS_REF=main
RUN git clone --depth 1 --branch "$SKILLS_REF" "$SKILLS_REPO_URL" /opt/fleet-skills && \
    rm -rf /opt/fleet-skills/.git

RUN chmod +x /opt/fleet-init.sh /opt/fleet-scripts/*.sh 2>/dev/null || true

# La imagen base ya define ENTRYPOINT y HEALTHCHECK; los respetamos.
# El entrypoint base hace:
#   1) setup persistent storage en /data
#   2) valida OPENCLAW_GATEWAY_TOKEN + 1 LLM provider
#   3) corre OPENCLAW_DOCKER_INIT_SCRIPT (= /opt/fleet-init.sh)  ← nuestro hook
#   4) corre configure.js (env → openclaw.json, layer-merge con custom config)
#   5) openclaw doctor --fix
#   6) genera nginx config
#   7) arranca nginx + openclaw gateway run
#
# EXPOSE 8080 ya esta heredado del base.
