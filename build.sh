#!/usr/bin/env bash
#
# build.sh — Construye una imagen de Oracle Database Free con APEX ya instalado.
#
# Estrategia: `docker run` + `docker commit`, NO un Dockerfile.
# Motivo: la base de datos tiene que estar levantada para correr apexins.sql, y
# un `RUN` de BuildKit no permite fijar --shm-size (por defecto 64 MB), lo que
# hace fallar el arranque de la SGA. Con run+commit controlamos memoria, shm y
# el apagado limpio de la instancia.
#
# Uso:
#   ./build.sh                    # build completo
#   KEEP_ON_ERROR=1 ./build.sh    # no borra el contenedor si falla (para debug)
#   ALLOW_ENV_DRIFT=1 ./build.sh  # no aborta si .env divergió de versions.env
#
# Requisitos: docker, curl, unzip, sha256sum (o shasum en macOS).
#
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly CACHE_DIR="${SCRIPT_DIR}/cache"
readonly BUILD_CONTAINER="apex-lab-build"
readonly APEX_INSTALL_TIMEOUT=3600
# DB_READY_TIMEOUT lo define scripts/base-profile.sh según la imagen base.

# Claves de .env que NO se editan a mano: se derivan de versions.env y del
# perfil de imagen. Ver sync_env().
readonly DERIVED_KEYS=(
  APEX_DB_IMAGE ORDS_TAG ORACLE_PASSWORD DB_HEALTHCHECK_CMD DB_INITDB_DIR
)

# Charset permitido en las contraseñas de build. Las contraseñas viajan a los
# .sql por sustitución de SQL*Plus y como parámetro posicional de
# apex_rest_config.sql: un '&', una comilla, un espacio o un backslash las parte
# en dos y la imagen queda con una contraseña distinta de la documentada, sin
# error visible hasta el primer login.
readonly PASSWORD_SAFE_CHARS='A-Za-z0-9_.#%+=:,@^~*()!?/-'

log()  { printf '\033[1;34m[apex-lab]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[apex-lab] WARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[apex-lab] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# Limpieza del contenedor temporal ante cualquier salida no exitosa.
cleanup() {
  local rc=$?
  if [[ ${rc} -ne 0 ]]; then
    if [[ "${KEEP_ON_ERROR:-0}" == "1" ]]; then
      warn "Build falló (rc=${rc}). Contenedor '${BUILD_CONTAINER}' conservado."
      warn "Inspeccionar con: docker logs ${BUILD_CONTAINER}"
    else
      log "Build falló (rc=${rc}). Eliminando contenedor temporal..."
      docker rm -f "${BUILD_CONTAINER}" >/dev/null 2>&1 || true
    fi
  fi
  return ${rc}
}
trap cleanup EXIT

# --------------------------------------------------------------------------
# 0. Precondiciones
# --------------------------------------------------------------------------

# El perfil define convenciones (variable de contraseña, healthcheck, initdb dir)
# que solo valen para su familia de imágenes. Cruzarlos no falla acá: falla más
# tarde y de forma oscura — el healthcheck no existe, la variable de contraseña
# se ignora y la base arranca con una contraseña que nadie eligió.
validate_profile() {
  case "${DB_IMAGE_PROFILE}" in
    gvenzl)
      [[ "${DB_BASE_IMAGE}" == gvenzl/* ]] || die \
        "DB_IMAGE_PROFILE='gvenzl' pero DB_BASE_IMAGE='${DB_BASE_IMAGE}'.
   El perfil gvenzl espera una imagen 'gvenzl/*'. Revisá versions.env."
      ;;
    oracle)
      [[ "${DB_BASE_IMAGE}" == container-registry.oracle.com/* ]] || die \
        "DB_IMAGE_PROFILE='oracle' pero DB_BASE_IMAGE='${DB_BASE_IMAGE}'.
   El perfil oracle espera una imagen 'container-registry.oracle.com/*'.
   Revisá versions.env."
      ;;
  esac
}

validate_passwords() {
  local name value
  for name in BUILD_ORACLE_PASSWORD BUILD_APEX_ADMIN_PASSWORD; do
    value="${!name:-}"
    [[ -n "${value}" ]] || die "${name} está vacío en versions.env."
    if [[ "${value}" =~ [^${PASSWORD_SAFE_CHARS}] ]]; then
      die "${name} contiene caracteres que rompen la sustitución de SQL*Plus.
   Permitidos: ${PASSWORD_SAFE_CHARS}
   Prohibidos en particular: & \" ' \\ \$ y espacios. Elegí otra en versions.env."
    fi
  done
}

# Avisa si a un filesystem le falta espacio. No aborta: df no siempre reporta
# bien montajes de Docker Desktop u overlays remotos, y un falso negativo no
# justifica bloquear el build.
check_free_space() {
  local path="$1" need_gb="$2" label="$3" free_gb
  free_gb=$(df -Pk "${path}" 2>/dev/null | awk 'NR==2 {printf "%d", $4/1024/1024}') || return 0
  [[ -n "${free_gb}" ]] || return 0
  if [[ ${free_gb} -lt ${need_gb} ]]; then
    warn "Solo ${free_gb} GB libres en ${path} (${label}). Se recomiendan >= ${need_gb} GB."
  fi
}

check_prereqs() {
  local missing=()
  for cmd in docker curl unzip; do
    command -v "${cmd}" >/dev/null 2>&1 || missing+=("${cmd}")
  done
  if command -v sha256sum >/dev/null 2>&1; then
    SHA_CMD="sha256sum"
  elif command -v shasum >/dev/null 2>&1; then
    SHA_CMD="shasum -a 256"
  else
    missing+=("sha256sum|shasum")
  fi
  [[ ${#missing[@]} -eq 0 ]] || die "Faltan comandos: ${missing[*]}"

  docker info >/dev/null 2>&1 || die "El daemon de Docker no responde."

  # El build consume disco en DOS filesystems distintos, y no tienen por qué ser
  # el mismo: el data-root de Docker (imagen base + capa nueva, ~20 GB) y ./cache
  # en el repo (zip de APEX + extraído, ~3 GB). Medir solo el repo es el error
  # clásico: el chequeo pasa y el build muere sin espacio horas después.
  check_free_space "${SCRIPT_DIR}" 3 "cache del instalador"

  local docker_root
  docker_root=$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || true)
  if [[ -n "${docker_root}" && -d "${docker_root}" ]]; then
    check_free_space "${docker_root}" 20 "imágenes de Docker"
  else
    warn "No se pudo inspeccionar el data-root de Docker${docker_root:+ (${docker_root})}."
    warn "Verificá a mano que haya >= 20 GB libres para las imágenes."
  fi
}

# --------------------------------------------------------------------------
# 1. Sincronización de .env
#
# versions.env + scripts/base-profile.sh son la ÚNICA fuente de verdad. Cinco
# valores de .env se derivan de ahí; antes se copiaban a mano con un comentario
# pidiendo "que coincidan", que es exactamente la clase de acuerdo que nadie
# cumple seis meses después. Acá se generan (si no hay .env) o se validan.
#
# No se sobrescribe un .env existente: ahí viven tus puertos y tu
# COMPOSE_PROJECT_NAME, que son legítimamente por-proyecto.
# --------------------------------------------------------------------------
derived_value() {
  case "$1" in
    APEX_DB_IMAGE)      printf '%s' "${IMAGE_NAME}:${IMAGE_TAG}" ;;
    ORDS_TAG)           printf '%s' "${ORDS_TAG}" ;;
    ORACLE_PASSWORD)    printf '%s' "${BUILD_ORACLE_PASSWORD}" ;;
    DB_HEALTHCHECK_CMD) printf '%s' "${DB_HEALTHCHECK_CMD}" ;;
    DB_INITDB_DIR)      printf '%s' "${DB_INITDB_DIR}" ;;
    *)                  die "derived_value: clave desconocida '$1'" ;;
  esac
}

# Lee una clave de un archivo .env. La última aparición gana, igual que docker
# compose. Ignora las líneas comentadas.
env_value() {
  local key="$1" file="$2"
  sed -n "s/^[[:space:]]*${key}=//p" "${file}" | tail -1
}

# Reescribe (o agrega al final) una clave, sin tocar el resto del archivo.
set_env_key() {
  local file="$1" key="$2" value="$3" tmp
  tmp="$(mktemp)"
  if grep -qE "^[[:space:]]*${key}=" "${file}"; then
    # awk en vez de sed: el valor puede traer '&' o '/', que sed interpretaría.
    awk -v k="${key}" -v v="${value}" \
      '$0 ~ "^[[:space:]]*" k "=" { print k "=" v; next } { print }' \
      "${file}" > "${tmp}"
  else
    cat "${file}" > "${tmp}"
    printf '%s=%s\n' "${key}" "${value}" >> "${tmp}"
  fi
  mv "${tmp}" "${file}"
}

sync_env() {
  local env_file="${SCRIPT_DIR}/.env"
  local example="${SCRIPT_DIR}/.env.example"
  local key

  if [[ ! -f "${env_file}" ]]; then
    [[ -f "${example}" ]] || { warn "No hay .env ni .env.example: se omite."; return 0; }
    log "No existe .env: generándolo desde .env.example con los valores de versions.env."
    cp "${example}" "${env_file}"
    for key in "${DERIVED_KEYS[@]}"; do
      set_env_key "${env_file}" "${key}" "$(derived_value "${key}")"
    done
    log "Generado ${env_file}. Ajustá los puertos si corrés varios proyectos."
    return 0
  fi

  local drift=() expected actual
  for key in "${DERIVED_KEYS[@]}"; do
    expected="$(derived_value "${key}")"
    actual="$(env_value "${key}" "${env_file}")"
    [[ "${actual}" == "${expected}" ]] \
      || drift+=("${key}=${expected}     <- en .env dice: ${actual:-<ausente>}")
  done

  if [[ ${#drift[@]} -gt 0 ]]; then
    if [[ "${ALLOW_ENV_DRIFT:-0}" == "1" ]]; then
      warn "ALLOW_ENV_DRIFT=1: se ignoran ${#drift[@]} divergencias en .env."
      printf '       %s\n' "${drift[@]}" >&2
      return 0
    fi
    die "El .env divergió de versions.env. Corregí estas líneas en ${env_file}:

$(printf '       %s\n' "${drift[@]}")
   Se aborta antes del build y no se toca .env, para no pisar tus
   puertos ni COMPOSE_PROJECT_NAME. Para seguir igual: ALLOW_ENV_DRIFT=1 ./build.sh"
  fi
  log ".env coherente con versions.env."
}

# compose monta ./init como directorio de semillas. NO está versionado: ahí van
# el DDL y los datos de cada proyecto, que no tienen por qué viajar en este repo
# (ver .gitignore). Se siembra desde init.example/ igual que el .env.
#
# Si el directorio no existiera, Docker lo crearía solo — vacío y como root, que
# es justo el fallo silencioso que este paso evita.
seed_init_dir() {
  local init_dir="${SCRIPT_DIR}/init"
  local example_dir="${SCRIPT_DIR}/init.example"

  if [[ -d "${init_dir}" ]]; then
    return 0
  fi
  if [[ ! -d "${example_dir}" ]]; then
    warn "No existe init.example/: se crea ./init vacío."
    mkdir -p "${init_dir}"
    return 0
  fi
  log "No existe ./init: sembrándolo desde init.example/."
  cp -R "${example_dir}" "${init_dir}"
}

# --------------------------------------------------------------------------
# 2. Descarga y verificación del instalador de APEX
# --------------------------------------------------------------------------
fetch_apex() {
  local zip="${CACHE_DIR}/apex_${APEX_VERSION}.zip"
  mkdir -p "${CACHE_DIR}"

  if [[ -f "${zip}" ]]; then
    log "Zip de APEX ${APEX_VERSION} ya en cache."
  else
    log "Descargando APEX ${APEX_VERSION} desde Oracle..."
    curl -fSL --retry 3 --retry-delay 5 -o "${zip}.part" "${APEX_URL}" \
      || die "No se pudo descargar ${APEX_URL}"
    mv "${zip}.part" "${zip}"
  fi

  local actual
  actual=$(${SHA_CMD} "${zip}" | awk '{print $1}')
  if [[ -z "${APEX_SHA256}" ]]; then
    warn "APEX_SHA256 está vacío en versions.env. Build sin verificación de integridad."
    warn "Pegá esto en versions.env para fijarlo:"
    printf '\n    APEX_SHA256="%s"\n\n' "${actual}" >&2
  elif [[ "${actual}" != "${APEX_SHA256}" ]]; then
    die "SHA256 no coincide.
     esperado: ${APEX_SHA256}
     obtenido: ${actual}
   Si Oracle re-publicó el release (pasó con 26.1 el 25/05/2026), borrá
   ${zip}, actualizá el hash y volvé a correr."
  else
    log "SHA256 verificado."
  fi

  # Se extrae en el host porque el contenedor de ORDS también necesita
  # ./cache/apex/images para servir los estáticos (/i/).
  if [[ ! -d "${CACHE_DIR}/apex" ]]; then
    log "Extrayendo instalador..."
    unzip -q "${zip}" -d "${CACHE_DIR}"
  fi
  [[ -f "${CACHE_DIR}/apex/apexins.sql" ]] \
    || die "No se encontró ${CACHE_DIR}/apex/apexins.sql tras extraer."
}

# --------------------------------------------------------------------------
# 3. Arranque del contenedor de build
# --------------------------------------------------------------------------
start_build_container() {
  log "Descargando imagen base ${DB_BASE_IMAGE}..."
  docker pull "${DB_BASE_IMAGE}"

  docker rm -f "${BUILD_CONTAINER}" >/dev/null 2>&1 || true

  log "Arrancando contenedor de build..."
  # --shm-size=2g: la SGA de Oracle se aloja en /dev/shm. Con el default de
  # 64 MB la instancia no levanta (ORA-00845 o fallo de asignación).
  docker run -d \
    --name "${BUILD_CONTAINER}" \
    --shm-size=2g \
    -e "${DB_PASSWORD_ENV}=${BUILD_ORACLE_PASSWORD}" \
    "${DB_BASE_IMAGE}" >/dev/null

  log "Esperando a que la base esté lista (máx ${DB_READY_TIMEOUT}s)..."
  local waited=0
  until docker exec "${BUILD_CONTAINER}" "${DB_HEALTHCHECK_CMD}" >/dev/null 2>&1; do
    docker ps -q --filter "name=^${BUILD_CONTAINER}$" | grep -q . \
      || die "El contenedor murió. Ver: docker logs ${BUILD_CONTAINER}"
    (( waited += 5 ))
    [[ ${waited} -lt ${DB_READY_TIMEOUT} ]] \
      || die "Timeout esperando la base de datos."
    sleep 5
  done
  log "Base de datos lista tras ${waited}s."
}

# --------------------------------------------------------------------------
# 4. Instalación de APEX dentro del contenedor
# --------------------------------------------------------------------------
install_apex() {
  log "Copiando instalador y scripts al contenedor..."
  docker cp "${CACHE_DIR}/apex"      "${BUILD_CONTAINER}:/tmp/apex"
  docker cp "${SCRIPT_DIR}/sql"      "${BUILD_CONTAINER}:/tmp/sql"
  docker cp "${SCRIPT_DIR}/scripts/install-apex.sh" \
                                     "${BUILD_CONTAINER}:/tmp/install-apex.sh"

  # `docker cp` preserva el uid/gid NUMERICO del host, que dentro del contenedor
  # no le corresponde a nadie: el runtime es oracle (54321), no tu usuario.
  # apexins.sql hace SPOOL de su log en el directorio actual, asi que sin este
  # chown el build muere a los 2 segundos con `SP2-0606: Cannot create SPOOL
  # file`, un error que no menciona permisos por ningun lado.
  # Se resuelve el uid en tiempo de ejecución en vez de hardcodear
  # `oracle:oinstall`, para que el perfil `oracle` funcione sin tocar esto.
  log "Ajustando propietario de los archivos copiados..."
  local run_uid run_gid
  run_uid=$(docker exec "${BUILD_CONTAINER}" id -u) \
    || die "No se pudo determinar el uid runtime del contenedor."
  run_gid=$(docker exec "${BUILD_CONTAINER}" id -g) \
    || die "No se pudo determinar el gid runtime del contenedor."
  docker exec -u 0 "${BUILD_CONTAINER}" \
    chown -R "${run_uid}:${run_gid}" /tmp/apex /tmp/sql /tmp/install-apex.sh \
    || die "No se pudo ajustar el propietario de /tmp/apex, /tmp/sql e install-apex.sh."

  log "Instalando APEX ${APEX_VERSION}. Tarda entre 4 y 30 minutos según la máquina."
  log "Seguimiento en vivo: docker logs -f ${BUILD_CONTAINER}"
  # El timeout va DENTRO del contenedor. Un `timeout` en el host solo mata al
  # cliente `docker exec`: apexins.sql seguiría corriendo adentro, a ciegas, y
  # el cleanup borraría el contenedor con la instalación a medias.
  local rc=0
  docker exec \
    -e APEX_ADMIN_PASSWORD="${BUILD_APEX_ADMIN_PASSWORD}" \
    -e APEX_ADMIN_EMAIL="${BUILD_APEX_ADMIN_EMAIL}" \
    -e APEX_PUBLIC_USER_PASSWORD="${BUILD_ORACLE_PASSWORD}" \
    -e DB_PDB="${DB_PDB}" \
    "${BUILD_CONTAINER}" \
    timeout "${APEX_INSTALL_TIMEOUT}" bash /tmp/install-apex.sh || rc=$?

  if [[ ${rc} -eq 124 ]]; then
    die "La instalación de APEX superó ${APEX_INSTALL_TIMEOUT}s y fue abortada.
   Si tu máquina es lenta, subí APEX_INSTALL_TIMEOUT en este script."
  elif [[ ${rc} -ne 0 ]]; then
    die "La instalación de APEX falló (rc=${rc}). Revisar la salida de arriba."
  fi

  log "Limpiando archivos temporales de la imagen..."
  docker exec "${BUILD_CONTAINER}" rm -rf /tmp/apex /tmp/sql /tmp/install-apex.sh
}

# --------------------------------------------------------------------------
# 5. Apagado limpio y commit
# --------------------------------------------------------------------------
commit_image() {
  # `docker stop` dispara el SIGTERM que el entrypoint de la imagen traduce en
  # un `shutdown immediate`. Nunca hacer `kill`: dejaría datafiles inconsistentes.
  log "Apagando la base de datos de forma limpia..."
  docker stop -t 180 "${BUILD_CONTAINER}" >/dev/null \
    || die "No se pudo apagar la base limpiamente."

  local full_tag="${IMAGE_NAME}:${IMAGE_TAG}"
  log "Generando imagen ${full_tag}..."
  # Las comillas INTERNAS no son decorativas: `--change` parsea el LABEL como
  # una línea de Dockerfile, o sea que parte por espacios. Un valor sin comillas
  # con espacios falla con "Syntax error - can't find = in ...", nombrando la
  # segunda palabra del valor y sin pista de cual label es.
  docker commit \
    --change 'LABEL org.opencontainers.image.title="apex-lab"' \
    --change 'LABEL org.opencontainers.image.description="Oracle Database Free + Oracle APEX preinstalado (entorno local de desarrollo)"' \
    --change "LABEL io.apexlab.db-base=\"${DB_BASE_IMAGE}\"" \
    --change "LABEL io.apexlab.apex-version=\"${APEX_VERSION}\"" \
    --change "LABEL io.apexlab.base-profile=\"${DB_IMAGE_PROFILE}\"" \
    --change "LABEL io.apexlab.built-at=\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"" \
    "${BUILD_CONTAINER}" "${full_tag}" >/dev/null

  docker tag "${full_tag}" "${IMAGE_NAME}:${IMAGE_TAG_MOVING}"
  docker rm -f "${BUILD_CONTAINER}" >/dev/null

  # `docker image inspect .Size` NO es lo que ocupa en disco: con el image store
  # de containerd devuelve el tamaño de los blobs (comprimidos), y reporta ~3 GB
  # para una imagen que `docker images` muestra como 16 GB. Se usa la misma
  # fuente que ve el usuario, para no prometerle un quinto del disco real.
  local size
  size=$(docker images --format '{{.Size}}' "${full_tag}" | head -1)
  size="${size:-desconocido}"

  cat >&2 <<EOF

  ────────────────────────────────────────────────────────────────
  Imagen lista: ${full_tag}  (${size})
  También etiquetada como ${IMAGE_NAME}:${IMAGE_TAG_MOVING}

  Arrancar el stack completo (BD + ORDS + Mailpit):
      docker compose up -d

  APEX Builder:  http://localhost:8080/ords/apex
    Workspace INTERNAL / ADMIN / ${BUILD_APEX_ADMIN_PASSWORD}
  Conexión SQL:  system/${BUILD_ORACLE_PASSWORD}@localhost:1521/FREEPDB1
  ────────────────────────────────────────────────────────────────

EOF
}

# --------------------------------------------------------------------------
main() {
  [[ -f "${SCRIPT_DIR}/versions.env" ]] || die "Falta versions.env"
  # shellcheck source=versions.env
  source "${SCRIPT_DIR}/versions.env"
  # shellcheck source=scripts/base-profile.sh
  source "${SCRIPT_DIR}/scripts/base-profile.sh"

  log "Perfil de imagen base: ${DB_IMAGE_PROFILE} (${DB_BASE_IMAGE})"
  # Todo lo barato que puede abortar el build va primero: no tiene sentido
  # descubrir un .env divergente con el build ya avanzado.
  validate_profile
  validate_passwords
  check_prereqs
  sync_env
  seed_init_dir
  fetch_apex
  start_build_container
  install_apex
  commit_image
}

main "$@"
