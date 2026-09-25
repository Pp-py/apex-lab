#!/usr/bin/env bash
#
# test-doctor.sh — Self-test de doctor.sh contra fixtures rotas a propósito.
#
# Un chequeo que devuelve [OK] porque su grep está mal escrito es peor que no
# tenerlo: da confianza falsa. Acá cada chequeo se ejercita en su caso sano Y
# en el roto, y se verifica el código de salida.
#
# Sin dependencias: bash y coreutils. Corre en CI junto al shellcheck.
#
# Uso:  ./scripts/test-doctor.sh
# Sale: 0 si pasan todos, 1 si falla alguno.
#
set -Eeuo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO

# shellcheck source=scripts/lib/checks.sh
source "${REPO}/scripts/lib/checks.sh"
# shellcheck source=scripts/lib/checks-env.sh
source "${REPO}/scripts/lib/checks-env.sh"
# Las constantes derivadas que check_env_drift necesita.
# shellcheck source=versions.env
source "${REPO}/versions.env"
# shellcheck source=scripts/base-profile.sh
source "${REPO}/scripts/base-profile.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

N_PASS=0; N_FAIL=0
if [[ -t 1 ]]; then C_G=$'\033[0;32m'; C_R=$'\033[0;31m'; C_0=$'\033[0m'
else C_G=""; C_R=""; C_0=""; fi

# esperado <rc> <id> <descripcion> -- <funcion> [args...]
esperado() {
  local want="$1" id="$2" desc="$3"; shift 4   # el 4o es el '--'
  local got=0
  CHECK_DETAIL=""; CHECK_FIX=""
  "$@" || got=$?
  if [[ "${got}" -eq "${want}" ]]; then
    N_PASS=$((N_PASS+1))
    printf '  %sok%s    %-24s %s\n' "${C_G}" "${C_0}" "${id}" "${desc}"
  else
    N_FAIL=$((N_FAIL+1))
    printf '  %sFALLO%s %-24s %s  (esperaba rc=%s, dio rc=%s)\n' \
      "${C_R}" "${C_0}" "${id}" "${desc}" "${want}" "${got}"
    printf '        detalle: %s\n' "${CHECK_DETAIL%%$'\n'*}"
    [[ -z "${CHECK_FIX}" ]] || printf '        arreglo: %s\n' "${CHECK_FIX}"
  fi
}

env_con() { printf '%s\n' "$@" > "${TMP}/env"; printf '%s' "${TMP}/env"; }

printf '\nChequeos estaticos (0=OK 1=FAIL 2=WARN 3=SKIP)\n\n'

# --- init-exec-bit -------------------------------------------------------
mkdir -p "${TMP}/init_ok" && : > "${TMP}/init_ok/01.sh" && chmod +x "${TMP}/init_ok/01.sh"
mkdir -p "${TMP}/init_nox" && : > "${TMP}/init_nox/01.sh" && chmod -x "${TMP}/init_nox/01.sh"
esperado 0 init-exec-bit "acepta .sh con +x"           -- check_init_exec_bit "${TMP}/init_ok"
esperado 1 init-exec-bit "detecta .sh SIN +x"          -- check_init_exec_bit "${TMP}/init_nox"
esperado 3 init-exec-bit "sin init/ es SKIP, no FAIL"  -- check_init_exec_bit "${TMP}/no_existe"

# --- init-inert-example --------------------------------------------------
mkdir -p "${TMP}/init_ej" && : > "${TMP}/init_ej/01_workspace.sh.example"
mkdir -p "${TMP}/init_otro" && : > "${TMP}/init_otro/notas.txt" && : > "${TMP}/init_otro/01.sh"
mkdir -p "${TMP}/init_doc" && : > "${TMP}/init_doc/01.sh" && : > "${TMP}/init_doc/README.md"
esperado 1 init-inert-example "detecta el .sh.example colgado" -- check_init_inert "${TMP}/init_ej"
esperado 2 init-inert-example "avisa de otras extensiones"     -- check_init_inert "${TMP}/init_otro"
esperado 0 init-inert-example "el README.md no molesta"        -- check_init_inert "${TMP}/init_doc"

# --- bind-addr -----------------------------------------------------------
esperado 2 bind-addr "detecta 0.0.0.0"          -- check_bind_addr "$(env_con 'BIND_ADDR=0.0.0.0')"
esperado 0 bind-addr "acepta loopback"          -- check_bind_addr "$(env_con 'BIND_ADDR=127.0.0.1')"
esperado 0 bind-addr "ausente = default seguro" -- check_bind_addr "$(env_con 'OTRA=1')"
esperado 3 bind-addr "sin .env es SKIP"         -- check_bind_addr "${TMP}/no_existe_env"

# --- compose-shm ---------------------------------------------------------
printf 'services:\n  db:\n    image: x\n'                  > "${TMP}/c_sin.yml"
printf 'services:\n  db:\n    shm_size: 1gb\n'             > "${TMP}/c_1gb.yml"
printf 'services:\n  db:\n    shm_size: 2gb\n'             > "${TMP}/c_2gb.yml"
esperado 1 compose-shm "detecta shm_size ausente" -- check_compose_shm "${TMP}/c_sin.yml"
esperado 1 compose-shm "detecta shm_size < 2gb"   -- check_compose_shm "${TMP}/c_1gb.yml"
esperado 0 compose-shm "acepta 2gb"               -- check_compose_shm "${TMP}/c_2gb.yml"

# --- seed-dir-mount ------------------------------------------------------
esperado 1 seed-dir-mount "detecta initdb.d (nunca corre)" \
  -- check_seed_dir_mount "$(env_con 'DB_SEED_DIR=/container-entrypoint-initdb.d')"
esperado 0 seed-dir-mount "acepta startdb.d" \
  -- check_seed_dir_mount "$(env_con 'DB_SEED_DIR=/container-entrypoint-startdb.d')"

# --- app-password-charset ------------------------------------------------
esperado 1 app-password "detecta espacio"   -- check_app_passwords "$(env_con 'APP_PASSWORD=a b' 'PDBADMIN_PASSWORD=ok')"
esperado 1 app-password "detecta comilla"   -- check_app_passwords "$(env_con 'APP_PASSWORD=ok' 'PDBADMIN_PASSWORD=a"b')"
esperado 1 app-password "detecta backslash" -- check_app_passwords "$(env_con 'APP_PASSWORD=a\b' 'PDBADMIN_PASSWORD=ok')"
# El '&' rompe SQL*Plus en el build pero NO el DDL de las semillas: la regla es
# distinta a proposito, y confundirlas seria reportar un FAIL que no existe.
esperado 0 app-password "acepta & (regla de semilla, no de build)" \
  -- check_app_passwords "$(env_con 'APP_PASSWORD=a&b' 'PDBADMIN_PASSWORD=Ok_2026#')"

# --- init-seed-vars ------------------------------------------------------
esperado 1 init-seed-vars "detecta una variable faltante" \
  -- check_seed_vars "$(env_con 'APP_WORKSPACE=D' 'APP_SCHEMA=D' 'APP_WS_USER=D' 'APP_EMAIL=d@d' 'APP_PASSWORD=d')"
esperado 0 init-seed-vars "acepta las seis" \
  -- check_seed_vars "$(env_con 'APP_WORKSPACE=D' 'APP_SCHEMA=D' 'APP_WS_USER=D' 'APP_EMAIL=d@d' 'APP_PASSWORD=d' 'PDBADMIN_PASSWORD=d')"

# --- ords-static-mount (bug A) -------------------------------------------
mkdir -p "${TMP}/proy_vacio/cache/apex"
mkdir -p "${TMP}/proy_ok/cache/apex/$(dirname "${ORDS_STATIC_PROBE}")"
: > "${TMP}/proy_ok/cache/apex/${ORDS_STATIC_PROBE}"
esperado 1 ords-static-mount "detecta cache/apex vacio (bug A)" -- check_ords_static_mount "${TMP}/proy_vacio" proyecto
esperado 1 ords-static-mount "detecta cache/apex ausente"       -- check_ords_static_mount "${TMP}/no_existe" proyecto
# En el repo, ./cache lo genera build.sh: su ausencia es SKIP, no FAIL. Sin esta
# distincion, un `git clone` recien hecho daria rojo y el chequeo seria ruido.
esperado 3 ords-static-mount "sin ./cache en el repo es SKIP"   -- check_ords_static_mount "${TMP}/no_existe" repo
esperado 0 ords-static-mount "acepta los estaticos presentes"   -- check_ords_static_mount "${TMP}/proy_ok" repo

# --- sql-ascii -----------------------------------------------------------
mkdir -p "${TMP}/repo_ascii/sql" "${TMP}/repo_acento/sql"
printf -- '-- comentario sano\nSELECT 1 FROM dual;\n'      > "${TMP}/repo_ascii/sql/10.sql"
printf -- '-- comentario con accion\nSELECT 1 FROM dual;\n' > "${TMP}/repo_acento/sql/10.sql"
printf -- '-- una e\xc3\xb1e colada\n'                     >> "${TMP}/repo_acento/sql/10.sql"
esperado 0 sql-ascii "acepta SQL 100% ASCII"   -- check_sql_ascii "${TMP}/repo_ascii"
esperado 1 sql-ascii "detecta una enie en .sql" -- check_sql_ascii "${TMP}/repo_acento"
esperado 3 sql-ascii "sin sql/ es SKIP"         -- check_sql_ascii "${TMP}/no_existe"

# y el caso dificil: el acento escondido en un heredoc de install-apex.sh
mkdir -p "${TMP}/repo_here/sql" "${TMP}/repo_here/scripts"
printf 'SELECT 1 FROM dual;\n' > "${TMP}/repo_here/sql/10.sql"
printf 'log "fuera del heredoc: ac\xc3\xa1 los acentos SI valen"\n' >  "${TMP}/repo_here/scripts/install-apex.sh"
printf 'sqlplus <<SQL\nPROMPT operaci\xc3\xb3n\nSQL\n'              >> "${TMP}/repo_here/scripts/install-apex.sh"
esperado 1 sql-ascii "detecta un acento DENTRO del heredoc" -- check_sql_ascii "${TMP}/repo_here"

# --- init-example-integrity ---------------------------------------------
mkdir -p "${TMP}/ej_ok" && : > "${TMP}/ej_ok/01.sh.example" && chmod +x "${TMP}/ej_ok/01.sh.example"
mkdir -p "${TMP}/ej_nox" && : > "${TMP}/ej_nox/01.sh.example" && chmod -x "${TMP}/ej_nox/01.sh.example"
esperado 0 init-example "acepta plantillas con +x"  -- check_init_example_integrity "${TMP}/ej_ok"
esperado 1 init-example "detecta plantilla sin +x"  -- check_init_example_integrity "${TMP}/ej_nox"

# --- env-drift y build-password -----------------------------------------
esperado 1 env-drift "detecta una clave derivada divergente" \
  -- check_env_drift "$(env_con "APEX_DB_IMAGE=${IMAGE_NAME}:${IMAGE_TAG}" 'ORDS_TAG=99.9.9')"
esperado 3 env-drift "sin .env es SKIP" -- check_env_drift "${TMP}/no_existe_env"
esperado 1 build-password "detecta espacio"  -- check_build_password X 'a b'
esperado 1 build-password "detecta vacia"    -- check_build_password X ''
esperado 1 build-password "detecta &"        -- check_build_password X 'a&b'
esperado 0 build-password "acepta la default" -- check_build_password X 'Apex_Lab_2026#'

# ---------------------------------------------------------------------------
# End to end: los codigos de salida y la deteccion de modo
# ---------------------------------------------------------------------------
printf '\nEnd to end de doctor.sh\n\n'

# Un "proyecto derivado": compose.yml + .env + init/ + la unidad portable.
PROY="${TMP}/proyecto"
mkdir -p "${PROY}/scripts/lib" "${PROY}/init" "${PROY}/cache/apex/$(dirname "${ORDS_STATIC_PROBE}")"
cp "${REPO}/doctor.sh" "${PROY}/"
cp "${REPO}"/scripts/lib/*.sh "${PROY}/scripts/lib/"
cp "${REPO}/compose.yml" "${PROY}/"
# El .env sale de .env.example, NO del .env local: asi el test es hermetico
# —no depende de como quedo configurada esta maquina— y corre igual en un
# checkout limpio de CI, donde .env no existe porque lo genera ./build.sh.
cp "${REPO}/.env.example" "${PROY}/.env"
: > "${PROY}/cache/apex/${ORDS_STATIC_PROBE}"
printf '#!/bin/sh\n' > "${PROY}/init/01_workspace.sh" && chmod +x "${PROY}/init/01_workspace.sh"

e2e() { # e2e <rc esperado> <descripcion> <dir> [args...]
  local want="$1" desc="$2" dir="$3"; shift 3
  local out got=0
  out="$(cd "${dir}" && ./doctor.sh --static "$@" 2>&1)" || got=$?
  E2E_OUT="${out}"
  if [[ "${got}" -eq "${want}" ]]; then
    N_PASS=$((N_PASS+1)); printf '  %sok%s    %-24s %s\n' "${C_G}" "${C_0}" "exit-code" "${desc}"
  else
    N_FAIL=$((N_FAIL+1)); printf '  %sFALLO%s %-24s %s (esperaba %s, dio %s)\n' \
      "${C_R}" "${C_0}" "exit-code" "${desc}" "${want}" "${got}"
    printf '%s\n' "${out}" | sed 's/^/        /'
  fi
}

e2e 0 "proyecto sano da 0" "${PROY}"
if grep -q 'modo proyecto' <<< "${E2E_OUT}" && grep -qE '\[SKIP\] +profile-match' <<< "${E2E_OUT}"; then
  N_PASS=$((N_PASS+1)); printf '  %sok%s    %-24s %s\n' "${C_G}" "${C_0}" "modo-proyecto" "detecta el modo y SKIPea lo build-side"
else
  N_FAIL=$((N_FAIL+1)); printf '  %sFALLO%s %-24s %s\n' "${C_R}" "${C_0}" "modo-proyecto" "no detecto el modo o no SKIPeo"
  printf '%s\n' "${E2E_OUT}" | sed 's/^/        /'
fi

sed -i 's/^BIND_ADDR=.*/BIND_ADDR=0.0.0.0/' "${PROY}/.env"
e2e 2 "solo WARN da 2" "${PROY}"
sed -i 's/^BIND_ADDR=.*/BIND_ADDR=127.0.0.1/' "${PROY}/.env"

chmod -x "${PROY}/init/01_workspace.sh"
e2e 1 "un FAIL da 1" "${PROY}"
chmod +x "${PROY}/init/01_workspace.sh"

e2e 0 "el repo real esta sano" "${REPO}"

# ---------------------------------------------------------------------------
printf '\n  %s%d pasaron%s' "${C_G}" "${N_PASS}" "${C_0}"
[[ ${N_FAIL} -eq 0 ]] || printf '   %s%d fallaron%s' "${C_R}" "${N_FAIL}" "${C_0}"
printf '\n\n'
[[ ${N_FAIL} -eq 0 ]]
