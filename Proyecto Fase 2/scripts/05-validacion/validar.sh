#!/usr/bin/env bash
# Validación del enunciado: SELECT COUNT(*) y SELECT * de CADA tabla (con fecha/hora para la captura).
# Uso: scripts/05-validacion/validar.sh <etiqueta> [filas_por_tabla]
#   ej.: validar.sh anio_tras_carga_02      (FILAS por defecto = 5; use 0 para solo conteos)
source "$(dirname "$0")/../lib.sh"
etiqueta="${1:?etiqueta, ej. anio_tras_carga_02}"; filas="${2:-5}"
salida="logs/validacion_${etiqueta}.log"
{
  echo "=== VALIDACION $etiqueta — $(date '+%F %T %Z') ==="
  for t in "${TABLAS_VALIDACION[@]}"; do
    psql_db -c "SELECT '$t' AS tabla, COUNT(*) AS filas FROM $t;"
    [ "$filas" -gt 0 ] && psql_db -c "SELECT * FROM $t LIMIT $filas;"
  done
  echo "=== fin $(date '+%F %T %Z') ==="
} | tee "$salida"
