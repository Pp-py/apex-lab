#!/usr/bin/env bash
#
# doctor.sh — Diagnostica un entorno apex-lab y explica cada hallazgo.
#
# Convierte en ejecutable el troubleshooting que el repo ya tenía escrito: la
# tabla "Problemas frecuentes" del README, las "Trampas conocidas" de
# CLAUDE.md, los bugs de docs/validacion-e2e.md y las notas de
# init.example/README.md. Ese conocimiento solo servía si alguien se acordaba
# de leerlo; acá se ejecuta.
#
# NO REPARA NADA. Cada hallazgo imprime el comando exacto y lo corrés vos:
# varias reparaciones de este entorno son destructivas (un `down -v` borra la
# base) y no es una decisión que deba tomar una herramienta de diagnóstico.
#
# Uso:
#   ./doctor.sh              diagnóstico completo
#   ./doctor.sh --static     solo lo que no necesita Docker (lo que corre en CI)
#   ./doctor.sh --help
#
# Salida:  0 todo bien   1 hay [FAIL]   2 solo hay [WARN]
#
# Corre en el repo y también en un directorio de proyecto derivado, donde no
# hay versions.env ni sql/. Ahí los chequeos que dependen de eso se reportan
# como [SKIP] con el motivo, NUNCA como [OK]: un chequeo que no se pudo hacer
# no es un chequeo que pasó.
#
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly LIB_DIR="${SCRIPT_DIR}/scripts/lib"

STATIC_ONLY=0

usage() {
  sed -n '3,28p' "${BASH_SOURCE[0]}" | sed 's/^#\{1,2\} \{0,1\}//'
  cat <<'EOF'

Fuera de alcance a propósito:
  - Los 7 bugs del build de docs/validacion-e2e.md: ya están corregidos en el
    código y solo volverían como regresión. Eso lo atrapa un test del build.
  - Wallet TLS (ORA-29024 / ORA-28860): depende del endpoint concreto.
  - El perfil `oracle` de base-profile.sh: sigue sin ejercitarse y el doctor
    no finge cubrirlo.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --static)    STATIC_ONLY=1; shift ;;
    -h|--help)   usage; exit 0 ;;
    *)           printf 'Opcion desconocida: %s\n\n' "$1" >&2; usage >&2; exit 64 ;;
  esac
done

# ---------------------------------------------------------------------------
# Librerías. En un proyecto derivado tienen que haberse copiado junto a este
# archivo: son la unidad portable (ver la receta del README).
# ---------------------------------------------------------------------------
if [[ ! -f "${LIB_DIR}/checks.sh" ]]; then
  printf 'ERROR: falta %s/checks.sh\n' "${LIB_DIR}" >&2
  printf '   doctor.sh no viaja solo. Copiá tambien scripts/lib/ desde apex-lab:\n' >&2
  printf '       mkdir -p scripts && cp -r <ruta-a-apex-lab>/scripts/lib scripts/\n' >&2
  exit 70
fi
# shellcheck source=scripts/lib/checks.sh
source "${LIB_DIR}/checks.sh"
# shellcheck source=scripts/lib/checks-env.sh
source "${LIB_DIR}/checks-env.sh"
# shellcheck source=scripts/lib/checks-runtime.sh
source "${LIB_DIR}/checks-runtime.sh"

# ---------------------------------------------------------------------------
# Modo. Lo decide la presencia del árbol de build, no un flag: en un directorio
# de proyecto hay compose.yml y .env, pero no versions.env ni sql/.
# ---------------------------------------------------------------------------
if [[ -f "${SCRIPT_DIR}/versions.env" && -f "${SCRIPT_DIR}/scripts/base-profile.sh" ]]; then
  MODE="repo"
  # shellcheck source=versions.env
  source "${SCRIPT_DIR}/versions.env"
  # shellcheck source=scripts/base-profile.sh
  source "${SCRIPT_DIR}/scripts/base-profile.sh"
else
  MODE="proyecto"
fi
readonly MODE
readonly ENV_FILE="${SCRIPT_DIR}/.env"
readonly COMPOSE_FILE="${SCRIPT_DIR}/compose.yml"

# ---------------------------------------------------------------------------
# Reporte
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_OK=$'\033[1;32m'; C_WARN=$'\033[1;33m'; C_FAIL=$'\033[1;31m'
  C_SKIP=$'\033[1;30m'; C_HEAD=$'\033[1;34m'; C_FIX=$'\033[0;36m'; C_OFF=$'\033[0m'
else
  C_OK=""; C_WARN=""; C_FAIL=""; C_SKIP=""; C_HEAD=""; C_FIX=""; C_OFF=""
fi

N_OK=0; N_WARN=0; N_FAIL=0; N_SKIP=0

section() { printf '\n%s%s%s\n' "${C_HEAD}" "$1" "${C_OFF}"; }

_emit() {
  local color="$1" tag="$2" id="$3" text="$4" fix="$5" first rest line
  first="${text%%$'\n'*}"
  # El tag va a ancho fijo: [OK] y [SKIP] no miden lo mismo y la columna de
  # ids se desalinea, que es justo lo que hace ilegible una lista larga.
  printf '  %s[%-4s]%s %-24s %s\n' "${color}" "${tag}" "${C_OFF}" "${id}" "${first}"

  # Las líneas siguientes traen su propia sangría de 3 espacios (así se leen
  # bien también cuando las imprime build.sh con `die`); acá se re-alinean.
  if [[ "${text}" == *$'\n'* ]]; then
    rest="${text#*$'\n'}"
    while IFS= read -r line; do
      printf '         %s\n' "${line#   }"
    done <<< "${rest}"
  fi
  [[ -z "${fix}" ]] || printf '         %s-> %s%s\n' "${C_FIX}" "${fix}" "${C_OFF}"
}

# run_check <id> <funcion> [args...]
run_check() {
  local id="$1"; shift
  local rc=0
  CHECK_DETAIL=""; CHECK_FIX=""
  "$@" || rc=$?
  case "${rc}" in
    0) N_OK=$((N_OK+1));   _emit "${C_OK}"   "OK"   "${id}" "${CHECK_DETAIL}" "" ;;
    2) N_WARN=$((N_WARN+1)); _emit "${C_WARN}" "WARN" "${id}" "${CHECK_DETAIL}" "${CHECK_FIX}" ;;
    3) N_SKIP=$((N_SKIP+1)); _emit "${C_SKIP}" "SKIP" "${id}" "${CHECK_DETAIL}" "" ;;
    *) N_FAIL=$((N_FAIL+1)); _emit "${C_FAIL}" "FAIL" "${id}" "${CHECK_DETAIL}" "${CHECK_FIX}" ;;
  esac
}

# Para los chequeos que solo existen en modo repo: reporta el SKIP con el
# motivo en vez de omitirlos de la lista. Que un chequeo no aplique tiene que
# verse; si desaparece, nadie nota que dejó de correr.
skip_en_proyecto() {
  _skip "requiere el arbol de build (versions.env, sql/); no existe en un proyecto"
}

# ---------------------------------------------------------------------------
main() {
  printf '%s[apex-lab doctor]%s modo %s  ·  %s\n' \
    "${C_HEAD}" "${C_OFF}" "${MODE}" "${SCRIPT_DIR}"

  section "Entorno y configuracion"
  run_check prereqs                check_required_commands
  run_check free-space             check_free_space "${SCRIPT_DIR}" 3 "cache e imagenes"
  if [[ "${MODE}" == "repo" ]]; then
    run_check profile-match        check_profile_match
    run_check build-password       check_build_password BUILD_ORACLE_PASSWORD "${BUILD_ORACLE_PASSWORD:-}"
    run_check env-drift            check_env_drift "${ENV_FILE}"
    run_check apex-sha             check_apex_sha "${SCRIPT_DIR}"
  else
    run_check profile-match        skip_en_proyecto
    run_check build-password       skip_en_proyecto
    run_check env-drift            skip_en_proyecto
    run_check apex-sha             skip_en_proyecto
  fi
  run_check app-password-charset   check_app_passwords "${ENV_FILE}"
  run_check init-seed-vars         check_seed_vars "${ENV_FILE}"
  run_check bind-addr              check_bind_addr "${ENV_FILE}"

  section "Convenciones del codigo"
  if [[ "${MODE}" == "repo" ]]; then
    run_check sql-ascii            check_sql_ascii "${SCRIPT_DIR}"
    run_check init-example-integrity check_init_example_integrity "${SCRIPT_DIR}/init.example"
  else
    run_check sql-ascii            skip_en_proyecto
    run_check init-example-integrity skip_en_proyecto
  fi

  section "Stack declarado (compose e init)"
  run_check compose-shm            check_compose_shm "${COMPOSE_FILE}"
  run_check seed-dir-mount         check_seed_dir_mount "${ENV_FILE}"
  run_check ords-static-mount      check_ords_static_mount "${SCRIPT_DIR}" "${MODE}"
  run_check init-exec-bit          check_init_exec_bit "${SCRIPT_DIR}/init"
  run_check init-inert-example     check_init_inert "${SCRIPT_DIR}/init"

  if [[ ${STATIC_ONLY} -eq 0 ]]; then
    section "Stack en ejecucion"
    runtime_checks
  fi

  # -------------------------------------------------------------------------
  printf '\n  %s%d OK%s   %s%d WARN%s   %s%d FAIL%s   %s%d SKIP%s\n' \
    "${C_OK}" "${N_OK}" "${C_OFF}" "${C_WARN}" "${N_WARN}" "${C_OFF}" \
    "${C_FAIL}" "${N_FAIL}" "${C_OFF}" "${C_SKIP}" "${N_SKIP}" "${C_OFF}"

  if [[ ${N_FAIL} -gt 0 ]]; then
    printf '  Hay %d problema(s) que arreglar.\n\n' "${N_FAIL}"
    exit 1
  fi
  if [[ ${N_WARN} -gt 0 ]]; then
    printf '  Nada roto, pero hay %d aviso(s) para mirar.\n\n' "${N_WARN}"
    exit 2
  fi
  printf '  Entorno sano.\n\n'
}

main
