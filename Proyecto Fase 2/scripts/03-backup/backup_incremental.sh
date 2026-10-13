#!/usr/bin/env bash
# Respaldo FÍSICO incremental (pg_basebackup --incremental). Cada incremental N se calcula contra el
# backup_manifest del anterior (full si N=1, incN-1 si no): es una cadena incremental.
# Uso: scripts/03-backup/backup_incremental.sh <tipo> <N>     ej.: ... anio 1
source "$(dirname "$0")/../lib.sh"
tipo="${1:?tipo: anio|deporte|deportista}"; n="${2:?N del incremental: 1, 2, 3}"; LOG_NAME="$tipo"
previo="/backups/$tipo/full"; [ "$n" -gt 1 ] && previo="/backups/$tipo/inc$((n - 1))"
destino="/backups/$tipo/inc$n"

docker compose exec -T -u root db rm -rf "$destino"
log "BACKUP INCREMENTAL $tipo #$n -> $destino (base: $previo)"
t0=$(ahora)
docker compose exec -T -u postgres db pg_basebackup -U "$POSTGRES_USER" -D "$destino" \
  --incremental="$previo/backup_manifest" -Fp -X stream -c fast -l "inc${n}_$tipo" -v 2>&1 | tee -a "logs/$tipo.log"
t1=$(ahora); seg=$(transcurrido "$t0" "$t1"); kb=$(tamano_kb "$destino")
log "BACKUP INCREMENTAL $tipo #$n: ${seg}s, ${kb} KB"
registrar_tiempo "$tipo" backup "inc$n" "$seg" "$kb"
