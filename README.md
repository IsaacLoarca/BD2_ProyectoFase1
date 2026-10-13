# Base de Datos Unificada de Olimpiadas

**Universidad de San Carlos de Guatemala** · Facultad de Ingeniería · Escuela de Ciencias y Sistemas
**Sistemas de Bases de Datos 2** — 2do. Semestre 2026

Repositorio único con las dos fases del proyecto. Cada fase es autosuficiente: tiene su propio
`docker-compose.yml`, `.env`, `.gitignore`, `README.md`, `db/`, `docs/`, `scripts/` y `staging/`.

| Carpeta | Contenido | Puerto Postgres | Contenedor |
|---------|-----------|-----------------|------------|
| [`Proyecto Fase 1/`](Proyecto%20Fase%201/) | Modelo ER, unificación de fuentes, carga y stored procedures. **Congelada**: no se modifica. | 5434 | `olimpiadas-postgres` |
| [`Proyecto Fase 2/`](Proyecto%20Fase%202/) | Parte de una copia de Fase 1 y es donde continúa el desarrollo. Incluye el enunciado (PDF). | 5435 | `olimpiadas-postgres-f2` |

> Desde Fase 2 en adelante **solo se modifica `Proyecto Fase 2/`**.

## Uso

Cada comando se ejecuta desde dentro de la carpeta de la fase:

```bash
cd "Proyecto Fase 2"            # o "Proyecto Fase 1"
cp .env.example .env            # una sola vez; ajustar la contraseña
docker compose up -d
```

Las fases usan nombre de proyecto (`proyectofase1` / `proyectofase2`), contenedor, volumen y puerto
distintos, así que pueden correr a la vez sin chocar.

## Datos derivados (no versionados)

`data/raw/` y `sources/` no se suben al repo. En Fase 1 existen; en Fase 2 se reconstruyen con
`./scripts/preparar-fuentes.sh` si se necesitan.

## Notas

- [`CONTEXTO.md`](CONTEXTO.md): nota de trabajo con el estado de Fase 1 (no es un entregable).
- Detalle de cada fase: README dentro de su carpeta.
