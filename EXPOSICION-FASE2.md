# Fase 2 — Respaldo y restauración físicos: justificación y guía de uso

Documento de apoyo para exponer y defender el diseño de la Fase 2 (carpeta `Proyecto Fase 2/`).
Todos los comandos se ejecutan **desde `Proyecto Fase 2/`**. Todas las salidas mostradas son reales
(ejecución del 2026-10-12, en `Proyecto Fase 2/logs/`).

---

## 1. El problema y qué necesita resolver

El enunciado pide demostrar el ciclo completo de continuidad de una base de datos:

| Necesidad (enunciado) | Cómo la resolvemos |
|---|---|
| Respaldos **físicos**, no dumps | `pg_basebackup` copia los archivos del clúster; no se usa `pg_dump` |
| Estrategia **full + incremental/diferencial** | Full + cadena de 3 incrementales nativos |
| Todo por **consola** | Scripts `bash` + `docker compose exec`; sin herramientas gráficas |
| 3 tipos de carga (año, deporte, deportista) | 3 conjuntos de CSV por tramos, generados desde la BD de Fase 1 |
| Capturas `SELECT *` / `COUNT(*)` tras cada carga y restauración | `validar.sh` |
| Nivel de **fragmentación** | `fragmentacion.sh` con la extensión `pgstattuple` |
| **Eliminar** la base y restaurar, midiendo tiempos | `eliminar_db.sh` + `restaurar.sh` + `logs/tiempos.csv` |
| Docker con **almacenamiento persistente** | Dos volúmenes con nombre, uno para datos y otro para respaldos |
| Capturas con fecha y hora | Cada script imprime `date`; la captura debe incluir el reloj del SO |

---

## 2. Decisiones de diseño y su justificación

### 2.1 Motor: PostgreSQL 17 (no 16)
Fase 1 usaba Postgres 16, que **no tiene respaldo incremental nativo**: solo full (`pg_basebackup`) o
archivado continuo de WAL, que no es un incremental real. Postgres 17 incorpora
`pg_basebackup --incremental` y `pg_combinebackup`. Subir de versión es lo más simple y deja un
incremental **verdadero y físico**, sin depender de herramientas de terceros.

Alternativas descartadas: pgBackRest en PG16 (válido, pero más configuración dentro de Docker) y
PITR con WAL (no es incremental según el enunciado).

### 2.2 Incremental encadenado (no diferencial)
Cada incremental N se calcula contra el `backup_manifest` del anterior (full → inc1 → inc2 → inc3).
Postgres solo ofrece incremental; su costo es que restaurar inc3 exige **toda la cadena**
(`full + inc1 + inc2 + inc3`). Esa es precisamente la desventaja que el análisis comparativo debe
mostrar frente al full.

### 2.3 Formato plano y WAL por streaming
`-Fp -X stream`: el respaldo es un directorio de archivos (inspeccionable, verificable con
`pg_verifybackup`) y el WAL necesario viaja dentro del respaldo, así que cada uno es autosuficiente
para llegar a un estado consistente.

### 2.4 Dos volúmenes separados
`olimpiadas_f2_pgdata` (datos) y `olimpiadas_f2_backups` (respaldos). "Eliminar la base" destruye el
primero; los respaldos sobreviven. Si estuvieran juntos, el desastre simulado borraría también la
copia de seguridad. Cumple el requisito de almacenamiento persistente.

### 2.5 Cargas por tramos (deltas)
Cada carga es un lote de CSV con **solo las filas nuevas** y los padres que aún no existen (así no se
rompe la integridad referencial). Así cada incremental captura exactamente lo que cambió. Tramo 01 =
carga inicial (+ catálogos geográficos `pais`, `noc`, `ciudad`) seguida del full; tramos 02–04, cada
uno seguido de un incremental.

| Tipo | Tramos 01 → 04 |
|---|---|
| `anio` | París 2024 → Tokio 2020 → Río 2016 → Londres 2012 (Juegos completos) |
| `deporte` | 100 m planos femenino en las mismas cuatro ediciones |
| `deportista` | Usain Bolt: Atenas 2004 → Pekín 2008 → Londres 2012 → Río 2016 |

El enunciado da tres ejemplos por tipo y exige hasta 3 incrementales, por eso se añadió una cuarta
edición (1 inicial + 3 incrementales).

### 2.6 Medición del tiempo de restauración en tres partes
`restore_archivos` (reconstruir el directorio de datos), `restore_recuperacion` (Postgres recupera
hasta aceptar conexiones) y `restore_total`. Separarlos permite explicar **dónde** se va el tiempo.

---

## 3. Estructura

```
Proyecto Fase 2/
├── docker-compose.yml        Postgres 17, summarize_wal=on, volúmenes datos + respaldos
├── db/init/                  DDL (01..05, heredado de Fase 1) + 06-pgstattuple.sql
├── staging/                  CSV de Fase 1 (origen de las cargas)
├── cargas/                   (generado, no versionado) tramos por tipo de carga
├── scripts/
│   ├── lib.sh                funciones comunes (log, tiempos, psql)
│   ├── reset_instancia.sh    instancia nueva y vacía
│   ├── ejecutar_ciclo.sh     ciclo completo de un tipo de carga
│   ├── 02-carga/             generar_cargas.py, cargar_tramo.sh
│   ├── 03-backup/            backup_full.sh, backup_incremental.sh
│   ├── 04-restore/           eliminar_db.sh, restaurar.sh
│   ├── 05-validacion/        validar.sh, fragmentacion.sh
│   └── 06-analisis/          graficar.py (logs/tiempos.csv -> graficos/*.png)
├── graficos/                 5 gráficos comparativos (PNG)
└── logs/                     tiempos.csv, <tipo>.log, validacion_*.log, fragmentacion_*.log
```

---

## 4. Cada script: qué hace, cómo se ejecuta y qué muestra

### Preparación (una vez)
```bash
cd "Proyecto Fase 2"
cp .env.example .env                           # ajustar contraseña; puerto 5435
python3 scripts/02-carga/generar_cargas.py     # genera cargas/<tipo>/<NN_etiqueta>/*.csv
docker compose up -d --wait
```
`generar_cargas.py` imprime las filas nuevas por tabla en cada tramo:
```
anio/01_paris_2024: pais=205 noc=236 ciudad=42 edicion=1 sede=1 deporte=32 disciplina=47 evento=351 evento_edicion=351 atleta=11095 participacion=9579 participacion_atleta=14891 atleta_fuente=18190
anio/02_tokio_2020: pais=0 noc=0 ciudad=0 edicion=1 sede=1 deporte=2 disciplina=3 evento=256 evento_edicion=347 atleta=8044 participacion=9018 ...
```
Se ve el efecto "delta": en Tokio solo entran 2 deportes nuevos porque los demás ya estaban cargados.

### `scripts/reset_instancia.sh`
Baja el contenedor, **elimina el volumen de datos** y levanta una instancia nueva (corre `db/init`:
esquema, índices, catálogos `medalla`/`fuente`, `pgstattuple`). No toca los respaldos.
```bash
scripts/reset_instancia.sh
```
Cumple: "En una instancia de base de datos nueva realizar una carga inicial".

### `scripts/02-carga/cargar_tramo.sh <tipo> <NN>`
Carga un tramo con `\copy` en orden de llaves foráneas, alinea las secuencias `SERIAL` y registra el
tiempo.
```bash
scripts/02-carga/cargar_tramo.sh anio 02
```
```
[2026-10-12 19:38:55] CARGA anio/02_tokio_2020: inicio
  pais: COPY 0   noc: COPY 0   ciudad: COPY 0   edicion: COPY 1   sede: COPY 1
  deporte: COPY 2   disciplina: COPY 3   evento: COPY 256   evento_edicion: COPY 347
  atleta: COPY 8044   participacion: COPY 9018   participacion_atleta: COPY 13950   atleta_fuente: COPY 14577
[2026-10-12 19:38:58] CARGA anio/02_tokio_2020: fin en 3.046s
```

### `scripts/05-validacion/validar.sh <etiqueta> [filas]`
Para **cada una de las 15 tablas**: `SELECT COUNT(*)` y `SELECT * ... LIMIT <filas>` (por defecto 5; `0`
solo conteos). Escribe en `logs/validacion_<etiqueta>.log` con fecha y hora al inicio y al final.
```bash
scripts/05-validacion/validar.sh anio_carga02
scripts/05-validacion/validar.sh anio_carga02 0      # solo conteos
```
```
=== VALIDACION anio_carga01 — 2026-10-12 19:38:50 CST ===
 tabla | filas
-------+-------
 pais  |   205
(1 row)
 pais_id |     nombre     | codigo_iso3
---------+----------------+-------------
       1 | Afghanistan    |
...
```

### `scripts/03-backup/backup_full.sh <tipo>`
`pg_basebackup -Fp -X stream -c fast` hacia `/backups/<tipo>/full` (volumen de respaldos). Registra
duración y tamaño.
```bash
scripts/03-backup/backup_full.sh anio
```
```
[2026-10-12 19:38:53] BACKUP FULL anio -> /backups/anio/full
pg_basebackup: write-ahead log start point: 0/3000028 on timeline 1
pg_basebackup: base backup completed
[2026-10-12 19:38:55] BACKUP FULL anio: 2.311s, 59268 KB
```

### `scripts/03-backup/backup_incremental.sh <tipo> <N>`
`pg_basebackup --incremental=<manifest del respaldo anterior>` hacia `/backups/<tipo>/incN`.
```bash
scripts/03-backup/backup_incremental.sh anio 1
```
```
[2026-10-12 19:39:01] BACKUP INCREMENTAL anio #1 -> /backups/anio/inc1 (base: /backups/anio/full)
[2026-10-12 19:39:04] BACKUP INCREMENTAL anio #1: 2.192s, 38940 KB
```

### `scripts/05-validacion/fragmentacion.sh <etiqueta>`
Mide con `pgstattuple`/`pgstatindex`: tuplas muertas y espacio libre por tabla, y densidad y
fragmentación de hojas por índice B-tree. Salida en `logs/fragmentacion_<etiqueta>.log`.
```bash
scripts/05-validacion/fragmentacion.sh anio_carga04_inc3
```
```
        tabla         |  tamano | tuplas_vivas | tuplas_muertas | dead_pct | free_pct
 atleta_fuente        | 5376 kB |        73869 |              0 |     0.00 |     0.37
 participacion        | 2248 kB |        36901 |              0 |     0.00 |     0.32
                     indice          |  tamano | densidad_hoja_pct | fragmentacion_hoja_pct
 participacion_atleta_pkey           | 2392 kB |             64.55 |                  50.51
```
Lectura: tras cargas masivas sin `UPDATE`/`DELETE` no hay tuplas muertas (tablas compactas), pero los
índices sí muestran fragmentación de hojas por los splits durante la inserción.

### `scripts/04-restore/eliminar_db.sh`
Simula el desastre: elimina el contenedor y el **volumen de datos**. Los respaldos permanecen.
```bash
scripts/04-restore/eliminar_db.sh
```

### `scripts/04-restore/restaurar.sh <tipo> <K>`
Siempre parte de una base eliminada. `K=0` copia solo el full; `K≥1` combina
`full + inc1..incK` con `pg_combinebackup` en un contenedor de un solo uso que rellena el volumen de
datos; luego arranca Postgres, que recupera con `backup_label` + WAL.
```bash
scripts/04-restore/restaurar.sh anio 0     # solo full
scripts/04-restore/restaurar.sh anio 3     # full + inc1 + inc2 + inc3
```
```
[2026-10-12 19:39:55] RESTORE anio [full+inc1+inc2+inc3]: inicio
[2026-10-12 19:40:03] RESTORE anio [full+inc1+inc2+inc3]: archivos 2.585s + recuperación 5.824s = total 8.409s
```
Después de cada restauración se corre `validar.sh` para comparar con los conteos de la carga original.

### `scripts/ejecutar_ciclo.sh <tipo>`
Orquesta todo: instancia nueva → carga 01 → full → (cargas 02–04, cada una con su incremental,
validación y fragmentación) → restaurar full, +inc1, +inc2, +inc3, validando cada una. Útil para
repetir las mediciones.
```bash
scripts/ejecutar_ciclo.sh anio          # ~1.5 min
scripts/ejecutar_ciclo.sh deporte
scripts/ejecutar_ciclo.sh deportista
```

---

## 5. Consultas y comandos para verificar los cambios

**Integridad de datos (SQL)** — usar `docker compose exec db psql -U olimpiadas_app -d olimpiadas`:
```sql
-- Conteo por tabla (comparar con el de la carga original en logs/validacion_*)
SELECT 'participacion' t, count(*) FROM participacion UNION ALL
SELECT 'atleta',          count(*) FROM atleta UNION ALL
SELECT 'evento_edicion',  count(*) FROM evento_edicion;

-- Ediciones cargadas hasta el momento
SELECT anio, temporada, nombre FROM edicion ORDER BY anio;

-- Integridad referencial: debe devolver 0 filas
SELECT p.participacion_id FROM participacion p
LEFT JOIN evento_edicion ee USING (evento_edicion_id) WHERE ee.evento_edicion_id IS NULL;

-- Participaciones de Bolt por edición (depende del tipo cargado: con "anio" solo salen 2012 y 2016;
-- con "deportista" salen 2004, 2008, 2012 y 2016)
SELECT e.anio, ev.nombre, m.nombre AS medalla
FROM participacion_atleta pa
JOIN atleta a USING (atleta_id)
JOIN participacion p USING (participacion_id)
JOIN evento_edicion ee USING (evento_edicion_id)
JOIN edicion e USING (edicion_id)
JOIN evento ev USING (evento_id)
LEFT JOIN medalla m USING (medalla_id)
WHERE a.nombre_normalizado = 'usain bolt' ORDER BY e.anio;
```

**Configuración que habilita el incremental:**
```sql
SHOW summarize_wal;                         -- on
SELECT count(*) FROM pg_available_wal_summaries();   -- resúmenes WAL disponibles
SELECT pg_is_in_recovery();                 -- f: la base restaurada quedó escribible
SELECT pg_size_pretty(pg_database_size('olimpiadas'));
```

**Estado de los respaldos (consola):**
```bash
docker compose exec db ls /backups/anio                         # full inc1 inc2 inc3
docker compose exec db head -12 /backups/anio/inc1/backup_label # INCREMENTAL FROM LSN ...
docker compose exec db ls /backups/anio/inc1/base/1 | grep INCREMENTAL   # archivos incrementales
docker compose exec -u postgres db pg_verifybackup /backups/anio/full   # "backup successfully verified"
docker volume ls | grep f2                                      # los dos volúmenes persistentes
column -s, -t logs/tiempos.csv                                  # tiempos registrados
```
`backup_label` del incremental muestra la prueba de que es incremental real:
```
LABEL: inc1_anio
INCREMENTAL FROM LSN: 0/3000028
```

---

## 6. Resultados obtenidos

**Conteos de `anio`: carga original vs. restauración (idénticos en las 4 etapas)**

| Etapa | participacion | atleta | evento_edicion | Restauración correspondiente |
|---|---|---|---|---|
| Carga 01 (París 2024) | 9 579 | 11 095 | 351 | full → 9 579 ✔ |
| Carga 02 (+Tokio 2020) | 18 597 | 19 139 | 698 | full+inc1 → 18 597 ✔ |
| Carga 03 (+Río 2016) | 27 986 | 26 555 | 1 015 | full+inc1+inc2 → 27 986 ✔ |
| Carga 04 (+Londres 2012) | 36 901 | 33 100 | 1 329 | full+inc1+inc2+inc3 → 36 901 ✔ |

(`deporte`: 91 → 157 → 232 → 310 participaciones; `deportista`: 1 → 4 → 7 → 10; también idénticos.)

**Tiempos de restauración (segundos), tipo `anio`**

| Restauración | Archivos | Recuperación | Total |
|---|---|---|---|
| Solo full | 0.80 | 5.85 | 6.65 |
| full + inc1 | 2.53 | 5.83 | 8.36 |
| full + inc1 + inc2 | 2.51 | 5.82 | 8.33 |
| full + inc1 + inc2 + inc3 | 2.59 | 5.82 | 8.41 |

**Respaldo (`anio`)**

| Respaldo | Duración | Tamaño |
|---|---|---|
| Full | 2.31 s | 59 268 KB |
| Incremental 1 | 2.19 s | 38 940 KB |
| Incremental 2 | 2.22 s | 38 716 KB |
| Incremental 3 | 2.29 s | 42 940 KB |

---

## 7. Lectura honesta de los resultados (limitaciones)

- **El volumen es pequeño** (el mayor, `anio`, son ~41 MB de base). El tiempo de restauración está
  dominado por la recuperación fija de Postgres (~5.8 s), no por los datos, y los respaldos duran lo
  mismo (~2 s). Por eso las diferencias entre estrategias son modestas. No hay que exagerarlas en
  las conclusiones.
- **Cada incremental pesa 24–43 MB** pese a cargar pocos datos: incluye un segmento de WAL de 16 MB
  por streaming, más archivos de catálogo del sistema que cambian en cada carga.
- **Lo que sí se observa:** restaurar con incrementales cuesta ~1.7 s más en reconstrucción de archivos
  (`pg_combinebackup`) que el full solo, y ese costo crece con el largo de la cadena. La ventaja del
  incremental está en el **respaldo** (menos datos a copiar en bases grandes), no en la restauración.
- Si el análisis necesita más contraste, se puede repetir con el tipo `anio` ampliado (más ediciones por tramo).

---

## 8. Cobertura de la rúbrica

| Criterio | Dónde se cubre |
|---|---|
| Código fuente organizado (15) | `scripts/` separado en carga, backup, restore, validación; comentado |
| Carga masiva (15) | `generar_cargas.py` + `cargar_tramo.sh`; integridad referencial verificada |
| Ejecución de respaldos (15) | `backup_*.sh`, consola, con fecha/hora en logs |
| Restauración y validación (15) | `restaurar.sh` + `validar.sh`; tiempos en `tiempos.csv` |
| Análisis comparativo (15) | Sección 6 + gráficos por generar a partir de `tiempos.csv` |
| Documentación técnica (15) y manual de usuario (10) | Este documento es la base; falta el PDF y el manual |

---

## 9. Lo que sigue

1. Tomar las **capturas** (con fecha/hora visible del SO) de `validar.sh` tras cada carga y cada
   restauración, y de `fragmentacion.sh`.
2. ~~Generar gráficos~~ — hecho: `python3 scripts/06-analisis/graficar.py` (requiere `matplotlib`) produce
   `graficos/01..05_*.png` (tamaño y duración de respaldos, restauración total y descompuesta, tiempo de carga).
3. Redactar la **documentación técnica en PDF** (metodología, ER, plan de respaldo, especificaciones
   del servidor, análisis y conclusiones) y el **manual de usuario**.
4. Opcionales: compresión, cron, cifrado y alertas de integridad.
5. Entregar en UEDI el **17-oct-2026** (todos los integrantes).
