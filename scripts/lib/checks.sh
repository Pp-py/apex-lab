#!/usr/bin/env bash
#
# checks.sh — Constantes y chequeos compartidos por build.sh y doctor.sh.
#
# Existe para que un invariante del entorno esté escrito UNA vez. Antes, el
# charset de contraseñas, las claves derivadas del .env y la validación de
# perfil vivían sueltos dentro de build.sh; el doctor los habría copiado, que es
# exactamente el patrón que este repo dice haber sacado.
#
# Contrato de cada check_*: NO imprime nada. Devuelve un código y deja el texto
# en dos variables, para que el que llama decida qué hacer con él —build.sh
# aborta, doctor.sh reporta y sigue—:
#
#   0  OK
#   1  FAIL   algo está mal y hay que arreglarlo
#   2  WARN   funciona, pero conviene mirarlo
#   3  SKIP   falta el insumo (todavía no corriste ./build.sh): NO es un fallo
#
#   CHECK_DETAIL  por qué, ya formateado para imprimir
#   CHECK_FIX     el comando exacto que lo arregla, o vacío
#
# Se sourcea desde build.sh y desde doctor.sh. No ejecutar directamente.
#
# shellcheck shell=bash
#
# SC2034 desactivado para todo el archivo, no por descuido: este archivo es
# ÍNTEGRAMENTE una librería. Todo lo que define lo consumen build.sh, doctor.sh
# y checks-env.sh, que shellcheck no ve al analizarlo suelto, así que marcaría
# como "unused" cada constante y cada variable de salida.
# shellcheck disable=SC2034

# Guarda de inclusión: los `readonly` de abajo abortarían en un segundo source.
[[ -n "${APEXLAB_CHECKS_SH:-}" ]] && return 0
readonly APEXLAB_CHECKS_SH=1

# ---------------------------------------------------------------------------
# Constantes: los invariantes del entorno, en un solo lugar
# ---------------------------------------------------------------------------

# Charset permitido en las contraseñas de BUILD. Viajan a los .sql por
# sustitución de SQL*Plus y como parámetro posicional de apex_rest_config.sql:
# un '&', una comilla, un espacio o un backslash las parte en dos y la imagen
# queda con una contraseña distinta de la documentada, sin error visible hasta
# el primer login.
readonly PASSWORD_SAFE_CHARS='A-Za-z0-9_.#%+=:,@^~*()!?/-'

# Claves de .env que NO se editan a mano: se derivan de versions.env y del
# perfil de imagen. Ver derived_value() y check_env_drift().
readonly DERIVED_KEYS=(
  APEX_DB_IMAGE ORDS_TAG ORACLE_PASSWORD DB_HEALTHCHECK_CMD DB_SEED_DIR
)

# Variables que compose declara SIN valor por defecto para pasárselas a los
# scripts de init/. Si falta una, compose falla al levantar.
readonly SEED_VARS=(
  APP_WORKSPACE APP_SCHEMA APP_WS_USER APP_EMAIL APP_PASSWORD PDBADMIN_PASSWORD
)

# Lo ÚNICO que el entrypoint de la imagen ejecuta del directorio de semillas.
# Cualquier otro nombre lo loguea como `ignoring` y sigue: por eso las
# plantillas terminan en `.example` y quedan inertes hasta renombrarlas.
readonly SEED_RUN_EXTENSIONS=('sh' 'sql' 'sql.zip' 'sql.gz')

# Estático de APEX que sirve de sonda: si este archivo no está bajo el montaje
# que ORDS recibe en /opt/oracle/apex, el Builder carga sin estilos.
readonly ORDS_STATIC_PROBE='images/apex_ui/css/Core.min.css'

# ---------------------------------------------------------------------------
# Primitivos de resultado
# ---------------------------------------------------------------------------
CHECK_DETAIL=""
CHECK_FIX=""
# Los ítems crudos del último chequeo que enumera cosas (hoy: las claves
# derivadas que divergieron). Se exponen aparte del mensaje ya armado porque
# cada consumidor los enmarca distinto: build.sh bajo ALLOW_ENV_DRIFT dice
# "se ignoran" y listarlos bajo un "corregí estas líneas" se contradiría.
CHECK_ITEMS=()

_ok()   { CHECK_DETAIL="${1:-}"; CHECK_FIX="";        return 0; }
_fail() { CHECK_DETAIL="$1";     CHECK_FIX="${2:-}";  return 1; }
_warn() { CHECK_DETAIL="$1";     CHECK_FIX="${2:-}";  return 2; }
_skip() { CHECK_DETAIL="$1";     CHECK_FIX="";        return 3; }

# ---------------------------------------------------------------------------
# Lectura de .env
# ---------------------------------------------------------------------------

# Lee una clave de un archivo .env. La última aparición gana, igual que docker
# compose. Ignora las líneas comentadas.
env_value() {
  local key="$1" file="$2"
  [[ -f "${file}" ]] || return 0
  sed -n "s/^[[:space:]]*${key}=//p" "${file}" | tail -1
}

# Valor que DEBE tener cada clave derivada, según versions.env + base-profile.sh.
# Requiere que el que llama los haya sourceado antes.
derived_value() {
  case "$1" in
    APEX_DB_IMAGE)      printf '%s' "${IMAGE_NAME}:${IMAGE_TAG}" ;;
    ORDS_TAG)           printf '%s' "${ORDS_TAG}" ;;
    ORACLE_PASSWORD)    printf '%s' "${BUILD_ORACLE_PASSWORD}" ;;
    DB_HEALTHCHECK_CMD) printf '%s' "${DB_HEALTHCHECK_CMD}" ;;
    DB_SEED_DIR)        printf '%s' "${DB_SEED_DIR}" ;;
    *)                  printf 'derived_value: clave desconocida %s' "$1" >&2; return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# Chequeos
# ---------------------------------------------------------------------------

# El perfil define convenciones (variable de contraseña, healthcheck, seed dir)
# que solo valen para su familia de imágenes. Cruzarlos no falla acá: falla más
# tarde y de forma oscura — el healthcheck no existe, la variable de contraseña
# se ignora y la base arranca con una contraseña que nadie eligió.
check_profile_match() {
  case "${DB_IMAGE_PROFILE}" in
    gvenzl)
      [[ "${DB_BASE_IMAGE}" == gvenzl/* ]] || _fail \
        "DB_IMAGE_PROFILE='gvenzl' pero DB_BASE_IMAGE='${DB_BASE_IMAGE}'.
   El perfil gvenzl espera una imagen 'gvenzl/*'. Revisá versions.env." || return 1
      ;;
    oracle)
      [[ "${DB_BASE_IMAGE}" == container-registry.oracle.com/* ]] || _fail \
        "DB_IMAGE_PROFILE='oracle' pero DB_BASE_IMAGE='${DB_BASE_IMAGE}'.
   El perfil oracle espera una imagen 'container-registry.oracle.com/*'.
   Revisá versions.env." || return 1
      ;;
  esac
  _ok "perfil '${DB_IMAGE_PROFILE}' coherente con ${DB_BASE_IMAGE}"
}

# Contraseñas de BUILD: allowlist estricta, porque pasan por SQL*Plus.
check_build_password() {
  local name="$1" value="${2-}"

  [[ -n "${value}" ]] || _fail "${name} está vacío en versions.env." || return 1

  if [[ "${value}" =~ [^${PASSWORD_SAFE_CHARS}] ]]; then
    _fail "${name} contiene caracteres que rompen la sustitución de SQL*Plus.
   Permitidos: ${PASSWORD_SAFE_CHARS}
   Prohibidos en particular: & \" ' \\ \$ y espacios. Elegí otra en versions.env." \
      "editar versions.env y volver a correr ./build.sh"
    return 1
  fi
  _ok "${name} con caracteres seguros"
}

# Contraseñas de las SEMILLAS: regla DISTINTA y más laxa que la de build.
# Denylist literal, la misma que aplican init.example/00_pdbadmin.sh y
# 01_workspace.sh: la clave viaja dentro de un identificador entrecomillado del
# CREATE/ALTER USER, así que una comilla lo parte en dos. Usar acá la allowlist
# de build sería reportar como rotas contraseñas que las semillas aceptan.
seed_password_is_safe() {
  [[ ! "$1" =~ [\"\'\\[:space:]] ]]
}

check_required_commands() {
  local missing=() cmd
  for cmd in docker curl unzip; do
    command -v "${cmd}" >/dev/null 2>&1 || missing+=("${cmd}")
  done

  # SHA_CMD queda global: fetch_apex() de build.sh lo usa.
  if command -v sha256sum >/dev/null 2>&1; then
    SHA_CMD="sha256sum"
  elif command -v shasum >/dev/null 2>&1; then
    SHA_CMD="shasum -a 256"
  else
    missing+=("sha256sum|shasum")
  fi

  [[ ${#missing[@]} -eq 0 ]] || _fail "Faltan comandos: ${missing[*]}" || return 1
  _ok "docker, curl, unzip y sha256sum disponibles"
}

check_docker_daemon() {
  docker info >/dev/null 2>&1 \
    || _fail "El daemon de Docker no responde." "arrancar Docker" || return 1
  _ok "el daemon de Docker responde"
}

# Avisa si a un filesystem le falta espacio. NO falla: df no siempre reporta
# bien montajes de Docker Desktop u overlays remotos, y un falso negativo no
# justifica bloquear el build.
check_free_space() {
  local path="$1" need_gb="$2" label="$3" free_gb
  free_gb=$(df -Pk "${path}" 2>/dev/null | awk 'NR==2 {printf "%d", $4/1024/1024}') \
    || { _ok "espacio en ${path}: no se pudo medir"; return 0; }
  [[ -n "${free_gb}" ]] || { _ok "espacio en ${path}: no se pudo medir"; return 0; }

  if [[ ${free_gb} -lt ${need_gb} ]]; then
    _warn "Solo ${free_gb} GB libres en ${path} (${label}). Se recomiendan >= ${need_gb} GB."
    return 2
  fi
  _ok "${free_gb} GB libres en ${path} (${label})"
}

# Compara el bloque derivado del .env contra versions.env + base-profile.sh.
# Deja en CHECK_DETAIL las líneas exactas a corregir, que es lo que hace
# accionable el error: sin eso, "el .env divergió" obliga a diffear a mano.
check_env_drift() {
  local env_file="$1"
  [[ -f "${env_file}" ]] || _skip "no existe ${env_file}; lo genera ./build.sh" || return 3

  local drift=() key expected actual
  CHECK_ITEMS=()
  for key in "${DERIVED_KEYS[@]}"; do
    expected="$(derived_value "${key}")"
    actual="$(env_value "${key}" "${env_file}")"
    [[ "${actual}" == "${expected}" ]] \
      || drift+=("${key}=${expected}     <- en .env dice: ${actual:-<ausente>}")
  done

  CHECK_ITEMS=("${drift[@]}")
  if [[ ${#drift[@]} -gt 0 ]]; then
    _fail "El .env divergió de versions.env. Corregí estas líneas en ${env_file}:

$(printf '       %s\n' "${drift[@]}")" \
      "editar ${env_file} con esos valores, o ALLOW_ENV_DRIFT=1 ./build.sh"
    return 1
  fi
  _ok "las ${#DERIVED_KEYS[@]} claves derivadas coinciden con versions.env"
}
