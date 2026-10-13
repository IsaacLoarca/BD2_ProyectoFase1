#!/usr/bin/env python3
"""
Fase 2 — gráficos comparativos a partir de logs/tiempos.csv  ->  graficos/*.png
Requiere matplotlib (pip install matplotlib). Uso: python3 scripts/06-analisis/graficar.py

Paleta categórica validada con el validador del skill dataviz (--pairs all, 3 series):
azul / naranja / aqua. Aqua queda bajo 3:1 sobre el fondo claro, por eso todas las barras
llevan el valor impreso (relieve de contraste).
"""
import csv
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

BASE = Path(__file__).resolve().parents[2]
OUT = BASE / "graficos"
OUT.mkdir(exist_ok=True)

SUPERFICIE, TINTA, TINTA_2, REJILLA = "#fcfcfb", "#0b0b0b", "#52514e", "#e3e2de"
COLOR_TIPO = {"anio": "#2a78d6", "deporte": "#eb6834", "deportista": "#1baf7a"}
NOMBRE_TIPO = {"anio": "Por año", "deporte": "Por deporte", "deportista": "Por deportista"}
TIPOS = list(COLOR_TIPO)
RESPALDOS = ["full", "inc1", "inc2", "inc3"]
CADENAS = ["full", "full+inc1", "full+inc1+inc2", "full+inc1+inc2+inc3"]
ETIQ_CADENA = ["Full", "Full\n+inc1", "Full\n+inc1+inc2", "Full\n+inc1+inc2+inc3"]

plt.rcParams.update({
    "figure.facecolor": SUPERFICIE, "axes.facecolor": SUPERFICIE, "savefig.facecolor": SUPERFICIE,
    "text.color": TINTA, "axes.labelcolor": TINTA_2, "xtick.color": TINTA_2, "ytick.color": TINTA_2,
    "axes.edgecolor": REJILLA, "axes.spines.top": False, "axes.spines.right": False,
    "axes.grid": True, "axes.grid.axis": "y", "grid.color": REJILLA, "grid.linewidth": 0.8,
    "axes.axisbelow": True, "font.size": 10, "axes.titlesize": 11, "axes.titleweight": "bold",
})

# datos[tipo][operacion][detalle] = (segundos, kb)
datos = {t: {} for t in TIPOS}
with open(BASE / "logs" / "tiempos.csv", newline="", encoding="utf-8") as f:
    for r in csv.DictReader(f):
        kb = float(r["tamano_kb"]) if r["tamano_kb"] else None
        datos[r["tipo_carga"]].setdefault(r["operacion"], {})[r["detalle"]] = (float(r["segundos"]), kb)


def guardar(fig, nombre, titulo, subtitulo):
    fig.suptitle(titulo, x=0.01, y=1.04, ha="left", fontsize=13, fontweight="bold", color=TINTA)
    fig.text(0.01, 0.945, subtitulo, ha="left", fontsize=9.5, color=TINTA_2)
    fig.savefig(OUT / nombre, dpi=160, bbox_inches="tight")
    plt.close(fig)
    print("escrito", OUT / nombre)


def barras_agrupadas(nombre, titulo, subtitulo, ylabel, extraer, fmt, categorias, etiquetas):
    fig, ax = plt.subplots(figsize=(9, 4.6))
    ancho, n = 0.26, len(TIPOS)
    for i, t in enumerate(TIPOS):
        xs = [k + (i - (n - 1) / 2) * (ancho + 0.02) for k in range(len(categorias))]
        vs = [extraer(datos[t], c) for c in categorias]
        barras = ax.bar(xs, vs, ancho, color=COLOR_TIPO[t], label=NOMBRE_TIPO[t])
        for b, v in zip(barras, vs):
            ax.text(b.get_x() + b.get_width() / 2, v, fmt(v), ha="center", va="bottom", fontsize=8, color=TINTA)
    ax.set_xticks(range(len(categorias)), etiquetas)
    ax.set_ylabel(ylabel)
    ax.set_ylim(0, ax.get_ylim()[1] * 1.08)
    ax.legend(frameon=False, loc="upper center", ncol=3, bbox_to_anchor=(0.5, 1.0))
    fig.subplots_adjust(top=0.84)
    guardar(fig, nombre, titulo, subtitulo)


# 1) Tamaño de cada respaldo
barras_agrupadas(
    "01_tamano_respaldos.png", "Tamaño de cada respaldo",
    "Full vs. incrementales encadenados · MB en disco (incluye ~16 MB de WAL por respaldo)",
    "MB", lambda d, c: d["backup"][c][1] / 1024, lambda v: f"{v:.0f}", RESPALDOS,
    ["Full", "Incremental 1", "Incremental 2", "Incremental 3"])

# 2) Duración de cada respaldo
barras_agrupadas(
    "02_duracion_respaldos.png", "Duración de cada respaldo",
    "pg_basebackup por consola · segundos",
    "segundos", lambda d, c: d["backup"][c][0], lambda v: f"{v:.1f}", RESPALDOS,
    ["Full", "Incremental 1", "Incremental 2", "Incremental 3"])

# 3) Tiempo total de restauración por longitud de cadena
barras_agrupadas(
    "03_restauracion_total.png", "Tiempo total de restauración según la cadena",
    "Cada restauración parte de una base eliminada · segundos (archivos + recuperación)",
    "segundos", lambda d, c: d["restore_total"][c][0], lambda v: f"{v:.1f}", CADENAS, ETIQ_CADENA)

# 4) Descomposición: archivos vs. recuperación, un panel por tipo (mismo eje Y)
fig, axs = plt.subplots(1, 3, figsize=(11, 4.4), sharey=True)
C_ARCH, C_REC = "#2a78d6", "#eb6834"
for ax, t in zip(axs, TIPOS):
    arch = [datos[t]["restore_archivos"][c][0] for c in CADENAS]
    rec = [datos[t]["restore_recuperacion"][c][0] for c in CADENAS]
    xs = range(len(CADENAS))
    b1 = ax.bar(xs, arch, 0.6, color=C_ARCH, label="Reconstruir archivos")
    b2 = ax.bar(xs, rec, 0.6, bottom=arch, color=C_REC, label="Recuperación de Postgres",
                edgecolor=SUPERFICIE, linewidth=1.5)
    for k, (a, r) in enumerate(zip(arch, rec)):
        ax.text(k, a / 2, f"{a:.1f}", ha="center", va="center", fontsize=8, color="white")
        ax.text(k, a + r / 2, f"{r:.1f}", ha="center", va="center", fontsize=8, color=TINTA)
        ax.text(k, a + r, f"{a + r:.1f}", ha="center", va="bottom", fontsize=8.5, color=TINTA, fontweight="bold")
    ax.set_title(NOMBRE_TIPO[t], loc="left")
    ax.set_xticks(list(xs), ["Full", "+inc1", "+inc2", "+inc3"])
axs[0].set_ylabel("segundos")
axs[0].set_ylim(0, 10.5)
h, l = axs[0].get_legend_handles_labels()
fig.legend(h, l, frameon=False, loc="upper left", ncol=2, bbox_to_anchor=(0.0, 0.915))
fig.subplots_adjust(top=0.78, wspace=0.08)
guardar(fig, "04_restauracion_descomposicion.png", "¿Dónde se va el tiempo de restaurar?",
        "El costo extra de los incrementales es reconstruir archivos (pg_combinebackup); la recuperación es constante")

# 5) Tiempo de carga por tramo
fig, ax = plt.subplots(figsize=(9, 4.6))
tramos = {t: sorted(((d, v[0]) for d, v in datos[t]["carga"].items())) for t in TIPOS}
ancho = 0.26
for i, t in enumerate(TIPOS):
    xs = [k + (i - 1) * (ancho + 0.02) for k in range(4)]
    vs = [v for _, v in tramos[t]]
    for b, v in zip(ax.bar(xs, vs, ancho, color=COLOR_TIPO[t], label=NOMBRE_TIPO[t]), vs):
        ax.text(b.get_x() + b.get_width() / 2, v, f"{v:.1f}", ha="center", va="bottom", fontsize=8)
ax.set_xticks(range(4), ["Carga 01\n(inicial)", "Carga 02", "Carga 03", "Carga 04"])
ax.set_ylabel("segundos")
ax.set_ylim(0, ax.get_ylim()[1] * 1.08)
ax.legend(frameon=False, loc="upper center", ncol=3, bbox_to_anchor=(0.5, 1.0))
fig.subplots_adjust(top=0.84)
guardar(fig, "05_tiempo_carga.png", "Tiempo de cada carga de datos",
        "\\copy de cada tramo desde CSV · segundos")
