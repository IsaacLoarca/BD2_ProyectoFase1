# Contexto completo — Proyecto Fase 1, BD2 (USAC)

Documento de contexto para retomar el proyecto después de reorganizar carpetas (separación en
`Proyecto Fase 1` y `Proyecto Fase 2`). Escrito el 2026-10-12. No es un entregable del curso: es una
nota de trabajo para no perder el hilo.

---

## 1. Qué es el proyecto

**Curso:** Sistemas de Bases de Datos 2, USAC, 2do. semestre 2026.
**Objetivo:** unificar 4 datasets olímpicos heterogéneos en una base de datos relacional
normalizada en PostgreSQL, con 15 tablas.

| Inciso | Qué pide | Dónde está |
|---|---|---|
| (a) | Modelo ER | `diagramas/modelo-er-olimpiadas.drawio`, `docs/modelo-de-datos.md` |
| (b) | Extracción y unificación de las 4 fuentes | `scripts/generar_csv_carga.py` → `staging/*.csv` |
| (c) | Crear la base y cargar los datos | `db/init/*.sql`, `docker-compose.yml`, `docs/guia-carga-db.md` |
| (d) | Stored procedure por atleta | `sp_info_atleta` en `db/init/05-procedimientos.sql` |
| (e) | Stored procedure por país | `sp_info_pais` en `db/init/05-procedimientos.sql` |

**Las 4 fuentes:**

| # | Fuente | Volumen | Cobertura | Aporte único |
|---|---|---|---|---|
| F1 | Olympedia (vía KeithGalli/Olympics-Dataset) | 145 500 atletas, 308 408 resultados (302 565 tras limpiar) | 1896–2022, Verano+Invierno | Fecha de nacimiento, medidas, y **puesto** además de medalla |
| F2 | Kaggle "120 years of Olympic history" | 271 116 filas | 1896–2016 | Ciudad sede, nombres de equipo, catálogo NOC→región |
| F3 | Kaggle "Summer Olympics Medals 1896-2024" | 252 565 filas | 1896–2024, solo Verano | Es la única con **París 2024** (se usa solo para 2024, porque F1 ya cubre hasta Tokio 2020) |
| F4 | DataCamp DataLab "r-olympics" | 100 filas | muestra | Ninguno: es subconjunto literal de F2 (D-000) |
| F5 | olympics.com | — | — | Solo referencia de verificación, no se carga |

**Hallazgos de calidad que condicionaron el diseño** (detalle completo en
`docs/HANDOFF-decisiones.md`):
1. `noc_regions.csv` (F2) usa saltos de línea CR; normalizado a LF en staging.
2. IDs de atleta incompatibles entre fuentes (`athlete_id`, `ID`, `player_id`) → unificación por
   atributos, no por ID.
3. F1 usa `Discipline` (94 valores), F2/F3 usan `Sport` (66) → jerarquía de 3 niveles.
4. El puesto viene como texto (`=17`, `DNF`, `DNS`, `AC`).
5. Los CSV crudos vienen a grano atleta × evento → una medalla de equipo se repite por integrante.

---

## 2. Modelo de datos (15 tablas, 16 relaciones, 3FN)

Diccionario completo en `docs/modelo-de-datos.md`. Resumen por grupo:

- **Geografía:** `pais`, `noc` (puede estar disuelto, `es_historico`), `ciudad`.
- **Ediciones:** `edicion`, `sede` (tabla puente edición↔ciudad).
- **Catálogo deportivo:** `deporte` → `disciplina` → `evento` → `evento_edicion`.
- **Núcleo:** `atleta`, `participacion`, `participacion_atleta`, `medalla`.
- **Trazabilidad:** `fuente`, `atleta_fuente`.

**Decisión más importante del modelo (D-004a / D-007):** `participacion` es una **entrada a un
evento**, no un atleta. Un equipo es 1 fila de `participacion` + N filas de
`participacion_atleta`. Así el medallero es `COUNT(*)` sobre participaciones, no sobre atletas.

**Otras decisiones clave** (bitácora completa D-000 a D-014 en `docs/HANDOFF-decisiones.md`):
- D-003: F1 (Olympedia) es la espina dorsal de la identidad del atleta; F2/F3/F4 se reconcilian
  contra ella por nombre normalizado + sexo + NOC + año + evento, con trazabilidad en
  `atleta_fuente`.
- D-004b: `noc` separado de `pais` (comités disueltos como URS, GDR, YUG, EUN tienen medallas).
- D-008: jerarquía deporte/disciplina/evento, para reconciliar `Sport` (F2/F3) con `Discipline`
  (F1).
- D-009: `sede` es tabla puente (no FK simple) por casos reales: Melbourne 1956 con la hípica en
  Estocolmo, Milán-Cortina 2026 con dos sedes.
- D-010: no hay tabla `resultado` aparte; `puesto`, `puesto_texto`, `empatado`, `medalla_id` viven
  en `participacion`.
- D-011: `puesto` (numérico, para ordenar) y `puesto_texto` (original, conserva DNF/DNS/AC) juntos.
- D-012: única desnormalización deliberada: `participacion.es_por_equipos` duplica
  `evento.es_por_equipos` (evita un JOIN de 3 saltos en el medallero).
- D-013: banderas `fue_cancelada` / `es_intercalada` en `edicion` (1916, 1940, 1944, Atenas 1906).
- D-014: `atleta.nombre_normalizado` materializado e indexado (clave de matching del ETL y de los
  SPs).
- **Excluido a propósito:** antropometría por edición y geolocalización/población histórica.

---

## 3. ETL (`scripts/generar_csv_carga.py`)

Script en Python/pandas, vectorizado (groupby/agg/nunique/first/ngroup, sin iterrows() en las
partes de 300k+ filas). Genera **13 CSV** en `staging/` (medalla y fuente no salen de CSV: los
siembra `db/init/04-seed.sql`).

**7 etapas:** (1) carga de fuentes crudas, (2) país/NOC, (3) ciudad/edición/sede, (4) catálogo
deportivo, (5) participación/participación_atleta, (6) atleta/atleta_fuente, (7) escritura de CSV.

**Resolución de identidad de atleta** (`resolver_atleta()`), en cascada de confianza:

| Criterio | Confianza |
|---|---|
| F1 es la espina | 1.00 |
| Nombre + NOC + año exacto | 0.90 |
| Nombre + NOC | 0.75 |
| Núcleo del nombre (1er+último token) + NOC | 0.65 |
| Nombre único en F1 | 0.55 |
| Núcleo único en F1 | 0.45 |
| Atleta nuevo | 0.50 |

Solo se acepta un match si el candidato es único en el índice correspondiente.

**Limpieza aplicada:**
- CR→LF en `noc_regions.csv`.
- 5 842 filas de Youth Olympic Games descartadas de F1.
- 2 601 filas de F1 sin edición resoluble, descartadas.
- 177 filas duplicadas en `participacion_atleta` (mismo atleta repetido en la misma entrada),
  colapsadas.
- Enteros nullable con `Int64` (evita que salgan como `12.0` en el CSV).

**Cifras finales de la última corrida** (ya cargadas y verificadas en la DB):

| Tabla | Filas |
|---|---|
| pais | 205 |
| noc | 236 |
| ciudad | 42 |
| edicion | 63 |
| sede | 54 |
| deporte | 59 |
| disciplina | 90 |
| evento | 1 761 |
| evento_edicion | 8 123 |
| atleta | 239 678 |
| participacion | 212 376 |
| participacion_atleta | 314 679 |
| atleta_fuente | 517 009 |
| medalla (seed) | 3 |
| fuente (seed) | 4 |

---

## 4. Bug real encontrado y corregido (importante para la defensa)

**Síntoma:** al probar `sp_info_pais`, el medallero de Francia 2024 salía inflado. El oro de
Rugby Sevens contaba 13 veces (una por integrante del equipo).

**Causa:** en `scripts/generar_csv_carga.py`, la detección de "evento por equipos" para F3-2024
(único tramo de F3 que aporta participaciones nuevas) dependía solo de keywords en el texto del
evento (`Team`, `Relay`, `Doubles`, etc. — ver `TEAM_KEYWORDS`). No cubría disciplinas 100% de
equipo cuyo evento es simplemente "Men"/"Women" (Basketball, 3x3 Basketball, Beach Volleyball,
Football, Handball, Hockey, Rugby Sevens, Volleyball, Water Polo), ni formas singulares no
cubiertas por las keywords (Rowing "Eight", Canoe/Kayak "Double", Cycling Track "Madison", Diving
"Synchronised", Sailing "Skiff"/"Dinghy"/"Multihull").

**Corrección aplicada:** se sumó el mismo criterio data-driven que ya usaba F1 (ver
`generar_csv_carga.py`, cerca de la línea 495): si dentro de un `evento_edicion` hay un grupo
`(NOC, medalla)` con más de un atleta, es evidencia directa de equipo. Se verificó que en este
dataset no hay colisiones falsas (ningún evento individual tiene dos medallistas del mismo país
con el mismo color de medalla, salvo "Judo Mixed Team", que sí es equipo).

**Resultado:** `participacion` pasó de 215 318 a 212 376 filas; 29 eventos cambiaron su flag
`es_por_equipos`. El medallero de Francia 2024 da **16 oros, 26 platas, 22 bronces — igual al
oficial**. Guatemala: 1 oro (Adriana Ruano, Trap), 1 plata (Érick Barrondo, 20km marcha), 1 bronce
(Pierre Brol, Trap) — verificado contra el CSV crudo de F3.

**Commit:** `53cf540` — "feat: agregar SPs sp_info_atleta/sp_info_pais y corregir colapso de
equipos en F3-2024". También corrigió que `staging/` no estaba montado en el contenedor (la Opción
B de `\copy` con `docker compose exec` no funcionaba tal como estaba documentada); ahora se monta
en `/staging` (ver `docker-compose.yml`).

---

## 5. Carga de la base

Guía paso a paso completa: `docs/guia-carga-db.md`. Resumen:

1. `cp .env.example .env` si no existe.
2. `docker compose down -v` (si había una corrida previa) y `docker compose up -d`. Postgres
   ejecuta automáticamente `db/init/01-extensions.sql` → `02-schema.sql` → `03-indices.sql` →
   `04-seed.sql` → `05-procedimientos.sql`, en ese orden, al crear el volumen.
3. Verificar con `\dt` (15 tablas) y conteos (`medalla`=3, `fuente`=4, `pais`=0 antes de cargar).
4. Cargar los 13 CSV en orden de llaves foráneas: pais → noc → ciudad → edicion → sede → deporte
   → disciplina → evento → evento_edicion → atleta → participacion → participacion_atleta →
   atleta_fuente. Con dBeaver (Import Data) o con `\copy` (más rápido, sobre todo para
   `atleta_fuente`, 517k filas).
5. Resincronizar 9 secuencias `SERIAL` con `setval` (los CSV traen IDs explícitos).
6. Verificar conteos finales (tabla de la sección 3 arriba) y un sanity check de medallero por
   NOC.

**Conexión:** `localhost`, puerto de `POSTGRES_PORT` en `.env` (por defecto `5434`), base
`olimpiadas`, usuario/contraseña de `.env`.

---

## 6. Stored procedures

Archivo: `db/init/05-procedimientos.sql`. Son `PROCEDURE` de PL/pgSQL que despliegan con
`RAISE NOTICE` (no `SELECT`), se invocan con `CALL`. En psql el texto sale en consola; en dBeaver
sale en la pestaña *Output*/*Server Output*, no en la grilla.

### `sp_info_atleta(p_nombre, p_deporte, p_pais, p_anio)` — inciso (d)
Busca por nombre parcial (`ILIKE`) sobre `nombre_completo`, `nombre_usado`, `nombre_normalizado`
— puede matchear varios atletas y los despliega por separado. Muestra biografía, medallero y cada
participación (edición, deporte/disciplina, evento, NOC, equipo si aplica, puesto, medalla).
Filtros opcionales por deporte, país (nombre de NOC o código) y año.

Verificado: Michael Phelps = 23 oro/3 plata/2 bronce (4 oro/2 plata con `p_anio=2012`). Usain Bolt
con `('Bolt','Athletics','JAM')` = 8 oros.

### `sp_info_pais(p_pais, p_anio, p_temporada, p_deporte)` — inciso (e)
`p_pais` matchea por nombre de país, nombre de comité o código NOC (cubre comités históricos
disueltos). Muestra, por cada NOC que matchea: años y ciudades como sede, resumen de
participaciones y medallero (cuenta entradas, no atletas), años de participación, y resultados con
medalla.

Verificado: Francia 2024 = 16/26/22 (igual al oficial); sede en 1900, 1924 (Verano e Invierno),
1968, 1992, 2024. Guatemala = 1/1/1, sin sedes.

**Detalles que salieron al probarlos** (ya corregidos en el archivo):
- `p_anio` es `INT`, no `SMALLINT` — con `SMALLINT`, `CALL sp_info_atleta('X', NULL, NULL, 2012)`
  falla por resolución de sobrecarga de Postgres.
- `puesto_texto` llega como cadena vacía (no `NULL`) en las entradas de F3-2024 sin posición
  exacta; se muestra con `COALESCE(NULLIF(x, ''), '—')`.
- `RAISE NOTICE` usa un solo `%` como placeholder (no `%s` estilo printf); `%%` es un `%` literal.
  Cuidado si se edita a mano.

### ⚠️ `sp_medallistas_pais(p_pais, p_deporte, p_anio, p_medalla)` — PENDIENTE DE GUARDAR

Se creó en sesión para responder "atletas que han ganado medalla, por país", pero **existe solo en
la base de datos en vivo** (confirmado con `\df sp_*` el 2026-10-12) y **no está en
`db/init/05-procedimientos.sql` ni commiteado**. Si se hace `docker compose down -v`, se pierde.
`docs/guia-carga-db.md` ya tiene (sin commitear) dos ejemplos de `CALL` que lo referencian, pero el
procedure en sí hay que volver a escribirlo en el archivo. El SQL completo, tal como quedó
funcionando:

```sql
-- sp_medallistas_pais(p_pais, p_deporte, p_anio, p_medalla)
-- Lista a los atletas que han ganado medalla para un pais, ordenados por total de medallas, con el
-- detalle de cada una. p_pais matchea igual que en sp_info_pais (pais, comite o codigo NOC).
-- Filtros opcionales: deporte (nombre), anio de la edicion, medalla ('Oro', 'Plata' o 'Bronce').
-- Una medalla de equipo cuenta para cada integrante.

CREATE OR REPLACE PROCEDURE sp_medallistas_pais(
    p_pais     VARCHAR,
    p_deporte  VARCHAR DEFAULT NULL,
    p_anio     INT DEFAULT NULL,
    p_medalla  VARCHAR DEFAULT NULL
)
LANGUAGE plpgsql
AS $$
DECLARE
    r            RECORD;
    v_ultimo     INT := NULL;
    v_atletas    INT := 0;
BEGIN
    FOR r IN
        SELECT a.atleta_id, a.nombre_completo, n.nombre_comite, n.noc_codigo,
               ed.anio, ed.temporada, dep.nombre AS deporte, ev.nombre AS evento,
               p.nombre_equipo, p.es_por_equipos, m.nombre AS medalla,
               COUNT(*) OVER (PARTITION BY a.atleta_id) AS total,
               COUNT(*) FILTER (WHERE m.orden = 1) OVER (PARTITION BY a.atleta_id) AS oro,
               COUNT(*) FILTER (WHERE m.orden = 2) OVER (PARTITION BY a.atleta_id) AS plata,
               COUNT(*) FILTER (WHERE m.orden = 3) OVER (PARTITION BY a.atleta_id) AS bronce
        FROM participacion p
        JOIN medalla m               ON m.medalla_id = p.medalla_id
        JOIN noc n                   ON n.noc_codigo = p.noc_codigo
        LEFT JOIN pais pai           ON pai.pais_id = n.pais_id
        JOIN participacion_atleta pa ON pa.participacion_id = p.participacion_id
        JOIN atleta a                ON a.atleta_id = pa.atleta_id
        JOIN evento_edicion ee       ON ee.evento_edicion_id = p.evento_edicion_id
        JOIN edicion ed              ON ed.edicion_id = ee.edicion_id
        JOIN evento ev               ON ev.evento_id = ee.evento_id
        JOIN disciplina disc         ON disc.disciplina_id = ev.disciplina_id
        JOIN deporte dep             ON dep.deporte_id = disc.deporte_id
        WHERE (n.nombre_comite ILIKE '%' || p_pais || '%'
               OR n.noc_codigo = UPPER(p_pais)
               OR pai.nombre ILIKE '%' || p_pais || '%')
          AND (p_deporte IS NULL OR dep.nombre ILIKE '%' || p_deporte || '%')
          AND (p_anio    IS NULL OR ed.anio = p_anio)
          AND (p_medalla IS NULL OR m.nombre ILIKE p_medalla)
        ORDER BY COUNT(*) OVER (PARTITION BY a.atleta_id) DESC, a.nombre_completo, a.atleta_id,
                 ed.anio, m.orden
    LOOP
        IF v_ultimo IS DISTINCT FROM r.atleta_id THEN
            v_ultimo := r.atleta_id;
            v_atletas := v_atletas + 1;
            RAISE NOTICE '%  (%) — % medalla(s): Oro % / Plata % / Bronce %',
                r.nombre_completo, r.noc_codigo, r.total, r.oro, r.plata, r.bronce;
        END IF;
        RAISE NOTICE '    % % | % — % -> %',
            r.anio, r.temporada, r.deporte,
            r.evento || CASE WHEN r.es_por_equipos THEN ' [equipo: ' || COALESCE(r.nombre_equipo, '?') || ']' ELSE '' END,
            r.medalla;
    END LOOP;

    IF v_atletas = 0 THEN
        RAISE NOTICE 'No se encontraron medallistas para "%" con los filtros dados', p_pais;
    ELSE
        RAISE NOTICE '--- % medallista(s) ---', v_atletas;
    END IF;
END;
$$;
```

Verificado con `CALL sp_medallistas_pais('Guatemala')` (los 3 medallistas, 1 medalla cada uno) y
`CALL sp_medallistas_pais('USA', 'Aquatics', 2016, 'Oro')` (Phelps 5 oros, Ledecky 4 oros, etc.).

**Siguiente paso pendiente, discutido pero no aplicado:** agregar el nombre de los atletas al
`SELECT` del bucle de "resultados con medalla" dentro de `sp_info_pais`, con una subconsulta:

```sql
(SELECT string_agg(a.nombre_completo, ', ' ORDER BY a.nombre_completo)
   FROM participacion_atleta pa JOIN atleta a ON a.atleta_id = pa.atleta_id
  WHERE pa.participacion_id = p.participacion_id) AS atletas
```
y agregar `, r_medalla.atletas` a la línea `RAISE NOTICE '... -> % (%) | %'` de esa sección. Se
diseñó y se probó la subconsulta contra la base (devuelve los nombres correctos), pero **no se
aplicó al archivo**.

---

## 7. Limitaciones conocidas (mencionarlas antes de que las pregunten)

- Las participaciones de París 2024 (F3) no traen puesto, solo medalla; `puesto_texto` queda vacío
  para esas filas.
- `noc.nombre_comite` sale del catálogo NOC→región de F2, no del nombre real del comité: URS y EUN
  aparecen como "Russia". Para el bloque soviético hay que buscar por código (`URS`).
- `FRG` está marcado como `es_historico = false` aunque el comité está disuelto (dato mal
  clasificado en la carga, no corregido).
- Alemania se reparte entre GER, FRG y GDR sin medallero unificado por país.
- La detección de equipos en F3 (ver sección 4) asume que no hay dos medallistas del mismo NOC con
  el mismo color de medalla en un evento individual. Verificado que no ocurre en este dataset, pero
  no es una garantía general para datos futuros.
- Una participación de solo fase clasificatoria puede no tener medalla asociada aunque el equipo
  la ganó (ej. el relevo 4x100 de Bolt en 2008).
- Búsqueda parcial en los SPs: `sp_info_atleta('Bolt')` devuelve ~47 atletas cuyo nombre contiene
  "bolt".

---

## 8. Estado de git (al 2026-10-12)

**Repo:** `https://github.com/jRodas497/BD2_ProyectoFase1.git`, rama `main`.

```
53cf540 feat: agregar SPs sp_info_atleta/sp_info_pais y corregir colapso de equipos en F3-2024
015c592 Guía para crear la db
32e7894 feat: reemplazar los 15 CSV de carga por los generados con F1 como espina dorsal
af96ff1 Subida de csv + contenido de tablas
0775634 fix: diagrama en .drawio guardado y ordenado
a03f864 feat: modelo de datos unificado de olimpiadas (Fase 1, inciso a)
```

**Sin commitear al momento de escribir esto:**
- `docs/guia-carga-db.md` (4 líneas: dos ejemplos de `CALL sp_medallistas_pais(...)`) — referencia
  un procedure que no está guardado en ningún archivo (ver sección 6).

**Pendiente de decidir, nunca confirmado por el usuario:**
- Si borrar de disco `data/data_upload/olympics_15_csv_F1_backbone/` + `.zip` (el conjunto de CSV
  generado por otro agente/ChatGPT; ya está des-trackeado de git por `.gitignore`, pero sigue en
  disco).
- Si quitar de git `data/data_upload/review/` (contiene el script y reportes de validación de ese
  otro conjunto de CSV; sigue trackeado).

**Nota sobre atribución:** por pedido explícito del usuario, los commits de este proyecto se hacen
**sin** la línea `Co-Authored-By: Claude`.

---

## 9. Sobre la separación en Fase 1 / Fase 2

Al momento de escribir esto, `Proyecto Fase 2` (carpeta hermana, fuera de este repo) solo contiene
el enunciado (`775_Proyecto_2_2S2026.pdf`); no se ha explorado ni iniciado ningún trabajo de Fase
2 en esta conversación. Este documento (`CONTEXTO.md`) describe únicamente el estado de **Fase
1**. Antes de mover carpetas:

- Verificar que no haya trabajo sin commitear que se quiera conservar (ver sección 8).
- El contenedor Docker (`olimpiadas-postgres`) y su volumen (`proyectofase1_olimpiadas_pgdata`)
  quedan ligados al nombre del proyecto/carpeta en `docker-compose.yml`; si la carpeta se renombra
  o se mueve, Docker Compose puede crear un proyecto/volumen nuevo en vez de reusar el actual —
  conviene `docker compose down` (sin `-v`, para no perder los datos) antes de mover, y volver a
  `docker compose up -d` después, verificando que el volumen se reconecte o recargando desde los
  CSV de `staging/` si no.
- `db/init/05-procedimientos.sql` **no refleja el estado real de la base** (le falta
  `sp_medallistas_pais`, ver sección 6) — conviene resolver eso antes o inmediatamente después de
  mover la carpeta, para no perder el procedure si se recrea el contenedor.
