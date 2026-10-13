#!/usr/bin/env bash
# Crea una instancia NUEVA y vacía (esquema + catálogos estáticos de db/init). No toca los respaldos.
# Uso: scripts/reset_instancia.sh
source "$(dirname "$0")/lib.sh"
LOG_NAME=instancia
log "Reiniciando instancia: baja el contenedor y elimina el volumen de datos"
docker compose down
docker volume rm -f "$VOLUMEN_DATOS" >/dev/null
docker compose up -d --wait
log "Instancia nueva lista (puerto $POSTGRES_PORT, base $POSTGRES_DB)"
