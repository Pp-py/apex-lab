#!/usr/bin/env bash
#
# checks-runtime.sh — Chequeos contra el stack levantado: Docker, SQL y HTTP.
#
# Todos degradan a [SKIP] si el stack no está arriba. Un entorno apagado no es
# un entorno roto, y un [FAIL] por algo que ni siquiera se pudo mirar entrena
# a ignorar la herramienta.
#
# Mismo contrato que checks.sh. `runtime_checks` usa run_check(), que define
# doctor.sh: este archivo describe QUÉ se chequea, doctor.sh CÓMO se reporta.
#
# Se sourcea después de checks.sh. No ejecutar directamente.
#
# shellcheck shell=bash
# shellcheck disable=SC2034   # ver la nota de checks.sh: esto es una librería

[[ -n "${APEXLAB_CHECKS_RUNTIME_SH:-}" ]] && return 0
readonly APEXLAB_CHECKS_RUNTIME_SH=1

RT_PROJECT=""
RT_DB=""
RT_ORDS=""
RT_ORDS_URL=""
RT_MAILPIT_URL=""
RT_APP_SCHEMA=""
RT_PDB=""

_compose() { docker compose --project-directory "${SCRIPT_DIR}" "$@" 2>/dev/null; }

# SQL en la PDB como SYSDBA.
#
# El `timeout` va DENTRO del contenedor a propósito: uno en el host solo mata
# al cliente `docker exec` y deja el sqlplus corriendo a ciegas del otro lado.
#
# El SET SERVEROUTPUT no hace falta acá (no se usa DBMS_OUTPUT), pero si
# alguna vez se agrega, va DESPUES del ALTER SESSION SET CONTAINER: cambiar de
# contenedor descarta el buffer del lado del servidor y las lineas se pierden
# sin que `SHOW SERVEROUTPUT` deje de decir ON.
_sql() {
  docker exec -i "${RT_DB}" timeout 30 sqlplus -s -L / as sysdba <<SQL 2>/dev/null
WHENEVER SQLERROR EXIT FAILURE
SET HEADING OFF FEEDBACK OFF PAGESIZE 0 LINESIZE 300 ECHO OFF TRIMSPOOL ON
ALTER SESSION SET CONTAINER=${RT_PDB};
$1
SQL
}

# Devuelve la primera linea util de una consulta de un solo valor, o NADA si la
# consulta fallo.
#
# Distinguir las dos cosas no es opcional: con la base todavia arrancando, el
# ALTER SESSION falla y sqlplus imprime la sentencia junto al ORA-. Tomar a
# ciegas la primera linea devolvia 'ALTER SESSION SET CONTAINER=FREEPDB1' como
# si fuera el dato, y de ahi salian diagnosticos absurdos ("solo 4 de los 3
# usuarios existen"). Verificado rompiendo el entorno a proposito.
#
# Siempre sale con 0 y comunica el fallo por la salida vacia: los que llaman lo
# hacen dentro de $( ), y con `set -e` un rc!=0 ahi abortaria el doctor entero.
# El trim va con sed y no con xargs: xargs interpreta comillas y apostrofes.
_sql1() {
  local out rc=0
  out="$(_sql "$1")" || rc=$?
  [[ ${rc} -eq 0 ]] || return 0
  grep -qE '^(ORA-|SP2-|ERROR |Usage:)' <<< "${out}" && return 0

  printf '%s' "${out}" | tr -d '\r' | sed '/^[[:space:]]*$/d' | head -1 \
    | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

_http_code() { curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$1" 2>/dev/null || true; }

# ---------------------------------------------------------------------------
# Resolución del entorno. Devuelve 1 si no hay nada con que hablar.
# ---------------------------------------------------------------------------
runtime_resolve() {
  RT_PROJECT="$(env_value COMPOSE_PROJECT_NAME "${ENV_FILE}")"
  RT_PROJECT="${RT_PROJECT:-apexlab}"
  RT_DB="${RT_PROJECT}-db"
  # El contenedor de ORDS, no solo su URL: ahi vive el SQLcl que usan
  # `apex export` (README) y scripts/apex-roundtrip.sh. El doctor no lo
  # necesita, pero derivarlo dos veces seria la duplicacion de siempre.
  RT_ORDS="${RT_PROJECT}-ords"
  RT_APP_SCHEMA="$(env_value APP_SCHEMA "${ENV_FILE}")"
  RT_PDB="${DB_PDB:-FREEPDB1}"

  local ords_port mailpit_port
  ords_port="$(env_value ORDS_PORT "${ENV_FILE}")";       ords_port="${ords_port:-8080}"
  mailpit_port="$(env_value MAILPIT_PORT "${ENV_FILE}")"; mailpit_port="${mailpit_port:-8025}"
  # Siempre por loopback: es el lado del host, con independencia de BIND_ADDR.
  RT_ORDS_URL="http://127.0.0.1:${ords_port}"
  RT_MAILPIT_URL="http://127.0.0.1:${mailpit_port}"

  docker info >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Chequeos
# ---------------------------------------------------------------------------
check_containers_health() {
  local ps_out
  ps_out="$(_compose ps --format '{{.Service}} {{.State}} {{.Health}}' || true)"
  [[ -n "${ps_out}" ]] || _skip "el stack no esta levantado (docker compose up -d)" || return 3

  local faltan=() svc estado
  for svc in db ords mail; do
    estado="$(awk -v s="${svc}" '$1==s {print $2}' <<< "${ps_out}")"
    [[ "${estado}" == "running" ]] || faltan+=("${svc}=${estado:-ausente}")
  done

  if [[ ${#faltan[@]} -gt 0 ]]; then
    _fail "Servicios que no estan corriendo: ${faltan[*]}." \
      "docker compose up -d   # y despues: docker compose logs <servicio>"
    return 1
  fi

  local health
  health="$(awk '$1=="db" {print $3}' <<< "${ps_out}")"
  if [[ -n "${health}" && "${health}" != "healthy" ]]; then
    _warn "Los tres servicios corren, pero db esta '${health}'. La base puede
   seguir abriendo: el healthcheck tarda hasta un minuto tras el arranque." \
      "docker compose logs db"
    return 2
  fi
  _ok "db, ords y mail corriendo${health:+ (db ${health})}"
}

# Sin shm_size la SGA no entra en los 64 MB por defecto de /dev/shm.
check_db_shm_runtime() {
  local logs
  logs="$(_compose logs db 2>/dev/null | tail -300 || true)"
  [[ -n "${logs}" ]] || _skip "sin logs de db (el stack no esta levantado)" || return 3

  if grep -q 'ORA-00845' <<< "${logs}"; then
    _fail "ORA-00845 en los logs de db: /dev/shm es demasiado chico para la SGA." \
      "verificar 'shm_size: 2gb' en compose.yml y recrear: docker compose up -d --force-recreate db"
    return 1
  fi
  _ok "sin ORA-00845 en los logs de db"
}

check_apex_registry() {
  local out status invalidos
  out="$(_sql1 "SELECT NVL((SELECT status FROM dba_registry WHERE comp_id='APEX'),'AUSENTE')
                       || '|' ||
                       (SELECT COUNT(*) FROM dba_objects
                         WHERE status='INVALID' AND owner LIKE 'APEX%') FROM dual;")"
  [[ -n "${out}" && "${out}" == *"|"* ]] \
    || _skip "no se pudo consultar la base (stack apagado o aun arrancando)" || return 3

  status="${out%%|*}"; invalidos="${out##*|}"
  if [[ "${status}" != "VALID" ]]; then
    _fail "APEX quedo en estado '${status}', no VALID." "revisar el log del build; puede requerir rehornear la imagen"
    return 1
  fi
  if [[ "${invalidos}" != "0" ]]; then
    _fail "APEX esta VALID pero hay ${invalidos} objetos APEX% invalidos." \
      "docker exec -i ${RT_DB} sqlplus -s / as sysdba <<< 'ALTER SESSION SET CONTAINER=${RT_PDB};
@?/rdbms/admin/utlrp.sql'"
    return 1
  fi
  _ok "APEX VALID, 0 objetos invalidos"
}

check_apex_rest_users() {
  local out
  # NVL con centinela: LISTAGG sobre cero filas devuelve NULL, y una salida
  # vacia no se distingue de "la consulta no corrio". Sin esto, "faltan los
  # tres usuarios" se reportaria como [SKIP], que es justo el fallo mudo que
  # esta herramienta existe para evitar.
  out="$(_sql1 "SELECT NVL(LISTAGG(username || '=' || account_status, ' ')
                  WITHIN GROUP (ORDER BY username), 'NINGUNO')
                  FROM dba_users
                 WHERE username IN ('APEX_LISTENER','APEX_REST_PUBLIC_USER','APEX_PUBLIC_USER');")"
  [[ -n "${out}" ]] || _skip "no se pudo consultar la base" || return 3

  local malos=() par cuantos
  if [[ "${out}" == "NINGUNO" ]]; then
    cuantos=0
  else
    cuantos="$(wc -w <<< "${out}")"
    for par in ${out}; do
      [[ "${par}" == *"=OPEN" ]] || malos+=("${par}")
    done
  fi
  if [[ "${cuantos}" -ne 3 ]]; then
    _fail "Solo ${cuantos} de los 3 usuarios REST de APEX existen: ${out}.
   apex_rest_config.sql pide las claves por prompt; si cambio la cantidad de
   prompts, el build las desalinea en silencio." "rehornear la imagen: ./build.sh"
    return 1
  fi
  if [[ ${#malos[@]} -gt 0 ]]; then
    _fail "Usuarios REST de APEX que no estan OPEN: ${malos[*]}." \
      "ALTER USER <usuario> ACCOUNT UNLOCK;"
    return 1
  fi
  _ok "APEX_LISTENER, APEX_REST_PUBLIC_USER y APEX_PUBLIC_USER OPEN"
}

# ORA-28002: la contraseña expira meses despues y el entorno deja de abrir.
check_account_expiry() {
  local out lista
  # La lista se arma aparte: incrustarla con ${VAR:+...} dentro del SQL es
  # ilegible y shellcheck no puede decidir si las comillas son de shell o SQL.
  lista="'SYS','SYSTEM','APEX_PUBLIC_USER','APEX_LISTENER','APEX_REST_PUBLIC_USER','PDBADMIN'"
  [[ -z "${RT_APP_SCHEMA}" ]] || lista="${lista},'${RT_APP_SCHEMA^^}'"

  out="$(_sql1 "SELECT NVL(LISTAGG(username || '=' || account_status, ' ')
                  WITHIN GROUP (ORDER BY username), 'NINGUNA')
                  FROM dba_users
                 WHERE account_status LIKE '%EXPIRED%'
                   AND username IN (${lista});")"
  [[ -n "${out}" ]] || _skip "no se pudo consultar la base" || return 3

  if [[ "${out}" != "NINGUNA" ]]; then
    _fail "Cuentas con la contrasena expirada: ${out}.
   Se manifiesta como ORA-28002 al conectar. El build lo previene con
   PASSWORD_LIFE_TIME UNLIMITED, asi que esto indica un perfil distinto." \
      "ALTER USER <usuario> IDENTIFIED BY <clave>;"
    return 1
  fi
  _ok "ninguna cuenta del entorno con la contrasena expirada"
}

# Las ACLs del engine: sin ellas, una REST Data Source de APEX da ORA-24247.
# El esquema de APEX se resuelve en runtime desde dba_registry, nunca por regex
# sobre dba_users: tras un upgrade conviven varios APEX_*.
check_engine_acl() {
  local schema cuantos
  schema="$(_sql1 "SELECT schema FROM dba_registry WHERE comp_id='APEX';")"
  [[ -n "${schema}" ]] || _skip "no se pudo resolver el esquema de APEX" || return 3

  cuantos="$(_sql1 "SELECT COUNT(DISTINCT principal) FROM dba_host_aces
                     WHERE principal IN ('${schema}','APEX_REST_PUBLIC_USER');")"
  if [[ "${cuantos}" != "2" ]]; then
    _fail "Faltan ACLs de red del engine: solo ${cuantos:-0} de 2 principals
   (${schema} y APEX_REST_PUBLIC_USER) las tienen. Una REST Data Source de
   APEX fallara con ORA-24247." "rehornear la imagen, o reaplicar sql/20_network_acl.sql"
    return 1
  fi
  _ok "ACLs del engine otorgadas a ${schema} y APEX_REST_PUBLIC_USER"
}

# El build NO cubre el esquema de la aplicacion: no existe todavia en ese
# momento. Sin ACL, el PL/SQL propio falla con ORA-29273 (con un 24247 anidado
# que SQLERRM muchas veces no muestra).
check_app_acl() {
  [[ -n "${RT_APP_SCHEMA}" ]] || _skip "APP_SCHEMA no definido en .env" || return 3

  local existe cuantas
  existe="$(_sql1 "SELECT COUNT(*) FROM dba_users WHERE username='${RT_APP_SCHEMA^^}';")"
  [[ -n "${existe}" ]] || _skip "no se pudo consultar la base" || return 3
  [[ "${existe}" == "1" ]] \
    || _skip "el esquema ${RT_APP_SCHEMA^^} todavia no existe (lo crea init/01_workspace.sh)" || return 3

  cuantas="$(_sql1 "SELECT COUNT(*) FROM dba_host_aces WHERE principal='${RT_APP_SCHEMA^^}';")"
  if [[ "${cuantas}" == "0" ]]; then
    _fail "El esquema ${RT_APP_SCHEMA^^} no tiene ACL de red. Cualquier llamada
   saliente desde su PL/SQL (APEX_WEB_SERVICE, UTL_HTTP, UTL_SMTP) va a fallar
   con ORA-29273, que trae un ORA-24247 anidado que SQLERRM suele ocultar." \
      "activar la semilla: cp init.example/02_acl_app.sh.example init/02_acl_app.sh && docker compose restart db"
    return 1
  fi
  _ok "el esquema ${RT_APP_SCHEMA^^} tiene ACL de red (${cuantas} ACE)"
}

check_builder_http() {
  local code; code="$(_http_code "${RT_ORDS_URL}/ords/apex")"
  case "${code}" in
    000) _skip "ORDS no responde en ${RT_ORDS_URL} (stack apagado o aun arrancando)"; return 3 ;;
    200|302) _ok "el Builder responde ${code} en ${RT_ORDS_URL}/ords/apex" ;;
    *)   _fail "El Builder devolvio HTTP ${code} en ${RT_ORDS_URL}/ords/apex." \
           "docker compose logs ords"; return 1 ;;
  esac
}

# El sintoma clasico es "APEX carga sin estilos, todo texto plano": ORDS sirve
# el HTML pero no los estaticos, porque el montaje de ./cache/apex esta vacio.
check_ords_statics_http() {
  local url="${RT_ORDS_URL}/i/apex_ui/css/Core.min.css" out code ctype
  out="$(curl -s -o /dev/null -w '%{http_code} %{content_type}' --max-time 10 "${url}" 2>/dev/null || true)"
  code="${out%% *}"; ctype="${out#* }"

  case "${code}" in
    000) _skip "ORDS no responde (stack apagado)"; return 3 ;;
    200) ;;
    *)   _fail "Los estaticos de APEX dan HTTP ${code} en ${url}.
   El Builder va a cargar en texto plano: el montaje de ./cache/apex en ORDS
   esta vacio o no existe." \
           "verificar ./cache/apex y recrear ords: docker compose up -d --force-recreate ords"
         return 1 ;;
  esac

  if [[ "${ctype}" != text/css* ]]; then
    _warn "Los estaticos responden 200 pero con content-type '${ctype}' en vez
   de text/css. El navegador puede descartar la hoja de estilos." ""
    return 2
  fi
  _ok "los estaticos de APEX responden 200 ${ctype}"
}

check_mailpit_http() {
  local code; code="$(_http_code "${RT_MAILPIT_URL}")"
  case "${code}" in
    000) _skip "Mailpit no responde en ${RT_MAILPIT_URL} (stack apagado)"; return 3 ;;
    200) _ok "Mailpit responde en ${RT_MAILPIT_URL}" ;;
    *)   _fail "Mailpit devolvio HTTP ${code}. El correo saliente de APEX no se
   va a poder inspeccionar." "docker compose logs mail"; return 1 ;;
  esac
}

# Bug #8 del repo: durante meses los init no se ejecutaron nunca y nadie lo
# noto, porque su ausencia no produce ningun error.
#
# La fuente NO son las lineas que imprime cada semilla —una semilla propia
# puede no loguear nada—, sino el entrypoint, que anuncia cada archivo del
# directorio de semillas como `running <ruta>` o `ignoring <ruta>`. Ese
# `ignoring` es la confesion directa del bug B: el archivo esta ahi y no se
# ejecuta por su extension.
check_init_ran() {
  local init_dir="${SCRIPT_DIR}/init" logs slice seed
  [[ -d "${init_dir}" ]] || _skip "no existe init/" || return 3

  logs="$(_compose logs db 2>/dev/null || true)"
  [[ -n "${logs}" ]] || _skip "sin logs de db (el stack no esta levantado)" || return 3

  seed="$(env_value DB_SEED_DIR "${ENV_FILE}")"
  seed="${seed:-/container-entrypoint-startdb.d}"

  # Solo el ULTIMO arranque. El log acumula todos, y una marca de tres
  # arranques atras diria que la semilla corrio cuando hoy ya no corre: un
  # falso OK en el unico chequeo que existe para que el bug #8 no vuelva.
  slice="$(awk '/CONTAINER: starting up Oracle Database/ {buf=""}
                {buf = buf $0 "\n"}
                END {printf "%s", buf}' <<< "${logs}")"
  [[ -n "${slice}" ]] || slice="${logs}"

  # El entrypoint corre las semillas DESPUES de abrir la base, y `restart`
  # devuelve antes de que termine. Sin esperar su marca de cierre, un doctor
  # lanzado enseguida reporta como "no corrio" algo que simplemente todavia no
  # corrio: un FAIL falso, que es lo que entrena a ignorar la herramienta.
  if ! grep -qF 'DONE: Executing user-defined scripts' <<< "${slice}"; then
    _skip "el arranque todavia no termino de ejecutar las semillas" || return 3
  fi

  local sin_correr=() ignorados=() f base
  for f in "${init_dir}"/*; do
    [[ -f "${f}" ]] || continue
    base="$(basename "${f}")"
    case "${base}" in *.md|README*) continue ;; esac

    if grep -qF "ignoring ${seed}/${base}" <<< "${slice}"; then
      ignorados+=("${base}")
    elif ! grep -qF "running ${seed}/${base}" <<< "${slice}"; then
      sin_correr+=("${base}")
    fi
  done

  if [[ ${#ignorados[@]} -gt 0 ]]; then
    _fail "El entrypoint IGNORO estas semillas en el ultimo arranque: ${ignorados[*]}.
   Solo ejecuta *.sh, *.sql, *.sql.zip y *.sql.gz; el resto lo loguea como
   'ignoring' y sigue. El workspace, el esquema o la ACL simplemente no
   existen, sin un solo error." \
      "renombrar sin el sufijo, y despues: docker compose restart db"
    return 1
  fi
  if [[ ${#sin_correr[@]} -gt 0 ]]; then
    _fail "Semillas que no corrieron en el ultimo arranque: ${sin_correr[*]}.
   Estan en init/ y el entrypoint no las anuncio siquiera. Revisa que ./init
   este montado en ${seed} y no en initdb.d, que con esta imagen no corre nunca." \
      "docker compose logs db | grep CONTAINER:"
    return 1
  fi
  _ok "el entrypoint ejecuto todas las semillas de init/ en el ultimo arranque"
}

# Subir la version de la base conservando el volumen deja binarios nuevos sobre
# datafiles viejos: la base abre, pero sin el datapatch que le corresponde. El
# diccionario (dba_registry) se queda atras respecto del binario (v$instance).
check_datapatch_pending() {
  local out binario diccionario
  out="$(_sql1 "SELECT (SELECT version_full FROM v\$instance) || '|' ||
                       (SELECT version_full FROM dba_registry WHERE comp_id='CATPROC')
                  FROM dual;")"
  [[ -n "${out}" && "${out}" == *"|"* ]] \
    || _skip "no se pudo comparar binario y diccionario" || return 3

  binario="${out%%|*}"; diccionario="${out##*|}"
  if [[ -z "${binario}" || -z "${diccionario}" ]]; then
    _skip "la base no reporto ambas versiones" || return 3
  fi
  if [[ "${binario}" != "${diccionario}" ]]; then
    _warn "El binario esta en ${binario} y el diccionario en ${diccionario}.
   Tipico de haber subido la version de la base conservando el volumen: el
   faststart solo copia los datafiles cuando el volumen esta vacio, asi que
   quedaron los viejos bajo binarios nuevos, sin datapatch. La base abre igual,
   que es lo que lo hace dificil de notar." \
      "docker compose down -v && docker compose up -d   # DESTRUYE la base"
    return 2
  fi
  _ok "binario y diccionario en ${binario}"
}

# ---------------------------------------------------------------------------
# Orquestacion. run_check() la define doctor.sh.
# ---------------------------------------------------------------------------
runtime_checks() {
  if ! runtime_resolve; then
    run_check docker-daemon check_docker_daemon
    return 0
  fi
  run_check containers-health  check_containers_health
  run_check db-shm-runtime     check_db_shm_runtime
  run_check apex-registry      check_apex_registry
  run_check apex-rest-users    check_apex_rest_users
  run_check account-expiry     check_account_expiry
  run_check engine-acl         check_engine_acl
  run_check app-acl            check_app_acl
  run_check init-ran           check_init_ran
  run_check datapatch-pending  check_datapatch_pending
  run_check builder-http       check_builder_http
  run_check ords-statics-http  check_ords_statics_http
  run_check mailpit-http       check_mailpit_http
}
