#!/usr/bin/env bash
#
# test-roundtrip.sh — Self-test de los parsers de scripts/lib/roundtrip.sh.
#
# NO necesita Docker, ni la base, ni SQLcl: le da a cada parser las salidas
# REALES que SQLcl 26.1.2 produjo —capturadas una por una contra la imagen
# ords:26.1.2— y verifica el código que devuelve.
#
# Por qué esto no es opcional: toda la cadena de Oracle que apex-roundtrip.sh
# usa sale con 0 cuando falla. `apex validate` con errores de sintaxis sale 0;
# con el directorio inexistente, 0; con una opción mal escrita, 0. Un parser
# con el grep mal puesto reporta PASS sobre una app rota y nadie se entera
# nunca, porque el exit code de SQLcl le da la razón.
#
# Sin dependencias: bash y coreutils. Corre en CI junto al shellcheck.
#
# Uso:  ./scripts/test-roundtrip.sh
# Sale: 0 si pasan todos, 1 si falla alguno.
#
set -Eeuo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO

# roundtrip.sh solo necesita de checks.sh los primitivos _ok/_fail/_warn/_skip.
# shellcheck source=scripts/lib/checks.sh
source "${REPO}/scripts/lib/checks.sh"
# shellcheck source=scripts/lib/roundtrip.sh
source "${REPO}/scripts/lib/roundtrip.sh"

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
    printf '  %sok%s    %-22s %s\n' "${C_G}" "${C_0}" "${id}" "${desc}"
  else
    N_FAIL=$((N_FAIL+1))
    printf '  %sFALLO%s %-22s %s  (esperaba rc=%s, dio rc=%s)\n' \
      "${C_R}" "${C_0}" "${id}" "${desc}" "${want}" "${got}"
    printf '        detalle: %s\n' "${CHECK_DETAIL%%$'\n'*}"
  fi
}

# contiene <texto-esperado> <id> <descripcion>
# Verifica el MENSAJE, no solo el codigo: un FAIL que no dice por que obliga a
# leer el log igual, y entonces el parser no sirvio de nada. Mira tambien
# CHECK_FIX, que es la mitad accionable del diagnostico.
contiene() {
  local aguja="$1" id="$2" desc="$3"
  if [[ "${CHECK_DETAIL}${CHECK_FIX}" == *"${aguja}"* ]]; then
    N_PASS=$((N_PASS+1)); printf '  %sok%s    %-22s %s\n' "${C_G}" "${C_0}" "${id}" "${desc}"
  else
    N_FAIL=$((N_FAIL+1))
    printf '  %sFALLO%s %-22s %s  (no menciona "%s")\n' "${C_R}" "${C_0}" "${id}" "${desc}" "${aguja}"
    printf '        detalle: %s\n' "${CHECK_DETAIL}"
  fi
}

# log <nombre> <contenido...>  -> imprime la ruta del archivo creado
log() { local n="$1"; shift; printf '%s\n' "$@" > "${TMP}/${n}"; printf '%s' "${TMP}/${n}"; }

# ---------------------------------------------------------------------------
# Salidas REALES de SQLcl 26.1.2. Copiadas tal cual, no reescritas a mano:
# si alguna vez cambian, el test tiene que fallar para que alguien mire.
# ---------------------------------------------------------------------------
L_VAL_OK="$(log val_ok 'Validation successful.')"
L_VAL_SINTAXIS="$(log val_sintaxis \
  'APEXLang Compile Errors:' \
  'File: pages/p00001-home.apx' \
  'Line: 36' \
  'Column: 0' \
  'Type: SYNTAX' \
  "Error: token recognition error at: 'esto no e'")"
L_VAL_NORUTA="$(log val_noruta 'Could not find file or directory with inputPath: /tmp/no-existe')"
L_VAL_OPCION="$(log val_opcion "'-exitwhendone' at column 42: Option not recognized")"
L_VACIO="$(log vacio '')"
L_AUSENTE="${TMP}/no-existe.log"

L_IMP_OK="$(log imp_ok 'Importing application ID: 9000 into workspace: DEV' 'Import successful.')"
L_IMP_WS="$(log imp_ws 'Workspace: NO_EXISTE from workspace input is invalid')"
L_IMP_CONN="$(log imp_conn \
  'Connection failed' \
  '  USER          = nadie' \
  '  URL           = jdbc:oracle:thin:@db:1521/FREEPDB1' \
  '  Error Message = ORA-01017: invalid credential or not authorized; logon denied')"
# El caso que un timeout produce: empezo y nunca confirmo.
L_IMP_TRUNCO="$(log imp_trunco 'Importing application ID: 9000 into workspace: DEV')"

printf '\nParsers de SQLcl (0=OK 1=FAIL)\n\n'

# --- rt_parse_validate ---------------------------------------------------
esperado 0 parse-validate "acepta la linea de exito"            -- rt_parse_validate "${L_VAL_OK}"
esperado 1 parse-validate "detecta errores de sintaxis"         -- rt_parse_validate "${L_VAL_SINTAXIS}"
esperado 1 parse-validate "detecta la ruta inexistente"         -- rt_parse_validate "${L_VAL_NORUTA}"
esperado 1 parse-validate "detecta la opcion no reconocida"     -- rt_parse_validate "${L_VAL_OPCION}"
esperado 1 parse-validate "el log vacio es fallo, no exito"     -- rt_parse_validate "${L_VACIO}"
esperado 1 parse-validate "el log ausente es fallo"             -- rt_parse_validate "${L_AUSENTE}"

# Los cuatro fallos de arriba salen con rc=0 en SQLcl. Este bloque es el que
# demuestra que el parser no se deja enganar por eso.
rt_parse_validate "${L_VAL_SINTAXIS}" || true
contiene 'no compila'            parse-validate "explica que el APEXlang no compila"
rt_parse_validate "${L_VAL_NORUTA}" || true
contiene 'docker cp'             parse-validate "apunta al docker cp, no a la app"
rt_parse_validate "${L_VAL_OPCION}" || true
contiene 'bug de este script'    parse-validate "se acusa a si mismo, no a la app"

# Con -x y no por substring: una linea que EMPIECE con el marcador no alcanza.
L_VAL_PARCIAL="$(log val_parcial 'Validation successful. 3 of 4 files')"
esperado 1 parse-validate "no acepta el marcador como substring" -- rt_parse_validate "${L_VAL_PARCIAL}"

# El marcador con CR y sangria (lo que deja SQLcl segun como se lo invoque).
L_VAL_CR="$(printf '  Validation successful.\r\n' > "${TMP}/val_cr"; printf '%s' "${TMP}/val_cr")"
esperado 0 parse-validate "tolera CR y sangria"                 -- rt_parse_validate "${L_VAL_CR}"

# --- rt_parse_import -----------------------------------------------------
esperado 0 parse-import "acepta la linea de exito"              -- rt_parse_import "${L_IMP_OK}"
esperado 1 parse-import "detecta el workspace invalido"         -- rt_parse_import "${L_IMP_WS}"
esperado 1 parse-import "detecta la conexion fallida"           -- rt_parse_import "${L_IMP_CONN}"
esperado 1 parse-import "detecta la ruta inexistente"           -- rt_parse_import "${L_VAL_NORUTA}"
esperado 1 parse-import "el log truncado NO es exito"           -- rt_parse_import "${L_IMP_TRUNCO}"
esperado 1 parse-import "el log vacio es fallo"                 -- rt_parse_import "${L_VACIO}"

rt_parse_import "${L_IMP_WS}" || true
contiene 'APP_WORKSPACE'  parse-import "nombra la variable del .env que lo causa"
rt_parse_import "${L_IMP_CONN}" || true
contiene 'APP_SCHEMA'     parse-import "nombra las credenciales del .env"

printf '\nInventario del origen\n\n'

# --- rt_source_pages / rt_source_statics ---------------------------------
APP="${TMP}/app"
mkdir -p "${APP}/pages" "${APP}/shared-components/static-files/icons"
: > "${APP}/pages/p00000-global-page.apx"
: > "${APP}/pages/p00001-home.apx"
: > "${APP}/pages/p09999-login.apx"
: > "${APP}/pages/notas.md"                      # no es una pagina
: > "${APP}/shared-components/static-files/icons/app-icon-32.png"
: > "${APP}/shared-components/static-files/app.js"

igual() {
  local want="$1" got="$2" id="$3" desc="$4"
  if [[ "${want}" == "${got}" ]]; then
    N_PASS=$((N_PASS+1)); printf '  %sok%s    %-22s %s\n' "${C_G}" "${C_0}" "${id}" "${desc}"
  else
    N_FAIL=$((N_FAIL+1))
    printf '  %sFALLO%s %-22s %s  (esperaba "%s", dio "%s")\n' \
      "${C_R}" "${C_0}" "${id}" "${desc}" "${want}" "${got}"
  fi
}

igual 3 "$(rt_source_pages "${APP}")"        source-pages   "cuenta solo los p*.apx"
igual 0 "$(rt_source_pages "${TMP}/nada")"   source-pages   "sin pages/ devuelve 0, no error"
igual "app.js
icons/app-icon-32.png" "$(rt_source_statics "${APP}")" source-statics "nombres relativos y ordenados"
igual "" "$(rt_source_statics "${TMP}/nada")" source-statics "sin static-files/ no devuelve nada"

# ---------------------------------------------------------------------------
printf '\n  %d pasaron' "${N_PASS}"
[[ ${N_FAIL} -eq 0 ]] || printf ',  %s%d FALLARON%s' "${C_R}" "${N_FAIL}" "${C_0}"
printf '\n\n'
[[ ${N_FAIL} -eq 0 ]]
