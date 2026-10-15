# Plan de equipo — Fase 2 (Respaldo y restauración)

**Entrega: 17-octubre-2026 en UEDI (todos los integrantes).**
Repositorio: carpeta `Proyecto Fase 2/`. Guía técnica y justificación: `EXPOSICION-FASE2.md`.

---

## 1. Gráficos ya generados

Carpeta `Proyecto Fase 2/graficos/` (se regeneran con `python3 scripts/06-analisis/graficar.py`, requiere `matplotlib`):

| Archivo | Qué muestra |
|---|---|
| `01_tamano_respaldos.png` | MB de cada respaldo (full vs. incrementales), por tipo de carga |
| `02_duracion_respaldos.png` | Segundos de cada respaldo |
| `03_restauracion_total.png` | Tiempo total de restauración según el largo de la cadena |
| `04_restauracion_descomposicion.png` | Reconstruir archivos vs. recuperación de Postgres, un panel por tipo |
| `05_tiempo_carga.png` | Segundos de cada carga de datos |

Conclusión que respaldan (sin exagerar): restaurar con incrementales cuesta ~1.7 s más, todo en
reconstrucción de archivos (`pg_combinebackup`); los respaldos duran lo mismo y los incrementales
pesan menos que el full. Los datos son pequeños, así que la recuperación fija de Postgres (~5.8 s)
domina el tiempo.

---

## 2. Capturas recomendadas

> Todas las capturas deben mostrar **fecha y hora del sistema operativo** (dejar visible el reloj de
> la pantalla). Los scripts además imprimen `date`.

### Una sola vez (por integrante, en su máquina)
- `docker compose ps` y `docker volume ls | grep f2` → dos volúmenes persistentes (datos y respaldos).
- `SHOW summarize_wal;` → `on`.
- `docker compose config` → configuración del servidor.
- `lscpu`, `free -h`, `docker version` → especificaciones técnicas.

### Por cada tipo de carga (`anio`, `deporte`, `deportista`), con los pasos sueltos

Ejecutar desde `Proyecto Fase 2/`. Reemplazar `<tipo>` por el tipo asignado.

| # | Comando | Captura |
|---|---|---|
| 1 | `scripts/reset_instancia.sh` | Instancia nueva y vacía |
| 2 | `scripts/02-carga/cargar_tramo.sh <tipo> 01` | Salida con los `COPY` y el tiempo |
| 3 | `scripts/05-validacion/validar.sh <tipo>_carga01 0` | **`COUNT(*)` de las 15 tablas** |
| 4 | `scripts/05-validacion/validar.sh <tipo>_carga01` | **`SELECT *`** (varias capturas; no cabe en una) |
| 5 | `scripts/03-backup/backup_full.sh <tipo>` | Salida del full, duración y tamaño |
| 6 | `docker compose exec db ls /backups/<tipo>` | Archivos del respaldo |
| 7 | `scripts/05-validacion/fragmentacion.sh <tipo>_carga01_full` | Fragmentación de tablas e índices |
| 8 | Cargas 02, 03, 04: `cargar_tramo.sh <tipo> 0N` → `validar.sh` → `backup_incremental.sh <tipo> N-1` → `fragmentacion.sh` | Una captura por cada paso, por cada carga |
| 9 | `docker compose exec db head -12 /backups/<tipo>/inc1/backup_label` | Línea `INCREMENTAL FROM LSN` (prueba de incremental real) |
| 10 | `scripts/04-restore/eliminar_db.sh` + intento de conexión fallido | Base eliminada |
| 11 | `scripts/04-restore/restaurar.sh <tipo> 0` | Restauración del full con tiempos |
| 12 | `scripts/05-validacion/validar.sh <tipo>_restore_inc0` | Conteos y `SELECT *` tras restaurar |
| 13 | `restaurar.sh <tipo> 1`, `2`, `3` (cada una con su `validar.sh`) | Restauración de cada incremental y su validación |
| 14 | `column -s, -t logs/tiempos.csv` | Tabla final de tiempos |

Son unas 25–30 capturas por tipo. Para el `SELECT *` basta con las tablas que cambian en cada carga
(`atleta`, `participacion`, `participacion_atleta`, `evento_edicion`, `edicion`); el `COUNT(*)` sí va sobre las 15.

**Atajo:** `scripts/ejecutar_ciclo.sh <tipo>` corre todo de punta a punta (~1.5 min) y deja los logs
en `logs/`. Sirve para repetir mediciones; las capturas se toman mejor con los pasos sueltos.

---

## 3. Pasos a tomar (orden de trabajo)

1. **Preparar el entorno** (cada integrante): clonar el repo, `cd "Proyecto Fase 2"`,
   `cp .env.example .env`, `python3 scripts/02-carga/generar_cargas.py`, `docker compose up -d --wait`.
2. **Ejecutar y capturar** el tipo asignado (sección 2).
3. **Redactar** documentación técnica, manual de usuario y análisis (reparto abajo).
4. **Revisión cruzada**: cada quien revisa el trabajo de otro (comandos del manual funcionan, datos
   del análisis coinciden con `logs/tiempos.csv`).
5. **Entrega en UEDI**: *todos* los integrantes suben los archivos (sin esto, nota 0).

---

## 4. Reparto de responsabilidades entre 3

La comparación es **full vs. incremental dentro de cada tipo**, así que cada integrante puede correr
su tipo en su propia máquina sin invalidar el análisis. Cada quien anota las especificaciones de su equipo.

| | Persona 1 | Persona 2 | Persona 3 |
|---|---|---|---|
| **Tipo de carga** | `anio` | `deporte` | `deportista` |
| **Capturas** | Las de su tipo (sección 2) | Las de su tipo | Las de su tipo |
| **Entregable principal** | **Documentación técnica (PDF):** metodología, modelo ER, plan de respaldo, especificaciones del servidor, conclusiones | **Manual de usuario:** comandos exactos, ejemplos, interpretación de logs, validación post-restauración | **Análisis comparativo:** tablas y gráficos, ventajas/desventajas, recomendación fundamentada |
| **Apoyo** | Verificar que el ER de Fase 1 está incluido | Probar que cada comando del manual funciona desde cero | Control del repositorio (orden, `.gitignore`), empaquetado y checklist de UEDI |
| **Revisa a** | Persona 3 | Persona 1 | Persona 2 |

Checklist de entrega (todos): ☐ PDF de documentación técnica ☐ Manual de usuario ☐ Código fuente /
repositorio ordenado ☐ Capturas con fecha y hora ☐ Logs de ejecución ☐ Subido a UEDI por cada integrante.

---

## 5. Qué sigue

1. **Hoy:** hacer commit/push de gráficos, scripts y documentación.
2. **Hoy–mañana:** cada persona ejecuta y captura su tipo de carga.
3. **Mañana:** Persona 1 y 2 redactan el PDF y el manual a partir de `EXPOSICION-FASE2.md`.
4. **Antes del 17-oct:** Persona 3 cierra el análisis comparativo; revisión cruzada; entrega de todos
   en UEDI.
5. **Opcional, si sobra tiempo:** cron, compresión, cifrado y alertas de integridad.
