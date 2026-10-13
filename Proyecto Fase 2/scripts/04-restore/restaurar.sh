#!/usr/bin/env bash
# Restaura desde respaldos físicos, partiendo de una instancia sin datos (la elimina primero).
#   K=0  -> solo el full                      (copia el full al volumen de datos)
#   K>=1 -> full + inc1..incK combinados con pg_combinebackup
# Mide: (a) reconstrucción de archivos, (b) recuperación hasta aceptar conexiones, (c) total.
# Uso: scripts/04-restore/restaurar.sh <tipo> <K>      ej.: ... anio 2
source "$(dirname "$0")/../lib.sh"
tipo="${1:?tipo: anio|deporte|deportista}"; k="${2:?K: 0 (solo full) .. 3}"; LOG_NAME="$tipo"
destino="/var/lib/postgresql/data"

"$RAIZ/scripts/04-restore/eliminar_db.sh"
if [ "$k" -eq 0 ]; then
  orden="full"; paso="cp -a /backups/$tipo/full/. $destino/"
else
  cadena="/backups/$tipo/full"; orden="full"
  for i in $(seq 1 "$k"); do cadena="$cadena /backups/$tipo/inc$i"; orden="$orden+inc$i"; done
  paso="pg_combinebackup $cadena -o $destino"
fi

log "RESTORE $tipo [$orden]: inicio"
t0=$(ahora)
# Contenedor de un solo uso con los mismos volúmenes; crea el volumen de datos y lo rellena
docker compose run --rm --no-deps -T --entrypoint sh db -c \
  "$paso && chown -R postgres:postgres $destino && chmod 700 $destino" 2>&1 | tee -a "logs/$tipo.log"
t1=$(ahora)
docker compose up -d --wait   # arranca Postgres: recupera con backup_label + WAL hasta el punto consistente
t2=$(ahora)

archivos=$(transcurrido "$t0" "$t1"); recup=$(transcurrido "$t1" "$t2"); total=$(transcurrido "$t0" "$t2")
log "RESTORE $tipo [$orden]: archivos ${archivos}s + recuperación ${recup}s = total ${total}s"
registrar_tiempo "$tipo" restore_archivos "$orden" "$archivos"
registrar_tiempo "$tipo" restore_recuperacion "$orden" "$recup"
registrar_tiempo "$tipo" restore_total "$orden" "$total"
