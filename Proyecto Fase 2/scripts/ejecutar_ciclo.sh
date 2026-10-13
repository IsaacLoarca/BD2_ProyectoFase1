#!/usr/bin/env bash
# Ciclo completo de un tipo de carga, de punta a punta (útil para repetir/medir; para las capturas
# del enunciado se pueden correr los pasos sueltos con los scripts de cada carpeta):
#   instancia nueva -> carga 01 -> FULL -> (carga 02..04 -> INCREMENTAL 1..3, validando cada una)
#   -> eliminar base -> restaurar full -> restaurar full+inc1, +inc2, +inc3 (validando cada una)
# Uso: scripts/ejecutar_ciclo.sh <anio|deporte|deportista>
source "$(dirname "$0")/lib.sh"
tipo="${1:?tipo: anio|deporte|deportista}"; LOG_NAME="$tipo"
S="$RAIZ/scripts"
[ -d "cargas/$tipo" ] || python3 -I "$S/02-carga/generar_cargas.py" >/dev/null

log "######## CICLO $tipo ########"
docker compose up -d --wait; docker compose exec -T -u root db rm -rf "/backups/$tipo"
"$S/reset_instancia.sh"

# --- Fase 2: carga y respaldo ---
"$S/02-carga/cargar_tramo.sh" "$tipo" 01
"$S/05-validacion/validar.sh" "${tipo}_carga01"
"$S/03-backup/backup_full.sh" "$tipo"
"$S/05-validacion/fragmentacion.sh" "${tipo}_carga01_full"
for n in 1 2 3; do
  "$S/02-carga/cargar_tramo.sh" "$tipo" "0$((n + 1))"
  "$S/05-validacion/validar.sh" "${tipo}_carga0$((n + 1))"
  "$S/03-backup/backup_incremental.sh" "$tipo" "$n"
  "$S/05-validacion/fragmentacion.sh" "${tipo}_carga0$((n + 1))_inc$n"
done

# --- Fase 3: restauración (cada una parte de una base eliminada) ---
for k in 0 1 2 3; do
  "$S/04-restore/restaurar.sh" "$tipo" "$k"
  "$S/05-validacion/validar.sh" "${tipo}_restore_inc${k}"
done
log "######## CICLO $tipo COMPLETO ########"
