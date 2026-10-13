#!/usr/bin/env bash
# Funciones compartidas por los scripts de Fase 2 (se carga con: source "$(dirname "$0")/../lib.sh").
# Siempre trabaja desde la raíz de Proyecto Fase 2, sin importar desde dónde se invoque.

RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$RAIZ"
set -euo pipefail

set -a; source .env; set +a
VOLUMEN_DATOS="proyectofase2_olimpiadas_f2_pgdata"
TABLAS_VALIDACION=(pais noc ciudad edicion sede deporte disciplina evento evento_edicion
                   medalla fuente atleta participacion participacion_atleta atleta_fuente)
# Orden de carga respetando llaves foráneas
TABLAS_CARGA=(pais noc ciudad edicion sede deporte disciplina evento evento_edicion
              atleta participacion participacion_atleta atleta_fuente)

mkdir -p logs
TIEMPOS_CSV="logs/tiempos.csv"
[ -f "$TIEMPOS_CSV" ] || echo "fecha_hora,tipo_carga,operacion,detalle,segundos,tamano_kb" > "$TIEMPOS_CSV"

# psql dentro del contenedor (el SQL entra por stdin o -c)
psql_db() { docker compose exec -T db psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 "$@"; }

# Mensaje con fecha/hora, a pantalla y al log del tipo de carga
log() { echo "[$(date '+%F %T')] $*" | tee -a "logs/${LOG_NAME:-general}.log"; }

ahora() { date +%s.%N; }
# diferencia en segundos con 3 decimales: transcurrido <t0> <t1>
transcurrido() { awk -v a="$1" -v b="$2" 'BEGIN { printf "%.3f", b - a }'; }

# registrar_tiempo <tipo> <operacion> <detalle> <segundos> [kb]
registrar_tiempo() {
  echo "$(date '+%F %T'),$1,$2,$3,$4,${5:-}" >> "$TIEMPOS_CSV"
}

esperar_db() {
  until docker compose exec -T db pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB" -q 2>/dev/null; do sleep 0.5; done
}

# tamaño en KB de una ruta dentro del contenedor
tamano_kb() { docker compose exec -T db du -sk "$1" | cut -f1; }
