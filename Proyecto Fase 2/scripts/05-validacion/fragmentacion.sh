#!/usr/bin/env bash
# Nivel de fragmentación de tablas e índices con pgstattuple (enunciado, Fase 2 "Carga de datos").
# Uso: scripts/05-validacion/fragmentacion.sh <etiqueta>
source "$(dirname "$0")/../lib.sh"
etiqueta="${1:?etiqueta, ej. anio_tras_carga_02}"
{
  echo "=== FRAGMENTACION $etiqueta — $(date '+%F %T %Z') ==="
  psql_db <<'SQL'
-- Tablas: dead_tuple_% y free_% altos indican espacio desperdiciado (hinchazón/fragmentación)
SELECT c.relname AS tabla,
       pg_size_pretty(s.table_len)        AS tamano,
       s.tuple_count                      AS tuplas_vivas,
       s.dead_tuple_count                 AS tuplas_muertas,
       round(s.dead_tuple_percent::numeric, 2) AS dead_pct,
       round(s.free_percent::numeric, 2)       AS free_pct
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace AND n.nspname = 'public'
CROSS JOIN LATERAL pgstattuple(c.oid) s
WHERE c.relkind = 'r'
ORDER BY s.table_len DESC;

-- Índices B-tree: leaf_fragmentation es el % de páginas hoja fuera de orden físico
SELECT c.relname AS indice,
       pg_size_pretty(pg_relation_size(c.oid)) AS tamano,
       round(i.avg_leaf_density::numeric, 2)   AS densidad_hoja_pct,
       round(i.leaf_fragmentation::numeric, 2) AS fragmentacion_hoja_pct
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace AND n.nspname = 'public'
JOIN pg_index x ON x.indexrelid = c.oid
JOIN pg_am a ON a.oid = c.relam AND a.amname = 'btree'
CROSS JOIN LATERAL pgstatindex(c.oid) i
WHERE c.relkind = 'i'
ORDER BY pg_relation_size(c.oid) DESC;
SQL
  echo "=== fin $(date '+%F %T %Z') ==="
} | tee "logs/fragmentacion_${etiqueta}.log"
