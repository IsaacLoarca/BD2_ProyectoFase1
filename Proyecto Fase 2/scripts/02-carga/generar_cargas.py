#!/usr/bin/env python3
"""
Fase 2 — genera los "tramos" de carga a partir de los 13 CSV de staging/ (Fase 1).

Un tramo es un lote de CSV con SOLO las filas nuevas que hay que cargar en ese paso, de modo
que cada carga cumple la integridad referencial (incluye los padres que aún no existen) y cada
respaldo incremental captura exactamente lo que cambió.

Tres tipos de carga (enunciado, sección 4.1). En cada tipo el tramo 01 es la carga inicial
(esquema vacío + catálogos geográficos pais/noc/ciudad) y los tramos 02..04 son las cargas
posteriores, cada una seguida de un respaldo incremental.

  anio       Juegos completos:   Paris 2024 | Tokio 2020 | Rio 2016 | Londres 2012
  deporte    100 m planos F:     Paris 2024 | Tokio 2020 | Rio 2016 | Londres 2012
  deportista Usain Bolt:         Atenas 2004 | Pekin 2008 | Londres 2012 | Rio 2016

Uso:  python3 scripts/02-carga/generar_cargas.py        # escribe cargas/<tipo>/<NN_etiqueta>/*.csv
"""
import csv
import shutil
import sys
from collections import defaultdict
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
STAGING = BASE / "staging"
OUT = BASE / "cargas"

# Orden de carga respetando llaves foráneas (también lo usa cargar_tramo.sh)
TABLAS = ["pais", "noc", "ciudad", "edicion", "sede", "deporte", "disciplina", "evento",
          "evento_edicion", "atleta", "participacion", "participacion_atleta", "atleta_fuente"]

TEMPORADA = "Verano"
BOLT = "usain bolt"           # atleta.nombre_normalizado
# F1 nombra el evento "100 metres" y F3 (Paris 2024) "100m": ambos son el mismo evento.
DEPORTE_100M, NOMBRES_100M, SEXO_100M = "Athletics", ("100 metres", "100m"), "F"

TRAMOS = {
    "anio": [("paris_2024", 2024), ("tokio_2020", 2020), ("rio_2016", 2016), ("londres_2012", 2012)],
    "deporte": [("paris_2024", 2024), ("tokio_2020", 2020), ("rio_2016", 2016), ("londres_2012", 2012)],
    "deportista": [("atenas_2004", 2004), ("pekin_2008", 2008), ("londres_2012", 2012), ("rio_2016", 2016)],
}


def leer(tabla):
    with open(STAGING / f"{tabla}.csv", newline="", encoding="utf-8") as f:
        r = csv.reader(f)
        cab = next(r)
        return cab, list(r)


def main():
    datos = {t: leer(t) for t in TABLAS}
    cab = {t: datos[t][0] for t in TABLAS}
    fil = {t: datos[t][1] for t in TABLAS}
    col = lambda t, c: cab[t].index(c)

    # --- índices de búsqueda ---
    edicion_id = {(int(r[col("edicion", "anio")]), r[col("edicion", "temporada")]): r[0] for r in fil["edicion"]}
    ee_por_id = {r[0]: r for r in fil["evento_edicion"]}
    ev_por_id = {r[0]: r for r in fil["evento"]}
    disc_por_id = {r[0]: r for r in fil["disciplina"]}
    dep_por_id = {r[0]: r for r in fil["deporte"]}
    atleta_por_id = {r[0]: r for r in fil["atleta"]}
    sede_por_ed = defaultdict(list)
    for r in fil["sede"]:
        sede_por_ed[r[0]].append(r)
    pa_por_part = defaultdict(list)
    for r in fil["participacion_atleta"]:
        pa_por_part[r[0]].append(r)
    af_por_atleta = defaultdict(list)
    for r in fil["atleta_fuente"]:
        af_por_atleta[r[0]].append(r)
    part_por_id = {r[0]: r for r in fil["participacion"]}
    ee_de_part = {r[0]: r[col("participacion", "evento_edicion_id")] for r in fil["participacion"]}
    part_por_ee = defaultdict(list)
    for pid, ee in ee_de_part.items():
        part_por_ee[ee].append(pid)

    # evento 100 m planos femenino
    dep, sexo = DEPORTE_100M, SEXO_100M
    dep_id = next(r[0] for r in fil["deporte"] if r[1] == dep)
    disc_ids = {r[0] for r in fil["disciplina"] if r[1] == dep_id and r[2] == dep}
    evento_100f = {r[0] for r in fil["evento"]
                   if r[1] in disc_ids and r[2] in NOMBRES_100M and r[col("evento", "categoria_sexo")] == sexo}
    bolt_ids = {r[0] for r in fil["atleta"] if r[col("atleta", "nombre_normalizado")] == BOLT}
    if not evento_100f or len(bolt_ids) != 1:
        sys.exit(f"No se encontró el evento 100 m F ({evento_100f}) o Bolt ({bolt_ids})")
    bolt = next(iter(bolt_ids))

    if OUT.exists():
        shutil.rmtree(OUT)

    for tipo, tramos in TRAMOS.items():
        cargado = {t: set() for t in TABLAS}          # claves ya enviadas en tramos previos
        for n, (etiqueta, anio) in enumerate(tramos, start=1):
            ed = edicion_id[(anio, TEMPORADA)]
            ee_ed = {r[0] for r in fil["evento_edicion"] if r[col("evento_edicion", "edicion_id")] == ed}

            # 1) participaciones del tramo (según el tipo de carga)
            if tipo == "anio":
                parts = {p for ee in ee_ed for p in part_por_ee[ee]}
            elif tipo == "deporte":
                ee_sel = {ee for ee in ee_ed if ee_por_id[ee][col("evento_edicion", "evento_id")] in evento_100f}
                parts = {p for ee in ee_sel for p in part_por_ee[ee]}
            else:  # deportista: solo las participaciones en las que figura Bolt
                parts = {p for ee in ee_ed for p in part_por_ee[ee]
                         if any(a[1] == bolt for a in pa_por_part[p])}

            # 2) filas de participacion_atleta (en deportista, solo la del atleta)
            pa_rows = [a for p in parts for a in pa_por_part[p] if tipo != "deportista" or a[1] == bolt]
            atletas = {a[1] for a in pa_rows}
            ees = {ee_de_part[p] for p in parts}
            eventos = {ee_por_id[ee][col("evento_edicion", "evento_id")] for ee in ees}
            discs = {ev_por_id[e][col("evento", "disciplina_id")] for e in eventos}
            deps = {disc_por_id[d][col("disciplina", "deporte_id")] for d in discs}

            sel = {
                "edicion": [r for r in fil["edicion"] if r[0] == ed],
                "sede": sede_por_ed[ed],
                "deporte": [dep_por_id[d] for d in sorted(deps, key=int)],
                "disciplina": [disc_por_id[d] for d in sorted(discs, key=int)],
                "evento": [ev_por_id[e] for e in sorted(eventos, key=int)],
                "evento_edicion": [ee_por_id[e] for e in sorted(ees, key=int)],
                "atleta": [atleta_por_id[a] for a in sorted(atletas, key=int)],
                "participacion": [part_por_id[p] for p in sorted(parts, key=int)],
                "participacion_atleta": pa_rows,
                "atleta_fuente": [r for a in sorted(atletas, key=int) for r in af_por_atleta[a]],
            }
            if n == 1:   # carga inicial: catálogos geográficos completos
                sel["pais"], sel["noc"], sel["ciudad"] = fil["pais"], fil["noc"], fil["ciudad"]
            else:
                sel["pais"] = sel["noc"] = sel["ciudad"] = []

            carpeta = OUT / tipo / f"{n:02d}_{etiqueta}"
            carpeta.mkdir(parents=True)
            resumen = []
            for t in TABLAS:
                # clave = columnas de la llave primaria (primera col, salvo tablas compuestas)
                clave = (lambda r: (r[0], r[1])) if t in ("sede", "participacion_atleta") else \
                        (lambda r: (r[0], r[1], r[2])) if t == "atleta_fuente" else (lambda r: r[0])
                nuevas = [r for r in sel[t] if clave(r) not in cargado[t]]
                cargado[t].update(clave(r) for r in nuevas)
                with open(carpeta / f"{t}.csv", "w", newline="", encoding="utf-8") as f:
                    w = csv.writer(f)
                    w.writerow(cab[t])
                    w.writerows(nuevas)
                resumen.append(f"{t}={len(nuevas)}")
            print(f"{tipo}/{n:02d}_{etiqueta}: " + " ".join(resumen))


if __name__ == "__main__":
    main()
