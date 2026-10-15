#!/usr/bin/env bash
# Guía interactiva para tomar las capturas del enunciado de un tipo de carga.
# Ejecuta cada paso, muestra un encabezado con fecha/hora y ESPERA a que usted tome la captura
# (presione Enter para continuar). La salida de cada paso también queda en capturas/<tipo>/NN_*.txt
# como respaldo de texto.
# Uso: scripts/guia_capturas.sh <anio|deporte|deportista>
#      SIN_PAUSA=1 scripts/guia_capturas.sh deporte    # sin esperar (para probar que todo corre)
source "$(dirname "$0")/lib.sh"
tipo="${1:?tipo: anio|deporte|deportista}"
S="$RAIZ/scripts"
carpeta="capturas/$tipo"; mkdir -p "$carpeta"
[ -d "cargas/$tipo" ] || python3 -I "$S/02-carga/generar_cargas.py" >/dev/null
docker compose up -d --wait >/dev/null; docker compose exec -T -u root db rm -rf "/backups/$tipo"

n=0
# paso "<titulo corto>" <comando...>  : encabezado + ejecución + pausa para la captura
paso() {
  local titulo="$1"; shift; n=$((n + 1))
  local archivo; archivo="$carpeta/$(printf '%02d' "$n")_${titulo// /_}.txt"
  clear 2>/dev/null || true
  echo "################ PASO $n — $titulo ################"
  echo "Fecha/hora del sistema: $(date '+%F %T %Z')"
  echo "\$ $*"; echo
  { "$@" 2>&1 || echo "(el comando terminó con error: esperado en el paso de 'base eliminada')"; } | tee "$archivo"
  echo; echo ">>> Tome la captura ahora (fecha y hora visibles). Salida guardada en $archivo"
  [ -n "${SIN_PAUSA:-}" ] || read -r -p ">>> Enter para continuar... " _
}
consulta() { docker compose exec -T db psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "$1"; }

# --- Entorno (se repite por tipo; basta con una captura buena por integrante) ---
paso "entorno docker y volumenes" bash -c 'docker compose ps; echo; docker volume ls | grep f2'
paso "configuracion summarize_wal" docker compose exec -T db psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "SHOW summarize_wal;" -c "SELECT version();"
paso "especificaciones del servidor" bash -c 'lscpu | grep -E "Model name|^CPU\(s\)|Thread"; free -h; docker version --format "Docker {{.Server.Version}}"'

# --- Carga inicial y full ---
paso "instancia nueva" "$S/reset_instancia.sh"
paso "carga 01" "$S/02-carga/cargar_tramo.sh" "$tipo" 01
paso "conteos carga 01" "$S/05-validacion/validar.sh" "cap_${tipo}_carga01_conteos" 0
paso "select carga 01" "$S/05-validacion/validar.sh" "cap_${tipo}_carga01" 5
paso "backup full" "$S/03-backup/backup_full.sh" "$tipo"
paso "archivos del full" docker compose exec -T db ls -la "/backups/$tipo/full"
paso "fragmentacion tras full" "$S/05-validacion/fragmentacion.sh" "cap_${tipo}_carga01_full"

# --- Cargas 02..04 con su incremental ---
for i in 1 2 3; do
  c="0$((i + 1))"
  paso "carga $c" "$S/02-carga/cargar_tramo.sh" "$tipo" "$c"
  paso "conteos carga $c" "$S/05-validacion/validar.sh" "cap_${tipo}_carga${c}_conteos" 0
  paso "select carga $c" "$S/05-validacion/validar.sh" "cap_${tipo}_carga${c}" 5
  paso "backup incremental $i" "$S/03-backup/backup_incremental.sh" "$tipo" "$i"
  paso "backup_label inc$i" docker compose exec -T db head -12 "/backups/$tipo/inc$i/backup_label"
  paso "fragmentacion tras inc$i" "$S/05-validacion/fragmentacion.sh" "cap_${tipo}_carga${c}_inc$i"
done
paso "respaldos existentes" docker compose exec -T db ls -la "/backups/$tipo"
paso "verificar integridad del full" docker compose exec -T -u postgres db pg_verifybackup "/backups/$tipo/full"

# --- Desastre y restauración ---
paso "eliminar base" "$S/04-restore/eliminar_db.sh"
paso "base inexistente" docker compose exec -T db psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "SELECT 1;"
for k in 0 1 2 3; do
  paso "restaurar k=$k" "$S/04-restore/restaurar.sh" "$tipo" "$k"
  paso "conteos tras restaurar k=$k" "$S/05-validacion/validar.sh" "cap_${tipo}_restore_inc${k}_conteos" 0
  paso "select tras restaurar k=$k" "$S/05-validacion/validar.sh" "cap_${tipo}_restore_inc${k}" 5
done
paso "tabla de tiempos" bash -c "column -s, -t logs/tiempos.csv | { head -1; grep ' $tipo '; }"
echo; echo "Guía terminada: $n pasos. Texto de cada paso en $carpeta/"
