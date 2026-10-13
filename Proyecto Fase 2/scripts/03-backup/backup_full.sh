#!/usr/bin/env bash
# Respaldo FÍSICO completo con pg_basebackup (formato plano, WAL incluido por streaming).
# Destino: volumen de respaldos, /backups/<tipo>/full   Uso: scripts/03-backup/backup_full.sh <tipo>
source "$(dirname "$0")/../lib.sh"
tipo="${1:?tipo: anio|deporte|deportista}"; LOG_NAME="$tipo"
destino="/backups/$tipo/full"

docker compose exec -T -u root db sh -c "install -d -o postgres -g postgres /backups/$tipo && rm -rf $destino"
log "BACKUP FULL $tipo -> $destino"
t0=$(ahora)
docker compose exec -T -u postgres db pg_basebackup -U "$POSTGRES_USER" -D "$destino" \
  -Fp -X stream -c fast -l "full_$tipo" -v 2>&1 | tee -a "logs/$tipo.log"
t1=$(ahora); seg=$(transcurrido "$t0" "$t1"); kb=$(tamano_kb "$destino")
log "BACKUP FULL $tipo: ${seg}s, ${kb} KB"
registrar_tiempo "$tipo" backup full "$seg" "$kb"
