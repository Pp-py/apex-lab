#!/usr/bin/env bash
#
# base-profile.sh — Resuelve las convenciones específicas de cada imagen base.
#
# Las imágenes de Oracle Database no comparten convenciones: cambian el nombre
# de la variable de contraseña, el healthcheck y el directorio de scripts de
# inicialización. Aislar esas diferencias acá hace que migrar de una base a otra
# sea cambiar DB_IMAGE_PROFILE en versions.env, no reescribir build.sh.
#
# Se sourcea desde build.sh. No ejecutar directamente.
#
# shellcheck shell=bash

case "${DB_IMAGE_PROFILE:-gvenzl}" in

  # -------------------------------------------------------------------------
  # gvenzl/oracle-free — perfil por defecto.
  # -------------------------------------------------------------------------
  gvenzl)
    DB_PASSWORD_ENV="ORACLE_PASSWORD"
    DB_HEALTHCHECK_CMD="healthcheck.sh"
    # OJO: startdb.d, NO initdb.d. El entrypoint corre initdb.d solo cuando la
    # base NO existe, y decide eso con [ -d oradata/dbconfig/$ORACLE_SID ]. Como
    # nuestra imagen sale de un -faststart + docker commit, ese directorio viaja
    # DENTRO de la imagen y se copia al volumen en el primer up: el entrypoint
    # loguea "database already initialized" y saltea initdb.d SIEMPRE, incluso
    # con un volumen recien creado. startdb.d corre en cada arranque, fuera de
    # ese condicional, y por eso los scripts de init/ tienen que ser
    # idempotentes. Verificado el 03/09/2026.
    DB_SEED_DIR="/container-entrypoint-startdb.d"
    DB_PDB="FREEPDB1"
    # La base ya viene creada en las variantes -faststart.
    DB_READY_TIMEOUT=900
    ;;

  # -------------------------------------------------------------------------
  # container-registry.oracle.com/database/free — plan B.
  #
  # Al cambiar a este perfil, ajustar también en versions.env:
  #   DB_BASE_IMAGE="container-registry.oracle.com/database/free:<tag>"
  # Usar el tag `full` (no `lite`): lite recorta componentes de la base.
  #
  # Pendiente de validar al migrar: si la imagen crea la base en el primer
  # arranque en vez de traerla hecha, el build tarda unos minutos más. El
  # timeout ampliado lo contempla.
  # -------------------------------------------------------------------------
  oracle)
    DB_PASSWORD_ENV="ORACLE_PWD"
    DB_HEALTHCHECK_CMD="/opt/oracle/checkDBStatus.sh"
    # Mismo criterio que en gvenzl: 'startup' corre en cada arranque y 'setup'
    # solo cuando la imagen crea la base. Sin validar (este perfil es el plan B).
    DB_SEED_DIR="/opt/oracle/scripts/startup"
    DB_PDB="FREEPDB1"
    DB_READY_TIMEOUT=1800
    ;;

  *)
    printf 'ERROR: DB_IMAGE_PROFILE="%s" no reconocido. Valores: gvenzl | oracle\n' \
      "${DB_IMAGE_PROFILE:-}" >&2
    exit 1
    ;;
esac

export DB_PASSWORD_ENV DB_HEALTHCHECK_CMD DB_SEED_DIR DB_PDB DB_READY_TIMEOUT
