# Manual de usuario — Respaldo y restauración físicos de la BD Olimpiadas

**Proyecto 2 · Sistemas de Bases de Datos 2 · USAC · 2do. semestre 2026**

Guía práctica para realizar respaldos **completos** e **incrementales**, restaurarlos, interpretar los
registros y validar la integridad. Todo se hace por **consola** (sin herramientas gráficas) sobre
PostgreSQL 17 en Docker. Todos los comandos se ejecutan desde la carpeta `Proyecto Fase 2/`.

---

## 1. Requisitos

| Requisito | Verificación |
|---|---|
| Docker y Docker Compose v2 | `docker --version` · `docker compose version` |
| Python 3 (para generar los lotes de carga) | `python3 --version` |
| Linux/macOS con `bash`, `awk`, `date` | — |
| ~1 GB libre en disco | `df -h .` |

Opcional: `matplotlib` (`pip install matplotlib`) solo para generar gráficos.

---

## 2. Instalación

```bash
git clone https://github.com/jRodas497/BD2_ProyectoFase1.git
cd BD2_ProyectoFase1/"Proyecto Fase 2"

cp .env.example .env                           # credenciales; ajustar la contraseña
python3 scripts/02-carga/generar_cargas.py     # crea cargas/<tipo>/<NN>/*.csv desde staging/
docker compose up -d --wait                    # Postgres 17 listo en el puerto 5435
```

Verificar que quedó bien:

```bash
docker compose ps                              # estado "healthy"
docker volume ls | grep f2                     # dos volúmenes persistentes
docker compose exec db psql -U olimpiadas_app -d olimpiadas -c "SHOW summarize_wal;"   # on
```

- `olimpiadas_f2_pgdata`: datos de la base.
- `olimpiadas_f2_backups`: respaldos. **Es independiente**: eliminar la base no los borra.

> `summarize_wal = on` es lo que permite los respaldos incrementales. Ya viene configurado en
> `docker-compose.yml`; sin esto `pg_basebackup --incremental` falla.

---

## 3. Conceptos

| Término | Significado en este proyecto |
|---|---|
| **Respaldo físico** | Copia de los archivos del clúster (`pg_basebackup`), no un `pg_dump` |
| **Full** | Copia completa. Se hace tras la carga inicial. Autosuficiente |
| **Incremental** | Solo lo que cambió desde el respaldo anterior. Se encadenan: inc1 usa el full, inc2 usa inc1, inc3 usa inc2 |
| **Restaurar** | Reconstruir el directorio de datos (`pg_combinebackup`) y arrancar Postgres |
| **Tipo de carga** | `anio`, `deporte` o `deportista` (ver tabla) |
| **Tramo** | Lote de CSV de una carga: 01 = carga inicial; 02, 03, 04 = cargas siguientes |

| Tipo | Tramos 01 → 04 |
|---|---|
| `anio` | París 2024 → Tokio 2020 → Río 2016 → Londres 2012 (Juegos completos) |
| `deporte` | 100 m planos femenino: París 2024 → Tokio 2020 → Río 2016 → Londres 2012 |
| `deportista` | Usain Bolt: Atenas 2004 → Pekín 2008 → Londres 2012 → Río 2016 |

**Regla de oro:** el orden es siempre *carga → validar → respaldar*. Un incremental N solo es válido si
existe el respaldo anterior (full si N=1, inc N-1 si no). **No se puede saltar un eslabón.**

---

## 4. Procedimiento paso a paso (ejemplo con `deporte`)

Reemplace `deporte` por `anio` o `deportista` según corresponda.

### Paso 1 — Crear una instancia nueva y vacía
```bash
scripts/reset_instancia.sh
```
Elimina el volumen de datos y crea una base nueva con el esquema vacío y los catálogos estáticos.
Los respaldos existentes **no** se tocan.
```
[2026-10-14 19:08:12] Reiniciando instancia: baja el contenedor y elimina el volumen de datos
[2026-10-14 19:08:20] Instancia nueva lista (puerto 5435, base olimpiadas)
```

### Paso 2 — Carga inicial (tramo 01)
```bash
scripts/02-carga/cargar_tramo.sh deporte 01
```
Carga los CSV con `\copy` respetando las llaves foráneas. Cada línea `COPY n` es el número de filas
insertadas en esa tabla; el último mensaje da el tiempo total.
```
  pais: COPY 205        noc: COPY 236       ciudad: COPY 42
  atleta: COPY 91       participacion: COPY 91   atleta_fuente: COPY 145
[...] CARGA deporte/01_paris_2024: fin en 1.554s
```

### Paso 3 — Validar la carga
```bash
scripts/05-validacion/validar.sh deporte_carga01 0     # solo COUNT(*) de las 15 tablas
scripts/05-validacion/validar.sh deporte_carga01       # COUNT(*) y SELECT * (5 filas) por tabla
```
El segundo argumento es la cantidad de filas del `SELECT *` (por defecto 5; `0` = solo conteos).
Cada validación imprime fecha y hora al inicio y al fin y se guarda en
`logs/validacion_<etiqueta>.log`.

Ver el número de participaciones a mano:
```bash
docker compose exec db psql -U olimpiadas_app -d olimpiadas -c "SELECT count(*) FROM participacion;"
```

### Paso 4 — Respaldo completo (full)
```bash
scripts/03-backup/backup_full.sh deporte
```
Ejecuta `pg_basebackup -Fp -X stream -c fast` hacia `/backups/deporte/full`.
```
[...] BACKUP FULL deporte -> /backups/deporte/full
pg_basebackup: initiating base backup, waiting for checkpoint to complete
pg_basebackup: write-ahead log start point: 0/3000028 on timeline 1
pg_basebackup: base backup completed
[...] BACKUP FULL deporte: 2.209s, 47820 KB
```

### Paso 5 — Medir la fragmentación
```bash
scripts/05-validacion/fragmentacion.sh deporte_carga01_full
```
Muestra, por tabla, tuplas vivas/muertas y espacio libre, y por índice la densidad y fragmentación de
hojas (ver §6).

### Paso 6 — Cargas siguientes, cada una con su incremental
Repetir para N = 1, 2, 3 (cargas 02, 03, 04):
```bash
scripts/02-carga/cargar_tramo.sh deporte 02
scripts/05-validacion/validar.sh deporte_carga02
scripts/03-backup/backup_incremental.sh deporte 1       # inc1 (base: full)
scripts/05-validacion/fragmentacion.sh deporte_carga02_inc1

scripts/02-carga/cargar_tramo.sh deporte 03
scripts/05-validacion/validar.sh deporte_carga03
scripts/03-backup/backup_incremental.sh deporte 2       # inc2 (base: inc1)
scripts/05-validacion/fragmentacion.sh deporte_carga03_inc2

scripts/02-carga/cargar_tramo.sh deporte 04
scripts/05-validacion/validar.sh deporte_carga04
scripts/03-backup/backup_incremental.sh deporte 3       # inc3 (base: inc2)
scripts/05-validacion/fragmentacion.sh deporte_carga04_inc3
```
Salida de un incremental:
```
[...] BACKUP INCREMENTAL deporte #1 -> /backups/deporte/inc1 (base: /backups/deporte/full)
[...] BACKUP INCREMENTAL deporte #1: 2.100s, 24728 KB
```
Comprobar los respaldos existentes:
```bash
docker compose exec db ls -la /backups/deporte          # full  inc1  inc2  inc3
```

### Paso 7 — Eliminar la base completa
```bash
scripts/04-restore/eliminar_db.sh
```
Destruye el contenedor y el **volumen de datos**. Los respaldos permanecen. Para comprobar que la base
ya no existe:
```bash
docker compose exec db psql -U olimpiadas_app -d olimpiadas -c "SELECT 1;"
# service "db" is not running   <- resultado esperado
```

### Paso 8 — Restaurar y medir
```bash
scripts/04-restore/restaurar.sh deporte 0      # solo el full
scripts/04-restore/restaurar.sh deporte 1      # full + inc1
scripts/04-restore/restaurar.sh deporte 2      # full + inc1 + inc2
scripts/04-restore/restaurar.sh deporte 3      # full + inc1 + inc2 + inc3
```
`K` indica hasta qué incremental se aplica. **Cada restauración parte de una base eliminada**
(el script la elimina primero), por lo que cada tiempo es independiente.
```
[...] RESTORE deporte [full+inc1+inc2+inc3]: inicio
[...] RESTORE deporte [full+inc1+inc2+inc3]: archivos 2.486s + recuperación 5.825s = total 8.312s
```

### Paso 9 — Validar después de restaurar
```bash
scripts/05-validacion/validar.sh deporte_restore_inc3
```
**Criterio de éxito:** los conteos deben ser **idénticos** a los de la carga correspondiente.

| Restauración | Conteo esperado de `participacion` (deporte) |
|---|---|
| K=0 (solo full) | 91 (= carga 01) |
| K=1 | 157 (= carga 02) |
| K=2 | 232 (= carga 03) |
| K=3 | 310 (= carga 04) |

Para `anio` los valores son 9 579 / 18 597 / 27 986 / 36 901 y para `deportista` 1 / 4 / 7 / 10.

### Atajos
```bash
scripts/ejecutar_ciclo.sh deporte        # todo el flujo de punta a punta (~1.5 min)
scripts/guia_capturas.sh deporte         # igual, pero pausa en cada paso para tomar capturas
```

---

## 5. Guía para tomar las capturas

El enunciado exige capturas con **fecha y hora del sistema operativo** visibles.

```bash
scripts/guia_capturas.sh deporte
```
La guía ejecuta 45 pasos en orden: entorno, instancia nueva, cada carga con sus conteos y `SELECT *`,
cada respaldo, la fragmentación, la eliminación de la base y las cuatro restauraciones con su
validación. En cada paso muestra la hora del sistema, ejecuta el comando y **espera Enter**: tome la
captura con el reloj de su pantalla visible y continúe. El texto de cada paso queda también en
`capturas/<tipo>/NN_*.txt` como respaldo.

Para probar que todo corre sin detenerse: `SIN_PAUSA=1 scripts/guia_capturas.sh deporte`.

> El `SELECT *` de las 15 tablas no cabe en una pantalla: haga varias capturas desplazando la terminal.

---

## 6. Interpretación de los registros

### 6.1 `logs/tiempos.csv`
```
fecha_hora,tipo_carga,operacion,detalle,segundos,tamano_kb
2026-10-12 19:35:57,deporte,carga,01_paris_2024,1.554,
2026-10-12 19:36:03,deporte,backup,full,2.209,47820
2026-10-12 19:36:31,deporte,restore_archivos,full+inc1,2.480,
2026-10-12 19:36:31,deporte,restore_recuperacion,full+inc1,5.845,
2026-10-12 19:36:31,deporte,restore_total,full+inc1,8.324,
```
| Operación | Qué mide |
|---|---|
| `carga` | Tiempo del `\copy` de un tramo |
| `backup` | Duración y tamaño (KB) de un respaldo |
| `restore_archivos` | Reconstruir el directorio de datos (`cp` o `pg_combinebackup`) |
| `restore_recuperacion` | Arranque de Postgres: recuperación con `backup_label` + WAL hasta aceptar conexiones |
| `restore_total` | Suma de las dos anteriores |

Verlo ordenado: `column -s, -t logs/tiempos.csv`

### 6.2 Salida de `pg_basebackup`
| Línea | Significado |
|---|---|
| `waiting for checkpoint to complete` | Fuerza un checkpoint (`-c fast`) antes de copiar |
| `write-ahead log start point: 0/3000028` | LSN desde donde se necesita WAL para que el respaldo sea consistente |
| `created temporary replication slot` | Slot temporal que retiene el WAL mientras dura la copia |
| `write-ahead log end point` | LSN final: el respaldo es consistente hasta aquí |
| `base backup completed` | Terminó sin errores |

### 6.3 `backup_label` de un incremental
```bash
docker compose exec db head -12 /backups/deporte/inc1/backup_label
```
```
START WAL LOCATION: 0/6000028 (file 000000010000000000000006)
LABEL: inc1_deporte
INCREMENTAL FROM LSN: 0/3000028       <- prueba de que es incremental y contra qué LSN se calculó
INCREMENTAL FROM TLI: 1
```
Los archivos que cambiaron aparecen como `INCREMENTAL.<archivo>`:
```bash
docker compose exec db ls /backups/deporte/inc1/base/1 | grep INCREMENTAL
```

### 6.4 Fragmentación (`fragmentacion.sh`)
| Columna | Lectura |
|---|---|
| `dead_pct` (tabla) | % de tuplas muertas. Alto = hace falta `VACUUM`. Tras cargas sin `UPDATE`/`DELETE` es `0` |
| `free_pct` (tabla) | % de espacio libre en las páginas |
| `densidad_hoja_pct` (índice) | Qué tan llenas están las hojas del B-tree (más alto = más compacto) |
| `fragmentacion_hoja_pct` (índice) | % de hojas fuera de orden físico; sube con las inserciones masivas |

---

## 7. Validación de integridad

1. **Conteos:** los de `validar.sh` tras restaurar deben igualar los de la carga original (§4, paso 9).
2. **Respaldo íntegro (full):**
   ```bash
   docker compose exec -u postgres db pg_verifybackup /backups/deporte/full
   # backup successfully verified
   ```
3. **Integridad referencial** (debe devolver 0 filas):
   ```bash
   docker compose exec db psql -U olimpiadas_app -d olimpiadas -c \
   "SELECT p.participacion_id FROM participacion p
    LEFT JOIN evento_edicion ee USING (evento_edicion_id) WHERE ee.evento_edicion_id IS NULL;"
   ```
4. **Base escribible tras restaurar** (debe devolver `f`):
   ```bash
   docker compose exec db psql -U olimpiadas_app -d olimpiadas -c "SELECT pg_is_in_recovery();"
   ```

---

## 8. Solución de problemas

| Síntoma | Causa probable | Solución |
|---|---|---|
| `incremental backups cannot be taken unless WAL summarization is enabled` | `summarize_wal` apagado | Verificar `command:` en `docker-compose.yml` y recrear: `docker compose up -d --force-recreate` |
| `service "db" is not running` | Base eliminada o contenedor detenido | Es lo esperado tras `eliminar_db.sh`; restaurar con `restaurar.sh` |
| `No existe cargas/<tipo>/...` | No se generaron los lotes | `python3 scripts/02-carga/generar_cargas.py` |
| `port is already allocated` (5435) | Otro proceso usa el puerto | Cambiar `POSTGRES_PORT` en `.env` |
| Falla un incremental porque falta el respaldo previo | Se saltó un eslabón o se borró `/backups/<tipo>` | Rehacer desde la instancia nueva (paso 1) |
| `cp`/`pg_combinebackup` falla por `No such file` en `/backups/<tipo>/...` | Aún no se hizo ese respaldo | Hacer el full/incrementales antes de restaurar |
| Se perdieron los respaldos | Se ejecutó `docker compose down -v` (borra **ambos** volúmenes) | Nunca usar `-v`; para vaciar solo los datos usar `scripts/reset_instancia.sh` |

---

## 9. Limpieza

```bash
docker compose down                      # detiene; conserva datos y respaldos
docker compose down -v                   # CUIDADO: borra también los respaldos
```
