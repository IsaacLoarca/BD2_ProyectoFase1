# Manual de usuario — Respaldo y restauración físicos de la BD Olimpiadas
### Integrantes

- Juan José Rodas Mansilla
- Integrante 2
- Integrante 3

**Proyecto 2 · Sistemas de Bases de Datos 2 · USAC · 2do. semestre 2026**

Guía práctica para realizar respaldos **completos** e **incrementales**, restaurarlos, interpretar los
registros y validar la integridad. Todo se hace por **consola** (sin herramientas gráficas) sobre
PostgreSQL 17 en Docker. Todos los comandos se ejecutan desde la carpeta `Proyecto Fase 2/`.

**Contenido:** 1 Requisitos · 2 Instalación · 3 Conceptos · 4 Procedimiento paso a paso · 5 Capturas ·
6 Interpretación de registros · 7 Validación de integridad · 8 Solución de problemas · 9 Limpieza ·
**10 Cómo funciona cada pieza (respaldo, incrementales, restauración, eliminación, integridad)** ·
**11 Los 45 pasos de la guía, uno por uno** · **12 DBeaver: conexión, consultas y Invalidate/Reconnect** ·
**13 Por qué automatizar con scripts `.sh`** · **14 Resultados de la corrida real (tipo `deporte`)** ·
**15 Notas y aclaraciones**

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


---

## 10. Cómo funciona cada pieza

### 10.1 Respaldo físico completo (full)
`pg_basebackup` copia los **archivos del clúster** de Postgres (datos, catálogos, configuración) mientras
la base sigue en línea, más el WAL que se generó durante la copia (`-X stream`). No genera SQL: por eso no es un
*dump* (`pg_dump`). El resultado es un directorio autosuficiente que, copiado de vuelta, es una base lista
para arrancar. Al terminar escribe un `backup_manifest` con la lista y el checksum de cada archivo.

*Ventaja:* restaurar es copiar archivos y arrancar. *Costo:* siempre copia todo (≈48 MB en nuestra base de prueba).

### 10.2 Incrementales: `inc1`, `inc2`, `inc3`
Un incremental guarda **solo los bloques que cambiaron** desde el respaldo anterior. Postgres 17 lo sabe porque,
con `summarize_wal = on`, un proceso va resumiendo qué bloques toca el WAL. El incremental se pide indicando el
`backup_manifest` del respaldo previo (`--incremental=<manifest>`).

| Respaldo | Se calcula contra | Contiene |
|---|---|---|
| `full` | — | Todo, tras la carga 01 |
| `inc1` | `full` | Cambios de la carga 02 |
| `inc2` | `inc1` | Cambios de la carga 03 |
| `inc3` | `inc2` | Cambios de la carga 04 |

Es una **cadena**: para llegar a la carga 04 hacen falta los cuatro (`full + inc1 + inc2 + inc3`). Si falta un
eslabón no se puede restaurar. Un incremental *diferencial* se calcularía siempre contra el full; aquí no es así.

**Prueba de que es incremental:** el `backup_label` de `inc1` trae `INCREMENTAL FROM LSN: 0/2000028`
(el punto del full de donde parte), y en `base/<oid>/` aparecen archivos `INCREMENTAL.<n>` en vez de copias completas.

> *Nota honesta:* en nuestra base (≈ 40 MB) cada incremental pesa ≈ 25 MB y el full ≈ 48 MB. Los incrementales
> no son 10 veces más chicos porque cada respaldo incluye un segmento de WAL de 16 MB y los catálogos del sistema
> cambian siempre. En bases grandes la diferencia a favor del incremental sería mucho mayor.

### 10.3 Eliminar la base de datos (el "drop")
En este proyecto eliminar la base es **destruir el volumen de datos de Docker**
(`docker compose rm -sf db` + `docker volume rm ...pgdata`), no un `DROP DATABASE` lógico. Es más realista:
simula perder el disco del servidor, y no hay forma de que quede algo reutilizable. El **volumen de respaldos
es distinto y sobrevive**: si estuvieran juntos, el desastre borraría también las copias. Tras eliminar, cualquier
conexión falla (`service "db" is not running`), y eso se captura como prueba de que la base ya no existe.

### 10.4 Restauración
1. Se parte siempre de una base eliminada (el script la elimina primero), para que cada tiempo sea independiente.
2. Un contenedor de un solo uso monta los dos volúmenes y reconstruye el directorio de datos:
   - solo full → `cp -a` del full;
   - full + incrementales → `pg_combinebackup full inc1 ... -o <datos>`, que fusiona la cadena en una sola base.
3. Se arranca Postgres. Lee el `backup_label` y **recupera**: repite el WAL incluido hasta un punto consistente
   y abre la base para escritura (`pg_is_in_recovery() = f`).

Los tiempos se separan en `restore_archivos` (paso 2) y `restore_recuperacion` (paso 3). Esto explica los
resultados: la recuperación dura casi lo mismo siempre (~5.8 s); lo que crece con los incrementales es
reconstruir archivos.

### 10.5 Pruebas de integridad
| Prueba | Qué demuestra |
|---|---|
| `COUNT(*)` de las 15 tablas tras cada carga y tras cada restauración | Los datos restaurados son **idénticos** a los de la carga que se respaldó (sin pérdida) |
| `SELECT *` de las tablas | Las filas existen y son legibles, no solo se cuentan |
| `pg_verifybackup` sobre el full | Todos los archivos del respaldo coinciden con el checksum del `backup_manifest` |
| Consulta de huérfanos (participaciones sin `evento_edicion`) devuelve 0 filas | Se conserva la integridad referencial |
| `pg_is_in_recovery()` = `f` | La base restaurada terminó la recuperación y es escribible |

La regla de oro: restaurar hasta `incK` debe dar **exactamente** los conteos de la carga `K+1`.

---

## 11. Los 45 pasos de la guía, uno por uno

`scripts/guia_capturas.sh <tipo>` ejecuta los pasos en este orden. Cada paso imprime la fecha y hora del sistema, el
comando que corre, su salida, y espera a que el usuario tome la captura y presione Enter.

### Entorno (pasos 1–3)
| # | Qué hace | Intención |
|---|---|---|
| 1 | `docker compose ps` y `docker volume ls` | Mostrar el contenedor sano y los **dos volúmenes persistentes** (requisito de Docker del enunciado) |
| 2 | `SHOW summarize_wal; SELECT version();` | Probar que Postgres 17 tiene habilitados los incrementales |
| 3 | `lscpu`, `free -h`, versión de Docker | Especificaciones técnicas del servidor para la documentación |

### Carga inicial y respaldo completo (pasos 4–10)
| # | Qué hace | Intención |
|---|---|---|
| 4 | `reset_instancia.sh` | Instancia nueva y vacía ("instancia de base de datos nueva") |
| 5 | `cargar_tramo.sh deporte 01` | Carga inicial (París 2024) con `\copy`; muestra filas por tabla y tiempo |
| 6 | Conteos (`validar.sh ... 0`) | Estado inicial medible |
| 7 | `SELECT *` (`validar.sh ... 5`) | Ver las filas cargadas |
| 8 | `backup_full.sh` | Primer respaldo: full físico |
| 9 | `ls -la /backups/deporte/full` | Probar que el respaldo es de archivos, con `backup_manifest` |
| 10 | `fragmentacion.sh` | Nivel de fragmentación tras el full |

### Cargas siguientes con su incremental (pasos 11–28, tres bloques de 6)
Cada bloque (`i = 1, 2, 3`, cargas 02, 03 y 04) hace lo mismo:
| Paso del bloque | Qué hace | Intención |
|---|---|---|
| carga | `cargar_tramo.sh deporte 0N` | Cambiar la base para que haya algo nuevo que respaldar |
| conteos | `validar.sh ... 0` | Ver cuánto creció cada tabla |
| select | `validar.sh ... 5` | Ver las filas nuevas |
| backup incremental | `backup_incremental.sh deporte i` | Respaldar **solo lo cambiado** desde el respaldo anterior |
| `backup_label` | `head /backups/deporte/inci/backup_label` | Evidencia: `INCREMENTAL FROM LSN` |
| fragmentación | `fragmentacion.sh` | Cómo cambia la fragmentación al crecer la base |

Pasos: 11–16 (carga 02 + `inc1`), 17–22 (carga 03 + `inc2`), 23–28 (carga 04 + `inc3`).

### Verificación y desastre (pasos 29–32)
| # | Qué hace | Intención |
|---|---|---|
| 29 | `ls -la /backups/deporte` | Mostrar `full inc1 inc2 inc3` |
| 30 | `pg_verifybackup` del full | Verificar la integridad del respaldo |
| 31 | `eliminar_db.sh` | **El desastre**: destruye el volumen de datos |
| 32 | `SELECT 1` falla | Prueba de que la base ya no existe |

### Restauración y validación (pasos 33–44, cuatro bloques de 3)
Cada bloque (`K = 0, 1, 2, 3`) hace:
| Paso del bloque | Qué hace | Intención |
|---|---|---|
| restaurar | `restaurar.sh deporte K` | Elimina, reconstruye con `full + inc1..incK` y arranca; **mide el tiempo** |
| conteos | `validar.sh ... 0` | Deben igualar los de la carga K+1 |
| select | `validar.sh ... 5` | Los datos son legibles y completos |

Pasos: 33–35 (K=0), 36–38 (K=1), 39–41 (K=2), 42–44 (K=3).

### Cierre (paso 45)
`column -s, -t logs/tiempos.csv`: la tabla de tiempos de todo el ciclo, base del análisis comparativo.

---

## 12. DBeaver: conexión, consultas y Invalidate/Reconnect

DBeaver es **opcional y solo visual**: se usa únicamente para mostrar los `SELECT` en una interfaz. Los respaldos y
las restauraciones se hacen siempre por consola, como exige el enunciado.

### 12.1 Conexión
**Database → New Database Connection → PostgreSQL**: host `localhost`, puerto `5435`, base `olimpiadas`,
usuario `olimpiadas_app`, contraseña la de `.env`. Pantalla dividida: terminal a la izquierda y DBeaver a la derecha;
se ejecuta la guía en la terminal y, en los pasos de conteos y `SELECT *`, se hace la consulta en DBeaver antes de
presionar Enter.

### 12.2 Consultas y su intención
**Conteo de las 15 tablas** (pasos de conteos: 6, 12, 18, 24, 34, 37, 40, 43):
```sql
SELECT 'pais' t, count(*) FROM pais UNION ALL SELECT 'noc', count(*) FROM noc
UNION ALL SELECT 'ciudad', count(*) FROM ciudad UNION ALL SELECT 'edicion', count(*) FROM edicion
UNION ALL SELECT 'sede', count(*) FROM sede UNION ALL SELECT 'deporte', count(*) FROM deporte
UNION ALL SELECT 'disciplina', count(*) FROM disciplina UNION ALL SELECT 'evento', count(*) FROM evento
UNION ALL SELECT 'evento_edicion', count(*) FROM evento_edicion UNION ALL SELECT 'medalla', count(*) FROM medalla
UNION ALL SELECT 'fuente', count(*) FROM fuente UNION ALL SELECT 'atleta', count(*) FROM atleta
UNION ALL SELECT 'participacion', count(*) FROM participacion
UNION ALL SELECT 'participacion_atleta', count(*) FROM participacion_atleta
UNION ALL SELECT 'atleta_fuente', count(*) FROM atleta_fuente;
```
*Intención:* es el `SELECT COUNT(*)` por tabla que pide el enunciado, en un solo resultado. Compara un estado con otro:
si tras restaurar coincide con la carga original, no hubo pérdida de datos.

**`SELECT *` de las tablas que cambian** (pasos 7, 13, 19, 25 y los de restauración):
```sql
SELECT * FROM edicion ORDER BY anio;                          -- las ediciones cargadas
SELECT * FROM participacion ORDER BY participacion_id DESC;   -- lo más reciente primero
SELECT * FROM atleta ORDER BY atleta_id DESC;
```
*Intención:* el enunciado pide `SELECT *`. Se ordena de modo que las filas recién cargadas aparezcan arriba, y
se eligen las tablas que **sí** cambian con cada tramo.

**Por qué algunas cifras no cambian entre cargas:** cada tramo carga solo lo nuevo. `pais`, `noc` y `ciudad` se
cargan completos en la carga 01; `medalla` y `fuente` vienen del esquema; en el tipo `deporte` siempre hay un
solo deporte y una sola disciplina (Athletics). Suben `edicion`, `sede`, `evento_edicion`, `atleta`,
`participacion`, `participacion_atleta` y `atleta_fuente`.

### 12.3 ¿Qué es Invalidate/Reconnect y para qué se hace?
DBeaver no se conecta de nuevo en cada consulta: **mantiene abiertas unas pocas conexiones** con el servidor (en las
capturas, `Live connection count: 3/3`).

En los pasos 4, 31 y en **cada restauración** el contenedor de Postgres se destruye y se crea otro nuevo. Las
conexiones abiertas apuntaban al proceso viejo, que ya no existe; el servidor nuevo responde en la misma dirección y
puerto, pero DBeaver sigue usando sockets muertos y mostraría errores como *connection closed* o
*terminating connection*.

**Invalidate/Reconnect** (clic derecho sobre la conexión) cierra las conexiones viejas y abre unas nuevas contra el
servidor actual. En la captura del paso 33 se ve el aviso `Datasource was invalidated` confirmando que se hizo.

| Cuándo | Por qué |
|---|---|
| Tras el paso 4 (instancia nueva) | El contenedor se recreó |
| Tras el paso 31 (eliminar) | Deja de existir; sirve para mostrar el fallo |
| Tras cada restauración (33, 36, 39, 42) | Es un servidor nuevo con los datos restaurados |

No es parte del método de respaldo: es un detalle de la herramienta gráfica. En la terminal (`psql`) no hace falta,
porque cada comando abre su propia conexión.

---

## 13. Por qué automatizar con scripts `.sh`

Hacer el ciclo a mano exige ~45 comandos largos, con rutas y argumentos que son fáciles de equivocar. Los scripts
aportan:

- **Repetibilidad:** el mismo comando da el mismo resultado en cualquier máquina; se pudo repetir el ciclo de los
  tres tipos de carga con idénticos pasos.
- **Medición exacta:** cada script toma la hora al empezar y al terminar y escribe el tiempo en `logs/tiempos.csv`.
  Medir a mano con cronómetro sería impreciso.
- **Un script por responsabilidad:** `cargar_tramo.sh`, `backup_full.sh`, `backup_incremental.sh`, `eliminar_db.sh`,
  `restaurar.sh`, `validar.sh` y `fragmentacion.sh`. Se pueden usar sueltos, y los combinan `ejecutar_ciclo.sh`
  (todo seguido) y `guia_capturas.sh` (con pausas).
- **Seguridad frente a errores:** `restaurar.sh` siempre elimina primero; `backup_incremental.sh` calcula solo el
  respaldo previo; los scripts usan `set -e`: se detienen ante el primer error en vez de seguir con un estado a medias.
- **Evidencia automática:** cada paso queda en `logs/` y, con la guía, en `capturas/<tipo>/NN_*.txt`, con fecha y
  hora. Si una captura se pierde, el texto la respalda.
- **Reanudable:** `DESDE=N` retoma la guía en el paso N sin repetir lo hecho (se usó en la corrida real).

---

## 14. Resultados de la corrida real (tipo `deporte`, 2026-10-14)

Conteos esperados y obtenidos (idénticos entre carga y restauración):

| Etapa | edicion | evento | evento_edicion | atleta | participacion | participacion_atleta | atleta_fuente |
|---|---|---|---|---|---|---|---|
| Carga 01 / restore full | 1 | 1 | 1 | 91 | 91 | 91 | 145 |
| Carga 02 / restore full+inc1 | 2 | 2 | 2 | 150 | 157 | 159 | 288 |
| Carga 03 / restore +inc2 | 3 | 2 | 3 | 206 | 232 | 239 | 507 |
| Carga 04 / restore +inc3 | 4 | 2 | 4 | 261 | 310 | 318 | 680 |

Respaldos:

| Respaldo | Duración | Tamaño |
|---|---|---|
| full | 2.08 s | 47 996 KB |
| inc1 | 2.01 s | 24 860 KB |
| inc2 | 2.01 s | 24 964 KB |
| inc3 | 2.05 s | 24 900 KB |

Restauraciones (cada una desde una base eliminada):

| Cadena | Reconstruir archivos | Recuperación | Total |
|---|---|---|---|
| full | 0.72 s | 5.80 s | 6.52 s |
| full + inc1 | 3.26 s | 5.81 s | 9.07 s |
| full + inc1 + inc2 | 2.38 s | 5.80 s | 8.17 s |
| full + inc1 + inc2 + inc3 | 2.38 s | 5.83 s | 8.21 s |

**Lectura:** la recuperación es constante (~5.8 s); restaurar con incrementales cuesta más por reconstruir archivos
con `pg_combinebackup` (la primera medición, 3.26 s, es algo mayor por variación normal entre ejecuciones). Los
respaldos duran lo mismo, pero los incrementales ocupan ~la mitad que el full. Con tan pocos datos las diferencias
son pequeñas: no deben exagerarse en las conclusiones.

**Fragmentación:** con pocas filas, tras el full todas las tablas están compactas (`dead_pct = 0`) y los índices no
muestran fragmentación (0 %). Tras la carga 04, `atleta_fuente_pkey` llegó a 20 % de fragmentación de hojas y 47 % de
densidad: crece conforme se insertan filas. `dead_pct` sigue en 0 porque nunca hubo `UPDATE` ni `DELETE`.

---

## 15. Notas y aclaraciones

**La guía no es una sola captura.** Son 45 pasos y se detiene en cada uno; en algunos se toman varias capturas (por
ejemplo, una por cada consulta de DBeaver).

**Si la guía se atasca.** Se corta con Ctrl+C y se retoma con `DESDE=<paso> scripts/guia_capturas.sh deporte`. La
base y los respaldos ya hechos se conservan.

**La fecha y la hora en las evidencias.** Cada paso de la guía imprime `Fecha/hora del sistema:` al empezar, y los
scripts marcan inicio y fin con fecha y hora. Por eso la hora queda registrada en la propia salida de la terminal; en
las capturas de pantalla completa además se ve el reloj del sistema, y las de DBeaver muestran la hora de cada
consulta (`fetched at ...`).

**Qué tablas se consultan con `SELECT *`.** Las que cambian con cada carga (`edicion`, `participacion`, `atleta`),
ordenadas para ver primero lo recién cargado. El conteo (`COUNT(*)`) sí se hace sobre las 15 tablas.

**Reconectar DBeaver después de restaurar.** Ver §12.3.

**Restaurar con incrementales es una cadena.** Restaurar hasta `inc3` requiere `full`, `inc1`, `inc2` e `inc3` en ese
orden; no se puede saltar ninguno.

**Por qué un incremental pesa casi la mitad del full aunque cambió poco.** Incluye 16 MB de WAL por respaldo y
archivos de catálogo que cambian en cada carga (§10.2).

**Repetir la corrida con otro tipo de carga.** `scripts/guia_capturas.sh anio` o `deportista` (o
`scripts/ejecutar_ciclo.sh <tipo>` sin pausas).
