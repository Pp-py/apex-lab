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

# Constantes y chequeos compartidos con doctor.sh: DERIVED_KEYS,
# PASSWORD_SAFE_CHARS, derived_value(), env_value() y los check_* que más abajo
# se envuelven en `|| die`. Viven ahí y no acá para que doctor.sh los use sin
# copiarlos: un invariante del entorno se escribe una sola vez.
# shellcheck source=scripts/lib/checks.sh
source "${SCRIPT_DIR}/scripts/lib/checks.sh"

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

# Los chequeos viven en scripts/lib/checks.sh y no imprimen: devuelven un
# código y dejan el texto en CHECK_DETAIL. Acá se los envuelve en `|| die`,
# que es la única diferencia con el uso que les da doctor.sh —el mismo
# chequeo, una política distinta—.
validate_profile() {
  check_profile_match || die "${CHECK_DETAIL}"
}

validate_passwords() {
  local name
  for name in BUILD_ORACLE_PASSWORD BUILD_APEX_ADMIN_PASSWORD; do
    check_build_password "${name}" "${!name:-}" || die "${CHECK_DETAIL}"
  done
}

check_prereqs() {
  check_required_commands || die "${CHECK_DETAIL}"
  check_docker_daemon     || die "${CHECK_DETAIL}"

  # El build consume disco en DOS filesystems distintos, y no tienen por qué ser
  # el mismo: el data-root de Docker (imagen base + capa nueva, ~20 GB) y ./cache
  # en el repo (zip de APEX + extraído, ~3 GB). Medir solo el repo es el error
  # clásico: el chequeo pasa y el build muere sin espacio horas después.
  check_free_space "${SCRIPT_DIR}" 3 "cache del instalador" || warn "${CHECK_DETAIL}"

  local docker_root
  docker_root=$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || true)
  if [[ -n "${docker_root}" && -d "${docker_root}" ]]; then
    check_free_space "${docker_root}" 20 "imágenes de Docker" || warn "${CHECK_DETAIL}"
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
# derived_value() y env_value() viven en scripts/lib/checks.sh: doctor.sh los
# necesita igual y son la definición de qué valor le corresponde a cada clave.
# set_env_key() se queda acá: escribe, y el doctor nunca escribe.

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

  local rc=0
  check_env_drift "${env_file}" || rc=$?

  if [[ ${rc} -ne 0 ]]; then
    if [[ "${ALLOW_ENV_DRIFT:-0}" == "1" ]]; then
      warn "ALLOW_ENV_DRIFT=1: se ignoran ${#CHECK_ITEMS[@]} divergencias en .env."
      printf '       %s\n' "${CHECK_ITEMS[@]}" >&2
      return 0
    fi
    die "${CHECK_DETAIL}
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

  # Y renombrar, quitando el sufijo. El entrypoint SOLO ejecuta *.sh, *.sql,
  # *.sql.zip y *.sql.gz; cualquier otro nombre lo loguea como `ignoring`.
  # Copiadas tal cual, las tres semillas quedan INERTES y el proyecto arranca
  # sin workspace, sin esquema y sin ACL — sin un solo mensaje de error. El
  # sufijo existe para que las plantillas versionadas no corran; dentro de
  # init/ ya no tiene sentido. El chequeo `init-inert-example` de doctor.sh
  # cubre el caso de que alguien copie a mano y se olvide.
  local seed
  for seed in "${init_dir}"/*.example; do
    # Un glob sin match se expande a sí mismo: sin esto se intentaría mover
    # un archivo llamado literalmente '*.example'.
    [[ -e "${seed}" ]] || continue
    mv "${seed}" "${seed%.example}"
  done
  log "Semillas listas en ./init (sufijo .example quitado)."
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

  # Los puertos salen del .env, no de un literal. Son legítimamente por-proyecto
  # —el README manda cambiarlos para correr varios en paralelo— y un mensaje
  # final que siempre dijera 8080 mandaría al usuario al stack de otro proyecto,
  # o al de otra persona. Los defaults son los mismos que aplica compose.yml.
  local ords_port db_port
  ords_port="$(env_value ORDS_PORT "${SCRIPT_DIR}/.env")"; ords_port="${ords_port:-8080}"
  db_port="$(env_value DB_PORT "${SCRIPT_DIR}/.env")";     db_port="${db_port:-1521}"

  cat >&2 <<EOF

  ────────────────────────────────────────────────────────────────
  Imagen lista: ${full_tag}  (${size})
  También etiquetada como ${IMAGE_NAME}:${IMAGE_TAG_MOVING}

  Arrancar el stack completo (BD + ORDS + Mailpit):
      docker compose up -d

  APEX Builder:  http://localhost:${ords_port}/ords/apex
    Workspace INTERNAL / ADMIN / ${BUILD_APEX_ADMIN_PASSWORD}
  Conexión SQL:  system/${BUILD_ORACLE_PASSWORD}@localhost:${db_port}/FREEPDB1
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
