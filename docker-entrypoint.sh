#!/bin/sh
set -e

# --- Détection automatique du port d'écoute -------------------------------
# Ordre de priorité :
#   1. Variable d'environnement PORT fournie par la plateforme d'hébergement
#      (Cloud Run, Render, Railway, Fly.io, etc. l'injectent automatiquement)
#   2. Port déclaré dans .choreo/component.yaml (Choreo n'injecte PAS PORT :
#      l'application doit écouter sur le port de l'endpoint déclaré)
#   3. Valeur par défaut : 3000
# ---------------------------------------------------------------------------
if [ -z "$PORT" ]; then
  YAML_FILE=""
  for f in ./.choreo/component.yaml /app/.choreo/component.yaml; do
    [ -f "$f" ] && YAML_FILE="$f" && break
  done
  DETECTED_PORT=""
  if [ -n "$YAML_FILE" ]; then
    DETECTED_PORT=$(sed -n 's/^[[:space:]]*port:[[:space:]]*\([0-9]\{2,5\}\).*/\1/p' "$YAML_FILE" | head -n1 || true)
  fi
  export PORT="${DETECTED_PORT:-3000}"
  if [ -n "$DETECTED_PORT" ]; then
    echo "[entrypoint] Aucune variable PORT définie -> port détecté dans $YAML_FILE : $PORT"
  else
    echo "[entrypoint] Aucune variable PORT définie -> port par défaut : $PORT"
  fi
else
  echo "[entrypoint] Variable d'environnement PORT détectée : $PORT"
fi

echo "[entrypoint] L'application va écouter sur le port $PORT"

# --- Augmentation de la limite de descripteurs de fichiers ----------------
# Avec potentiellement des milliers d'utilisateurs connectés en même temps
# (chacun ouvrant un socket WebSocket), la limite par défaut (souvent 1024)
# est vite atteinte et de nouvelles connexions échouent silencieusement.
# On relève cette limite au démarrage du conteneur, dans la mesure permise
# par l'hôte Docker (ulimit -n peut échouer sans droits suffisants -- on
# ignore alors l'erreur plutôt que de bloquer le démarrage).
ulimit -n 65536 2>/dev/null || echo "[entrypoint] Impossible d'augmenter ulimit -n (droits insuffisants), valeur actuelle : $(ulimit -n)"

# --- Dropbear (SSH) host keys ------------------------------------------
# The SSH system account itself (creation, username/password changes) is
# now owned entirely by server.ts (ensureSshSystemAccount / startDropbear)
# instead of duplicated here -- that's what let the earlier "invalid shell"
# bug happen silently in two places at once, and it also lets the bot's
# "change SSH username/password" command apply changes immediately without
# needing a redeploy. This block only generates the host keys, since that
# has to happen before dropbear's very first start either way.
if command -v dropbearkey >/dev/null 2>&1; then
  DROPBEAR_KEY_DIR="${DATA_DIR:-/app/data}/dropbear"
  mkdir -p "$DROPBEAR_KEY_DIR" 2>/dev/null || true
  [ -f "$DROPBEAR_KEY_DIR/dropbear_rsa_host_key" ] || dropbearkey -t rsa -f "$DROPBEAR_KEY_DIR/dropbear_rsa_host_key" >/dev/null 2>&1
  [ -f "$DROPBEAR_KEY_DIR/dropbear_ecdsa_host_key" ] || dropbearkey -t ecdsa -f "$DROPBEAR_KEY_DIR/dropbear_ecdsa_host_key" >/dev/null 2>&1
  export DROPBEAR_KEY_DIR
fi

exec "$@"
