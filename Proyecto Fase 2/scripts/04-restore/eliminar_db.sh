#!/usr/bin/env bash
# "Eliminar la base de datos completa": baja el contenedor y borra el volumen de DATOS.
# El volumen de respaldos no se toca.   Uso: scripts/04-restore/eliminar_db.sh
source "$(dirname "$0")/../lib.sh"
LOG_NAME=instancia
log "ELIMINAR BASE: se destruye el volumen de datos $VOLUMEN_DATOS"
docker compose rm -sf db >/dev/null
docker volume rm -f "$VOLUMEN_DATOS" >/dev/null
log "Base eliminada (respaldos intactos)"
