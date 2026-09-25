#!/usr/bin/env bash
#
# checks-env.sh — Chequeos estáticos propios de doctor.sh: los que miran
# archivos del host y no necesitan que el stack esté levantado.
#
# Cada uno recibe las rutas por parámetro en vez de leer globales. Es lo que
# hace que scripts/test-doctor.sh pueda apuntarlos a directorios rotos a
# propósito sin ensuciar el repo.
#
# Mismo contrato que checks.sh: 0 OK / 1 FAIL / 2 WARN / 3 SKIP, con el texto
# en CHECK_DETAIL y el comando en CHECK_FIX.
#
# Se sourcea después de checks.sh. No ejecutar directamente.
#
# shellcheck shell=bash
# shellcheck disable=SC2034   # ver la nota de checks.sh: esto es una librería

[[ -n "${APEXLAB_CHECKS_ENV_SH:-}" ]] && return 0
readonly APEXLAB_CHECKS_ENV_SH=1

# Detector de no-ASCII, usado por check_sql_ascii.
#
# El rango de bytes va literal ([^<tab><espacio>-~]) y NO como [^[:print:]]:
# GNU grep, incluso con LC_ALL=C, considera imprimibles los bytes >= 0x80, así
# que la forma con clases deja pasar las tildes sin decir nada. Verificado.
# Equivale al `grep -P '[^\x09\x0A\x0D\x20-\x7E]'` que documenta CLAUDE.md,
# pero sin depender de que grep traiga PCRE.
_grep_non_ascii() {
  LC_ALL=C grep -n '[^	 -~]' "$@"
}

# ---------------------------------------------------------------------------
# Solo modo repo (necesitan el árbol de build)
# ---------------------------------------------------------------------------

# Todo el SQL es 100 % ASCII, sin tildes ni eñes ni en los comentarios: corre
# dentro del contenedor con el NLS_LANG heredado del entorno. La regla vale
# para los .sql Y para el SQL embebido en los heredocs de install-apex.sh, que
# es donde más fácil se cuela un literal acentuado.
check_sql_ascii() {
  local repo="$1"
  local sql_dir="${repo}/sql" installer="${repo}/scripts/install-apex.sh"
  [[ -d "${sql_dir}" ]] || _skip "no hay sql/ (modo proyecto)" || return 3

  local hits=""
  hits="$(_grep_non_ascii "${sql_dir}"/*.sql || true)"

  # Los heredocs del instalador: se acotan igual que en CLAUDE.md.
  if [[ -f "${installer}" ]]; then
    local here
    here="$(awk '/<<SQL$/,/^SQL$/' "${installer}" | _grep_non_ascii || true)"
    [[ -z "${here}" ]] || hits="${hits}${hits:+$'\n'}install-apex.sh (heredoc):${here}"
  fi

  if [[ -n "${hits}" ]]; then
    _fail "Hay caracteres no ASCII en el SQL. Corren con el NLS_LANG del
   contenedor y se corrompen sin avisar:

$(printf '       %s\n' "${hits}")" \
      "reemplazar por entidades numericas o texto sin acentos"
    return 1
  fi
  _ok "sql/*.sql y los heredocs de install-apex.sh son 100% ASCII"
}

# Las plantillas de init.example/ tienen que traer el bit de ejecución: `cp` lo
# preserva, y de ahí lo heredan las semillas reales. Si se pierde acá, se
# pierde en cada proyecto que se siembre después.
check_init_example_integrity() {
  local dir="$1"
  [[ -d "${dir}" ]] || _skip "no hay init.example/ (modo proyecto)" || return 3

  local sin_x=() f
  for f in "${dir}"/*.sh.example; do
    [[ -e "${f}" ]] || continue
    [[ -x "${f}" ]] || sin_x+=("$(basename "${f}")")
  done

  if [[ ${#sin_x[@]} -gt 0 ]]; then
    _fail "Plantillas de init.example/ sin bit de ejecucion: ${sin_x[*]}.
   cp preserva el modo, asi que las semillas de cada proyecto naceran sin +x." \
      "chmod +x ${dir}/*.sh.example"
    return 1
  fi
  _ok "las plantillas de init.example/ conservan el bit de ejecucion"
}

# El bit de ejecucion que git REGISTRA, que no siempre es el que ves en el disco.
#
# Este repo tiene core.fileMode=false, asi que git ignora el modo del
# filesystem: un `chmod +x` local no llega nunca al indice y el archivo viaja a
# 644 para todos los que clonen. En tu maquina se ve bien y en el clon no
# arranca, que es la peor combinacion posible para diagnosticar.
#
# No es teorico, paso dos veces en este repo: las tres plantillas de
# init.example/ estuvieron a 644 en git desde el primer commit —contradiciendo
# a su propio README, que promete que "ya vienen con el bit puesto"— y doctor.sh
# y test-doctor.sh se publicaron sin el bit y rompieron CI con
# "Permission denied".
#
# Por eso el chequeo compara indice contra disco en vez de tener una lista de
# archivos que "deberian" ser ejecutables: el disco es la intencion de quien
# hizo el chmod, y la divergencia es justo lo que core.fileMode oculta.
check_git_exec_bit() {
  local repo="$1"
  command -v git >/dev/null 2>&1 || _skip "sin git en el PATH" || return 3
  git -C "${repo}" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || _skip "no es un repositorio git (modo proyecto)" || return 3

  local falta_x=() sobra_x=() mode path disco
  while read -r mode _ _ path; do
    [[ -f "${repo}/${path}" ]] || continue
    if [[ -x "${repo}/${path}" ]]; then disco=100755; else disco=100644; fi
    [[ "${mode}" == "${disco}" ]] && continue
    if [[ "${disco}" == "100755" ]]; then falta_x+=("${path}"); else sobra_x+=("${path}"); fi
  done < <(git -C "${repo}" ls-files -s)

  if [[ ${#falta_x[@]} -gt 0 ]]; then
    _fail "Archivos ejecutables en disco pero a 644 en el indice de git:
   ${falta_x[*]}
   Con core.fileMode=false el chmod local no llega al indice: quien clone los
   recibe sin el bit. Un .sh de init/ asi no se ejecuta, se SOURCEA, y esa rama
   del entrypoint tiene un bug de upstream que lo vuelve ilegible." \
      "git update-index --chmod=+x ${falta_x[*]}"
    return 1
  fi
  if [[ ${#sobra_x[@]} -gt 0 ]]; then
    _warn "Archivos a 755 en el indice de git pero no ejecutables en disco:
   ${sobra_x[*]}" "git update-index --chmod=-x ${sobra_x[*]}"
    return 2
  fi
  _ok "el bit de ejecucion del indice de git coincide con el del disco"
}

# El SHA256 fijado es la única defensa contra que Oracle re-publique el zip con
# el mismo nombre. Si el de cache ya no coincide, el próximo build aborta.
check_apex_sha() {
  local repo="$1"
  local zip="${repo}/cache/apex_${APEX_VERSION:-}.zip"

  [[ -n "${APEX_VERSION:-}" ]] || _skip "no hay versions.env (modo proyecto)" || return 3
  [[ -n "${SHA_CMD:-}" ]]      || _skip "no hay sha256sum ni shasum"          || return 3
  [[ -f "${zip}" ]]            || _skip "el zip no esta en cache; lo baja ./build.sh" || return 3
  [[ -n "${APEX_SHA256:-}" ]]  || _warn "APEX_SHA256 vacio en versions.env: el build no verifica integridad" \
      "correr ./build.sh y pegar el hash que imprime" || return 2

  local actual
  actual=$(${SHA_CMD} "${zip}" | awk '{print $1}')
  if [[ "${actual}" != "${APEX_SHA256}" ]]; then
    _fail "El zip de APEX en cache no coincide con versions.env.
     esperado: ${APEX_SHA256}
     obtenido: ${actual}" \
      "rm ${zip} && ./build.sh"
    return 1
  fi
  _ok "SHA256 del instalador en cache coincide con versions.env"
}

# ---------------------------------------------------------------------------
# Portables (modo repo y modo proyecto)
# ---------------------------------------------------------------------------

# Contraseñas de las semillas. Regla propia, NO la de build: ver
# seed_password_is_safe() en checks.sh.
check_app_passwords() {
  local env_file="$1"
  [[ -f "${env_file}" ]] || _skip "no existe .env; lo genera ./build.sh" || return 3

  local malas=() name value
  for name in APP_PASSWORD PDBADMIN_PASSWORD; do
    value="$(env_value "${name}" "${env_file}")"
    [[ -n "${value}" ]] || continue     # la ausencia la reporta check_seed_vars
    seed_password_is_safe "${value}" || malas+=("${name}")
  done

  if [[ ${#malas[@]} -gt 0 ]]; then
    _fail "Contrasenas con comillas, backslash o espacios: ${malas[*]}.
   Van dentro de un identificador entrecomillado del CREATE/ALTER USER, asi
   que lo parten en dos y la semilla falla al arrancar el contenedor." \
      "elegir otra en ${env_file}"
    return 1
  fi
  _ok "APP_PASSWORD y PDBADMIN_PASSWORD sin caracteres que rompan el DDL"
}

# Sin shm_size la SGA no entra en los 64 MB por defecto de /dev/shm y la base
# no arranca: ORA-00845.
check_compose_shm() {
  local compose="$1"
  [[ -f "${compose}" ]] || _skip "no existe compose.yml" || return 3

  local value
  value="$(sed -n 's/^[[:space:]]*shm_size:[[:space:]]*//p' "${compose}" | head -1)"

  if [[ -z "${value}" ]]; then
    _fail "compose.yml no declara shm_size. La SGA de Oracle vive en /dev/shm y
   con los 64 MB por defecto la base no arranca (ORA-00845)." \
      "agregar 'shm_size: 2gb' al servicio db"
    return 1
  fi

  local gb="${value%[gG][bB]}"
  if [[ "${gb}" =~ ^[0-9]+$ ]] && [[ ${gb} -lt 2 ]]; then
    _fail "shm_size: ${value} es insuficiente. Se necesitan al menos 2gb o la
   base falla con ORA-00845." "poner 'shm_size: 2gb'"
    return 1
  fi
  _ok "compose.yml declara shm_size: ${value}"
}

# Los puertos se publican en loopback a propósito: las credenciales de este
# entorno son públicas y APEX corre sin HTTPS.
check_bind_addr() {
  local env_file="$1"
  [[ -f "${env_file}" ]] || _skip "no existe .env; lo genera ./build.sh" || return 3

  local value
  value="$(env_value BIND_ADDR "${env_file}")"
  [[ -n "${value}" ]] || { _ok "BIND_ADDR sin definir: compose usa 127.0.0.1"; return 0; }

  if [[ "${value}" != "127.0.0.1" && "${value}" != "localhost" ]]; then
    _warn "BIND_ADDR=${value}: la base y el Builder quedan expuestos fuera de
   esta maquina. Las credenciales estan en el repo y APEX corre sin HTTPS, asi
   que cualquiera en la red llega como SYSTEM y como ADMIN. Si lo abriste para
   una demo, volvelo a loopback." \
      "sed -i 's/^BIND_ADDR=.*/BIND_ADDR=127.0.0.1/' ${env_file} && docker compose up -d"
    return 2
  fi
  _ok "los puertos se publican solo en ${value}"
}

# compose monta ./cache/apex en ORDS para servir los estáticos de /i/. La ruta
# es RELATIVA al directorio del compose: en un proyecto derivado que no tenga
# ese directorio, Docker lo crea vacio y APEX carga sin estilos.
check_ords_static_mount() {
  local dir="$1" mode="${2:-repo}"
  local cache="${dir}/cache"
  local probe="${cache}/apex/${ORDS_STATIC_PROBE}"
  local fix

  if [[ "${mode}" == "repo" ]]; then
    fix="./build.sh   # extrae el instalador en ./cache/apex"
    # En el repo, ./cache lo crea y lo llena ./build.sh. Que no exista significa
    # "todavia no construiste la imagen", no "esta roto": un clon recien hecho
    # tiene que dar 0, o el chequeo se vuelve ruido que se aprende a ignorar.
    [[ -e "${cache}" ]] || _skip "no hay ./cache todavia; lo genera ./build.sh" || return 3
  else
    fix="ln -s <ruta-a-apex-lab>/cache cache"
    # En un proyecto NO hay nada que lo genere: si falta, Docker va a crear el
    # directorio vacio en el primer `up` y montarlo igual. Ahi la ausencia SI
    # es el fallo, y detectarla antes de levantar es el punto del chequeo.
  fi

  if [[ ! -e "${probe}" ]]; then
    _fail "Falta ${probe}.
   compose monta ./cache/apex en ORDS para servir /i/; si el directorio no
   existe Docker lo crea VACIO y lo monta igual, y el Builder carga en texto
   plano, sin un solo error." "${fix}"
    return 1
  fi
  _ok "los estaticos de APEX estan en ${dir}/cache/apex"
}

# El entrypoint EJECUTA los .sh con +x y SOURCEA los que no lo tienen, y su
# rama de sourcing tiene un bug de upstream: le falta un ';', así que le pasa
# el echo siguiente como argumento al script.
check_init_exec_bit() {
  local init_dir="$1"
  [[ -d "${init_dir}" ]] || _skip "no existe init/; lo siembra ./build.sh" || return 3

  local sin_x=() f
  for f in "${init_dir}"/*.sh; do
    [[ -e "${f}" ]] || continue
    [[ -x "${f}" ]] || sin_x+=("$(basename "${f}")")
  done

  if [[ ${#sin_x[@]} -gt 0 ]]; then
    _fail "Semillas sin bit de ejecucion: ${sin_x[*]}.
   El entrypoint las SOURCEA en vez de ejecutarlas, y esa rama tiene un bug de
   upstream que les pasa el echo siguiente como argumento: el fallo es real
   pero ilegible." "chmod +x ${init_dir}/*.sh"
    return 1
  fi
  _ok "las semillas de init/ tienen bit de ejecucion"
}

# El entrypoint solo corre *.sh, *.sql, *.sql.zip y *.sql.gz. Cualquier otro
# nombre lo loguea como `ignoring` y sigue: una plantilla copiada con su
# sufijo .example queda INERTE y el proyecto arranca sin workspace ni ACL.
check_init_inert() {
  local init_dir="$1"
  [[ -d "${init_dir}" ]] || _skip "no existe init/; lo siembra ./build.sh" || return 3

  local inertes=() otros=() f base
  for f in "${init_dir}"/*; do
    [[ -f "${f}" ]] || continue
    base="$(basename "${f}")"
    case "${base}" in
      *.sh|*.sql|*.sql.zip|*.sql.gz) continue ;;   # el entrypoint los corre
      *.md|README*)                  continue ;;   # documentacion, inerte a proposito
      *.example)                     inertes+=("${base}") ;;
      *)                             otros+=("${base}") ;;
    esac
  done

  if [[ ${#inertes[@]} -gt 0 ]]; then
    _fail "Semillas INERTES en init/: ${inertes[*]}.
   Conservan el sufijo .example, y el entrypoint solo ejecuta *.sh, *.sql,
   *.sql.zip y *.sql.gz: las loguea como 'ignoring' y sigue. El proyecto
   arranca sin workspace, sin esquema y sin ACL, sin un solo error." \
      "cd ${init_dir} && for f in *.example; do mv \"\$f\" \"\${f%.example}\"; done"
    return 1
  fi
  if [[ ${#otros[@]} -gt 0 ]]; then
    _warn "Archivos que el entrypoint ignora en init/: ${otros[*]}.
   Solo corre *.sh, *.sql, *.sql.zip y *.sql.gz." ""
    return 2
  fi
  _ok "todas las semillas de init/ tienen una extension que el entrypoint corre"
}

# compose declara estas variables SIN valor por defecto a propósito: si falta
# una, es mejor que falle a que cree el esquema con una contraseña que no es la
# que creías.
check_seed_vars() {
  local env_file="$1"
  [[ -f "${env_file}" ]] || _skip "no existe .env; lo genera ./build.sh" || return 3

  local faltan=() name
  for name in "${SEED_VARS[@]}"; do
    [[ -n "$(env_value "${name}" "${env_file}")" ]] || faltan+=("${name}")
  done

  if [[ ${#faltan[@]} -gt 0 ]]; then
    _fail "Faltan variables de semilla en ${env_file}: ${faltan[*]}.
   compose se las pasa al contenedor sin valor por defecto, asi que los
   scripts de init/ fallan al arrancar." \
      "copiar el bloque 'Semillas de ./init' desde .env.example"
    return 1
  fi
  _ok "las ${#SEED_VARS[@]} variables de semilla estan definidas"
}

# initdb.d NO corre nunca con esta imagen: el entrypoint lo condiciona a que la
# base no exista, y el -faststart + docker commit la trae hecha dentro de la
# imagen. Las semillas van a startdb.d o no se ejecutan jamás.
check_seed_dir_mount() {
  local env_file="$1"
  [[ -f "${env_file}" ]] || _skip "no existe .env; lo genera ./build.sh" || return 3

  local value
  value="$(env_value DB_SEED_DIR "${env_file}")"
  [[ -n "${value}" ]] || { _ok "DB_SEED_DIR sin definir: compose usa startdb.d"; return 0; }

  if [[ "${value}" == *initdb.d* ]]; then
    _fail "DB_SEED_DIR=${value} apunta a initdb.d, que con esta imagen NO CORRE
   NUNCA: el entrypoint lo condiciona a que la base no exista y el -faststart
   la trae ya creada dentro de la imagen, incluso con el volumen recien creado.
   Las semillas quedarian sin ejecutarse en silencio." \
      "poner DB_SEED_DIR=/container-entrypoint-startdb.d en ${env_file}"
    return 1
  fi
  _ok "DB_SEED_DIR=${value} (corre en cada arranque)"
}
