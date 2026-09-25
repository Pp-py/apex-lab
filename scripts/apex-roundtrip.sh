#!/usr/bin/env bash
#
# apex-roundtrip.sh — Valida el round-trip completo de una aplicación APEXlang.
#
#   fuente .apx -> apex validate -> apex import -> app corriendo -> smoke test
#
# Responde una pregunta que este repo sabía hacerse y no sabía contestar:
# apps.example/README.md documenta cómo exportar a APEXlang y termina diciendo
# "Sin verificar en este entorno: el round-trip". Un .apx que nadie probó a
# re-importar es un backup que nadie probó a restaurar.
#
# Todo el trabajo lo hace el SQLcl que ya viene dentro del contenedor de ORDS.
# Acá no hay framework nuevo: hay un wrapper que sabe leer lo que contesta,
# que resulta ser la parte difícil (ver la cabecera de scripts/lib/roundtrip.sh).
#
# Uso:
#   ./scripts/apex-roundtrip.sh                 genera la app de referencia y la prueba
#   ./scripts/apex-roundtrip.sh apps/mi-app     prueba un árbol APEXlang propio
#   ./scripts/apex-roundtrip.sh --id 9001 ...   otro ID destino
#   ./scripts/apex-roundtrip.sh --force ...     importa aunque el ID sea de otra app
#   ./scripts/apex-roundtrip.sh --help
#
# Códigos de salida, por etapa: es lo que hace útil un fallo en CI.
#   0   PASS
#   1   falló VALIDATE
#   2   falló IMPORT
#   3   fallaron los RUNTIME CHECKS
#   4   falló el SMOKE TEST
#   64  uso incorrecto
#   70  falta una librería, Docker, o el entorno no se pudo resolver
#   75  prerequisito: el stack no está arriba, o el ID destino es de otra app
#
# NO levanta ni baja el stack, no borra apps y no toca el .env. Lo único que
# escribe es la app destino y su propio directorio de evidencia.
#
set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Rutas. Las librerías esperan SCRIPT_DIR = raíz del proyecto (es lo que
# doctor.sh les pasa y lo que `docker compose --project-directory` necesita);
# este script vive un nivel más abajo, igual que test-doctor.sh.
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly SCRIPT_DIR
readonly LIB_DIR="${SCRIPT_DIR}/scripts/lib"
readonly ENV_FILE="${SCRIPT_DIR}/.env"
readonly EVIDENCE_DIR="${SCRIPT_DIR}/artifacts/roundtrip"

APP_DIR=""
APP_ID=""
FORCE=0

usage() {
  # Imprime la cabecera de este archivo hasta la primera linea que no sea
  # comentario. Un rango fijo de lineas se desincroniza en cuanto alguien
  # agrega un parrafo, y el --help empieza a mostrar codigo sin que falle nada.
  awk 'NR > 2 { if (!/^#/) exit; sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"
  cat <<'EOF'

Fuera de alcance a propósito:
  - No re-exporta para diffear contra el origen: `generate` y `export`
    normalizan distinto y el diff sería ruido. La fidelidad se mide contra el
    diccionario de datos (páginas y static files), que es más fiable.
  - No inicia sesión en la app: verifica que se sirve, no que un usuario pueda
    operarla. Hacerlo necesitaría credenciales y dejaría de ser determinista.
  - Solo el perfil `gvenzl`, como el resto del repo.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --id)      [[ $# -ge 2 ]] || { printf 'ERROR: --id necesita un numero\n' >&2; exit 64; }
               APP_ID="$2"; shift 2 ;;
    --force)   FORCE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*)        printf 'Opcion desconocida: %s\n\n' "$1" >&2; usage >&2; exit 64 ;;
    *)         [[ -z "${APP_DIR}" ]] || { printf 'ERROR: solo se acepta un directorio\n' >&2; exit 64; }
               APP_DIR="$1"; shift ;;
  esac
done

[[ -z "${APP_ID}" || "${APP_ID}" =~ ^[0-9]+$ ]] || {
  printf 'ERROR: --id tiene que ser un numero, no "%s"\n' "${APP_ID}" >&2; exit 64; }

# ---------------------------------------------------------------------------
# Librerías
# ---------------------------------------------------------------------------
if [[ ! -f "${LIB_DIR}/checks.sh" ]]; then
  printf 'ERROR: falta %s/checks.sh\n' "${LIB_DIR}" >&2
  printf '   Este script no viaja solo. Copia tambien scripts/lib/ desde apex-lab.\n' >&2
  exit 70
fi
# shellcheck source=scripts/lib/checks.sh
source "${LIB_DIR}/checks.sh"
# shellcheck source=scripts/lib/checks-runtime.sh
source "${LIB_DIR}/checks-runtime.sh"
# shellcheck source=scripts/lib/roundtrip.sh
source "${LIB_DIR}/roundtrip.sh"

APP_ID="${APP_ID:-${RT_APP_ID_DEFAULT}}"
readonly APP_ID FORCE

# ---------------------------------------------------------------------------
# Reporte
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_OK=$'\033[1;32m'; C_WARN=$'\033[1;33m'; C_FAIL=$'\033[1;31m'
  C_SKIP=$'\033[1;30m'; C_HEAD=$'\033[1;34m'; C_FIX=$'\033[0;36m'; C_OFF=$'\033[0m'
else
  C_OK=""; C_WARN=""; C_FAIL=""; C_SKIP=""; C_HEAD=""; C_FIX=""; C_OFF=""
fi

STAGE=""          # etapa en curso, para el mensaje final
EV_STAGE=""       # log propio de la etapa, si tiene
EV_TRANSCRIPT=""  # transcripcion completa de la corrida
N_FAIL=0

# etapa <nombre> [log-propio]
#
# Todo veredicto va SIEMPRE a roundtrip.log —la transcripcion completa, en
# orden, que es lo que se lee cuando algo falla— y ademas al log de su etapa
# cuando la etapa tiene uno. Sin el segundo destino, runtime.log y
# smoke-test.log salian con el mismo contenido acumulado y ninguno de los dos
# servia para lo que su nombre promete.
etapa() {
  STAGE="$1"
  EV_STAGE="${2:+${EVIDENCE_DIR}/$2}"
  [[ -z "${EV_STAGE}" ]] || : > "${EV_STAGE}"
  printf '\n%s== %s ==%s\n' "${C_HEAD}" "$1" "${C_OFF}"
}

# Imprime un resultado ya calculado (CHECK_DETAIL / CHECK_FIX) y contabiliza.
_emit() {
  local rc="$1" id="$2" color tag first rest line
  case "${rc}" in
    0) color="${C_OK}";   tag="OK"   ;;
    2) color="${C_WARN}"; tag="WARN" ;;
    3) color="${C_SKIP}"; tag="SKIP" ;;
    *) color="${C_FAIL}"; tag="FAIL"; N_FAIL=$((N_FAIL+1)) ;;
  esac
  first="${CHECK_DETAIL%%$'\n'*}"
  printf '  %s[%-4s]%s %-22s %s\n' "${color}" "${tag}" "${C_OFF}" "${id}" "${first}"
  if [[ "${CHECK_DETAIL}" == *$'\n'* ]]; then
    rest="${CHECK_DETAIL#*$'\n'}"
    while IFS= read -r line; do printf '         %s\n' "${line#   }"; done <<< "${rest}"
  fi
  [[ -z "${CHECK_FIX}" ]] || printf '         %s-> %s%s\n' "${C_FIX}" "${CHECK_FIX}" "${C_OFF}"
  # A la evidencia va lo mismo, sin colores.
  local linea
  linea="$(printf '[%s] %s: %s\n' "${tag}" "${id}" "${CHECK_DETAIL}"
           [[ -z "${CHECK_FIX}" ]] || printf '       -> %s\n' "${CHECK_FIX}")"
  printf '%s\n' "${linea}" >> "${EV_TRANSCRIPT}"
  [[ -z "${EV_STAGE}" ]] || printf '%s\n' "${linea}" >> "${EV_STAGE}"
}

chequeo() {
  local id="$1"; shift
  local rc=0
  CHECK_DETAIL=""; CHECK_FIX=""
  "$@" || rc=$?
  _emit "${rc}" "${id}"
  return 0
}

# Sale reportando la etapa. El texto es el mismo que queda en summary.txt.
morir() {
  local rc="$1" motivo="$2"
  printf '\n  %sFAIL%s en %s: %s\n\n' "${C_FAIL}" "${C_OFF}" "${STAGE}" "${motivo}"
  printf 'FAIL\netapa: %s\nmotivo: %s\nfecha: %s\n' \
    "${STAGE}" "${motivo}" "$(date -u +%FT%TZ)" > "${EVIDENCE_DIR}/summary.txt" 2>/dev/null || true
  exit "${rc}"
}

# ---------------------------------------------------------------------------
main() {
  # --- Prerequisitos -------------------------------------------------------
  STAGE="PREREQUISITOS"
  command -v docker >/dev/null 2>&1 || { printf 'ERROR: falta docker\n' >&2; exit 70; }
  [[ -f "${ENV_FILE}" ]] || { printf 'ERROR: falta %s. Corre ./build.sh primero.\n' "${ENV_FILE}" >&2; exit 70; }

  runtime_resolve || { printf 'ERROR: Docker no responde (docker info).\n' >&2; exit 70; }

  local workspace schema
  workspace="$(env_value APP_WORKSPACE "${ENV_FILE}")"
  schema="$(env_value APP_SCHEMA "${ENV_FILE}")"
  [[ -n "${workspace}" && -n "${schema}" ]] || {
    printf 'ERROR: faltan APP_WORKSPACE o APP_SCHEMA en %s\n' "${ENV_FILE}" >&2; exit 70; }

  mkdir -p "${EVIDENCE_DIR}"
  EV_TRANSCRIPT="${EVIDENCE_DIR}/roundtrip.log"; : > "${EV_TRANSCRIPT}"

  printf '%s[apex-lab roundtrip]%s %s\n' "${C_HEAD}" "${C_OFF}" "${SCRIPT_DIR}"
  printf '  proyecto %s  ·  app %s en el workspace %s  ·  esquema %s\n' \
    "${RT_PROJECT}" "${APP_ID}" "${workspace}" "${schema}"

  # El stack tiene que estar arriba: este script no lo levanta. Levantarlo
  # implicaria decidir por el usuario una espera que puede ser de minutos (el
  # primer `up` de un proyecto copia ~4,5 GB al volumen) y que no es lo que
  # pidio al correr un test.
  local rc=0
  CHECK_DETAIL=""; CHECK_FIX=""
  rt_require_services || rc=$?
  _emit "${rc}" servicios
  [[ ${rc} -eq 0 ]] || morir 75 "${CHECK_DETAIL%%$'\n'*}"

  # --- Origen --------------------------------------------------------------
  etapa "ORIGEN"
  local src_host="${EVIDENCE_DIR}/app" src_remote app_dir_abs=""

  # Validar el origen ANTES de tocar nada. Al reves —y asi estaba— apuntar el
  # script a su propia copia de evidencia borraba el arbol y recien despues se
  # quejaba de que no era APEXlang: destruia el origen para informar de un
  # error que el mismo acababa de causar.
  if [[ -n "${APP_DIR}" ]]; then
    [[ -d "${APP_DIR}" ]] || morir 64 "'${APP_DIR}' no existe"
    [[ -f "${APP_DIR}/application.apx" ]] || \
      morir 64 "'${APP_DIR}' no parece un arbol APEXlang: no tiene application.apx"
    app_dir_abs="$(cd "${APP_DIR}" && pwd)"
  fi

  # Si el origen YA es la copia de evidencia, no hay nada que copiar.
  [[ "${app_dir_abs}" == "${src_host}" ]] || rm -rf "${src_host}"

  # Directorio ÚNICO por corrida dentro del contenedor. No es prolijidad: es
  # correccion. `apex validate` recorre el arbol entero, asi que un resto de
  # una corrida anterior se valida junto con lo de esta y los errores salen
  # apuntando a archivos que ya no existen en el origen. Pasó de verdad.
  #
  # Y limpiar el directorio viejo hay que hacerlo COMO ROOT: `docker cp` deja
  # los archivos con el uid NUMERICO del host (1000), que adentro no le
  # corresponde a nadie, asi que un `rm -rf` con el usuario del contenedor da
  # "Permission denied". Es el bug #1 de docs/validacion-e2e.md reapareciendo
  # en otro lado. Va best-effort: la correccion la da el directorio unico, no
  # esta limpieza.
  local run_dir="${RT_WORKDIR}/$$"
  docker exec -u 0 "${RT_ORDS}" rm -rf "${RT_WORKDIR}" >/dev/null 2>&1 || true
  docker exec "${RT_ORDS}" mkdir -p "${run_dir}" >/dev/null 2>&1 || true

  if [[ -n "${APP_DIR}" ]]; then
    [[ "${app_dir_abs}" == "${src_host}" ]] || cp -R "${app_dir_abs}" "${src_host}"
    src_remote="${run_dir}/src"
    # El `/.` del origen y el destino ya creado NO son intercambiables con
    # `docker cp dir contenedor:destino`: si el destino existe, docker mete el
    # directorio ADENTRO en vez de volcar su contenido, y el arbol queda
    # anidado un nivel. Asi es deterministico en los dos casos.
    docker exec "${RT_ORDS}" mkdir -p "${src_remote}" >/dev/null 2>&1 || true
    docker cp "${src_host}/." "${RT_ORDS}:${src_remote}" >/dev/null
    _ok "arbol propio: ${APP_DIR}"; _emit 0 origen
  else
    # La app de referencia la genera el propio SQLcl. Ver rt_run_generate.
    if ! rt_run_generate "${workspace}" "${schema}" "${APP_ID}" "${run_dir}" "${EVIDENCE_DIR}/generate.log"; then
      CHECK_DETAIL="apex generate no creo la app de referencia.
   $(sed -n '1,6p' "${EVIDENCE_DIR}/generate.log" | sed 's/^/       /')"
      CHECK_FIX="cat ${EVIDENCE_DIR#"${SCRIPT_DIR}"/}/generate.log"
      _emit 1 origen
      morir 70 "no se pudo generar la app de referencia"
    fi
    src_remote="${run_dir}/${RT_ALIAS,,}"
    docker cp "${RT_ORDS}:${src_remote}" "${src_host}" >/dev/null
    _ok "app de referencia generada por SQLcl ($(rt_source_pages "${src_host}") paginas)"
    _emit 0 origen
  fi

  # Confirmar que lo que SQLcl va a leer es lo que creemos. Sin esto, un
  # `docker cp` a medias se manifiesta como un error de sintaxis incomprensible
  # tres etapas mas abajo.
  if ! docker exec "${RT_ORDS}" test -f "${src_remote}/application.apx" 2>/dev/null; then
    CHECK_DETAIL="El arbol no llego completo al contenedor de ORDS: falta
   ${src_remote}/application.apx."
    CHECK_FIX="docker exec ${RT_ORDS} ls -la ${src_remote}"
    _emit 1 origen-en-contenedor
    morir 70 "el origen no llego al contenedor"
  fi

  # --- 1. VALIDATE ---------------------------------------------------------
  etapa "VALIDATE"
  rt_run_validate "${src_remote}" "${workspace}" "${EVIDENCE_DIR}/validate.log"
  CHECK_DETAIL=""; CHECK_FIX=""
  rt_parse_validate "${EVIDENCE_DIR}/validate.log" && rc=0 || rc=$?
  _emit "${rc}" validate
  [[ ${rc} -eq 0 ]] || morir 1 "el APEXlang de origen no valida"

  # --- 2. IMPORT -----------------------------------------------------------
  etapa "IMPORT"

  # Guarda de propiedad. `apex import` sobrescribe sin preguntar: sin esto,
  # un ID mal puesto se lleva puesta la app de alguien y no hay deshacer.
  local alias_actual
  alias_actual="$(rt_app_alias "${APP_ID}")"
  if [[ -z "${alias_actual}" ]]; then
    CHECK_DETAIL="No se pudo consultar apex_applications para saber si el ID ${APP_ID}
   esta libre. Sin esa respuesta no se importa: seria pisar a ciegas."
    CHECK_FIX="./doctor.sh   # empezar por ahi"
    _emit 1 guarda-de-id
    morir 75 "no se pudo verificar el ID destino"
  fi
  if [[ "${alias_actual}" != "LIBRE" && "${alias_actual}" != "${RT_ALIAS}" ]]; then
    if [[ ${FORCE} -eq 0 ]]; then
      CHECK_DETAIL="El ID ${APP_ID} ya lo ocupa la app '${alias_actual}', que NO es la de
   este test. Importar la sobrescribiria entera y sin deshacer."
      CHECK_FIX="./scripts/apex-roundtrip.sh --id <otro>   # o --force si de verdad querés pisarla"
      _emit 1 guarda-de-id
      morir 75 "el ID ${APP_ID} pertenece a la app '${alias_actual}'"
    fi
    # El `|| true` no es adorno: _warn DEVUELVE 2 y con `set -Eeuo pipefail`
    # una llamada suelta mata el script. Los primitivos de checks.sh estan
    # pensados para leerse con `|| return N`, no como sentencia.
    _warn "El ID ${APP_ID} es de la app '${alias_actual}' y se sobrescribe por --force." "" || true
    _emit 2 guarda-de-id
  else
    local estado="libre"
    [[ "${alias_actual}" == "LIBRE" ]] || estado="ocupado por ${RT_ALIAS}, que es la app de este test"
    _ok "ID ${APP_ID} ${estado}"
    _emit 0 guarda-de-id
  fi

  rt_run_import "${src_remote}" "${workspace}" "${schema}" "${APP_ID}" "${EVIDENCE_DIR}/import.log"
  CHECK_DETAIL=""; CHECK_FIX=""
  rt_parse_import "${EVIDENCE_DIR}/import.log" && rc=0 || rc=$?
  _emit "${rc}" import
  [[ ${rc} -eq 0 ]] || morir 2 "el import no se completo"

  # --- 3. RUNTIME CHECKS ---------------------------------------------------
  etapa "RUNTIME CHECKS" runtime.log
  N_FAIL=0
  chequeo apex-registry     check_apex_registry
  chequeo ords-http         check_builder_http
  chequeo app-row           rt_check_app_row "${APP_ID}" "${workspace}" "${schema}"
  chequeo pages-fidelity    rt_check_pages_fidelity "${APP_ID}" "${src_host}"
  chequeo statics-fidelity  rt_check_static_fidelity "${APP_ID}" "${src_host}"
  chequeo schema-objects    rt_check_schema_objects "${schema}"
  [[ ${N_FAIL} -eq 0 ]] || morir 3 "${N_FAIL} chequeo(s) de runtime en FAIL"

  # --- 4. SMOKE TEST -------------------------------------------------------
  etapa "SMOKE TEST" smoke-test.log
  N_FAIL=0
  local nombre alias_db ws_db
  nombre="$(_sql1 "SELECT NVL(MAX(application_name), 'NINGUNA') FROM apex_applications WHERE application_id = ${APP_ID};")"
  alias_db="$(_sql1 "SELECT NVL(MAX(alias), 'NINGUNA') FROM apex_applications WHERE application_id = ${APP_ID};")"
  ws_db="$(_sql1 "SELECT NVL(MAX(workspace), 'NINGUNA') FROM apex_applications WHERE application_id = ${APP_ID};")"

  if [[ -z "${nombre}" || "${nombre}" == "NINGUNA" ]]; then
    CHECK_DETAIL="No se pudo leer el nombre de la app importada; sin el, el smoke test
   no tiene con que distinguir la pagina real del error de APEX."
    CHECK_FIX=""
    _emit 1 app-http
    morir 4 "no se pudo resolver la identidad de la app"
  fi

  local smoke_html="${EVIDENCE_DIR}/app-response.html"
  chequeo app-http     rt_smoke_app "${APP_ID}" "${nombre}" "${smoke_html}"
  chequeo static-http  rt_smoke_static "${APP_ID}" "${ws_db}" "${alias_db}"
  [[ ${N_FAIL} -eq 0 ]] || morir 4 "${N_FAIL} chequeo(s) del smoke test en FAIL"

  # --- Evidencia -----------------------------------------------------------
  {
    printf 'PASS\n'
    printf 'fecha: %s\n' "$(date -u +%FT%TZ)"
    printf 'proyecto: %s\n' "${RT_PROJECT}"
    printf 'app: %s (id %s, alias %s, workspace %s, esquema %s)\n' \
      "${nombre}" "${APP_ID}" "${alias_db}" "${ws_db}" "${schema}"
    printf 'origen: %s\n' "${APP_DIR:-apex generate (app de referencia)}"
    printf 'paginas: %s\n' "$(rt_source_pages "${src_host}")"
    printf 'static files: %s\n' "$(rt_source_statics "${src_host}" | grep -c . || true)"
    printf 'endpoint: %s/ords/f?p=%s:1\n' "${RT_ORDS_URL}" "${APP_ID}"
  } > "${EVIDENCE_DIR}/summary.txt"

  printf '\n  %sPASS%s  round-trip completo\n' "${C_OK}" "${C_OFF}"
  printf '  evidencia en %s/\n' "${EVIDENCE_DIR#"${SCRIPT_DIR}"/}"
  printf '  la app quedo en %s/ords/f?p=%s:1\n\n' "${RT_ORDS_URL}" "${APP_ID}"
}

main
