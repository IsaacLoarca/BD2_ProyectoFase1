#!/usr/bin/env bash
# Carga un tramo de cargas/<tipo>/<NN_etiqueta>/ en la base (vía \copy dentro del contenedor).
# Uso: scripts/02-carga/cargar_tramo.sh <anio|deporte|deportista> <NN>     ej: ... anio 02
source "$(dirname "$0")/../lib.sh"
tipo="${1:?tipo: anio|deporte|deportista}"; n="${2:?numero de tramo, ej. 02}"
LOG_NAME="$tipo"
carpeta="$(cd cargas/"$tipo" && ls -d "$n"_* | head -1)"
[ -n "$carpeta" ] || { echo "No existe cargas/$tipo/${n}_*  (corre generar_cargas.py)"; exit 1; }

log "CARGA $tipo/$carpeta: inicio"
t0=$(ahora)
for t in "${TABLAS_CARGA[@]}"; do
  psql_db -c "\copy $t FROM '/cargas/$tipo/$carpeta/$t.csv' CSV HEADER" | sed "s/^/  $t: /" | tee -a "logs/$tipo.log"
done
# Las llaves se cargaron explícitas: alinear las secuencias SERIAL con el máximo cargado
psql_db -q <<'SQL'
SELECT setval(pg_get_serial_sequence(t, c), COALESCE(m, 1), m IS NOT NULL)
FROM (VALUES ('pais','pais_id',(SELECT max(pais_id) FROM pais)),
             ('ciudad','ciudad_id',(SELECT max(ciudad_id) FROM ciudad)),
             ('edicion','edicion_id',(SELECT max(edicion_id) FROM edicion)),
             ('deporte','deporte_id',(SELECT max(deporte_id) FROM deporte)),
             ('disciplina','disciplina_id',(SELECT max(disciplina_id) FROM disciplina)),
             ('evento','evento_id',(SELECT max(evento_id) FROM evento)),
             ('evento_edicion','evento_edicion_id',(SELECT max(evento_edicion_id) FROM evento_edicion)),
             ('atleta','atleta_id',(SELECT max(atleta_id) FROM atleta)),
             ('participacion','participacion_id',(SELECT max(participacion_id) FROM participacion))
     ) AS s(t, c, m);
SQL
t1=$(ahora)
seg=$(transcurrido "$t0" "$t1")
log "CARGA $tipo/$carpeta: fin en ${seg}s"
registrar_tiempo "$tipo" carga "$carpeta" "$seg"
