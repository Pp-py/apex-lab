#!/usr/bin/env bash
#
# roundtrip.sh — Etapas del round-trip de APEXlang y, sobre todo, sus parsers.
#
#   fuente .apx -> apex validate -> apex import -> app corriendo -> smoke test
#
# Todo el trabajo lo hace el SQLcl que ya viene DENTRO del contenedor de ORDS
# (`/usr/bin/sql`). Acá no hay una capa nueva: hay un wrapper que sabe leer lo
# que ese SQLcl contesta.
#
# ---------------------------------------------------------------------------
# LO ÚNICO QUE HAY QUE ENTENDER DE ESTE ARCHIVO
#
# Toda la cadena de Oracle que este script usa devuelve ÉXITO cuando falla.
# Medido contra ords:26.1.2, no deducido:
#
#   apex validate  con errores de sintaxis        -> rc=0
#   apex validate  con el directorio inexistente  -> rc=0
#   apex validate  con una opción mal escrita     -> rc=0
#   apex import    a un workspace inexistente     -> rc=0
#   apex import    sin poder conectar (ORA-01017) -> rc=0
#   la app con la página de inicio faltante       -> HTTP 200 "Sorry, this
#                                                    page isn't available"
#
# Ni `whenever sqlerror exit failure` ni `-exitwhendone` cambian nada: el
# primero no aplica a los comandos de SQLcl y el segundo directamente no es
# una opción de `validate`.
#
# Consecuencia de diseño, y es la razón de ser de este archivo: **allowlist
# positiva**. Solo la línea de éxito literal cuenta como éxito; todo lo demás
# —incluida la salida vacía— es fallo. Un grep de errores conocidos (denylist)
# daría PASS con cualquier fallo que todavía no esté en la lista, empezando
# por un comando mal escrito por nosotros.
#
# Es la misma lección que `_sql1()` de checks-runtime.sh ya había aprendido
# con sqlplus. Por eso los parsers están separados de los ejecutores: reciben
# un ARCHIVO de texto y no tocan Docker, así scripts/test-roundtrip.sh los
# alimenta con las salidas reales capturadas arriba. Un parser que devuelve
# PASS porque su grep está mal escrito es peor que no tener parser.
# ---------------------------------------------------------------------------
#
# Se sourcea después de checks.sh y checks-runtime.sh. No ejecutar directamente.
#
# shellcheck shell=bash
# shellcheck disable=SC2034   # es una librería: ver la nota de checks.sh

[[ -n "${APEXLAB_ROUNDTRIP_SH:-}" ]] && return 0
readonly APEXLAB_ROUNDTRIP_SH=1

# ---------------------------------------------------------------------------
# Constantes
# ---------------------------------------------------------------------------

# ID e identidad de la app de prueba. El alias es el MARCADOR DE PROPIEDAD:
# antes de importar, el script comprueba que el ID destino esté libre o lo
# ocupe una app con este alias. Sin eso, `apex import` sobrescribe en silencio
# la app que haya ahí —lo dice apps.example/README.md— y este script sería la
# forma más rápida de perder el trabajo de una tarde.
readonly RT_APP_ID_DEFAULT=9000
readonly RT_ALIAS='APEXLAB-ROUNDTRIP'
readonly RT_APP_NAME='apex-lab roundtrip'

# Las líneas de éxito. Literales, exactas, y lo único que se acepta.
readonly RT_MARK_VALIDATE='Validation successful.'
readonly RT_MARK_IMPORT='Import successful.'

# El timeout va DENTRO del contenedor: uno en el host sobre `docker exec` mata
# al cliente y deja el SQLcl corriendo del otro lado (trampa de CLAUDE.md).
readonly RT_SQLCL_TIMEOUT=300

# Dentro del contenedor de ORDS la base se llama `db`, el nombre del servicio
# de compose, no localhost.
readonly RT_JDBC='db:1521/FREEPDB1'

# Directorio de trabajo DENTRO del contenedor de ORDS.
readonly RT_WORKDIR='/tmp/apexlab-roundtrip'

# ---------------------------------------------------------------------------
# Parsers: reciben un archivo, no ejecutan nada. Esta es la parte testeable.
# ---------------------------------------------------------------------------

# Contenido del log normalizado: sin CR y sin sangría por línea, que es lo que
# permite comparar el marcador con -x (línea completa) en vez de por substring.
# Con substring, un hipotético "Validation successful: 3 of 4" pasaría.
_rt_text() {
  local f="$1"
  [[ -f "${f}" ]] || return 1
  tr -d '\r' < "${f}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

# Primeras N líneas con contenido, sangradas para el reporte.
_rt_excerpt() {
  local text="$1" n="${2:-10}"
  printf '%s\n' "${text}" | sed '/^$/d' | head -n "${n}" | sed 's/^/       /'
}

# Traduce la salida de un comando `apex` fallido a una causa en castellano.
# Compartido por validate e import: las dos comparten casi todas las ramas, y
# duplicarlas sería garantizar que se separen.
#
# NO decide si hubo fallo —eso lo hace la allowlist de cada parser—, solo
# explica el que ya se detectó.
_rt_diagnose() {
  local text="$1"
  if   grep -q 'Could not find file or directory with inputPath' <<< "${text}"; then
    printf 'SQLcl no encontró la ruta DENTRO del contenedor de ORDS. El árbol se copia con docker cp: si ese paso falló, esto es lo que se ve.'
  elif grep -q 'Option not recognized' <<< "${text}"; then
    printf 'SQLcl rechazó una opción del comando. Es un bug de este script, no de tu app: la versión de SQLcl instalada no acepta lo que le mandamos.'
  elif grep -q 'from workspace input is invalid' <<< "${text}"; then
    printf 'El workspace no existe en esta base. Sale de APP_WORKSPACE en tu .env, y las semillas de init/ son las que lo crean.'
  elif grep -q '^Connection failed' <<< "${text}"; then
    printf 'SQLcl no pudo conectar a la base. Revisá APP_SCHEMA y APP_PASSWORD en el .env: compose se los pasa al contenedor de ORDS.'
  elif grep -q 'APEXLang Compile Errors' <<< "${text}"; then
    printf 'El código APEXlang no compila. Los errores traen archivo, línea y columna.'
  else
    printf 'SQLcl no confirmó la operación y la salida no coincide con ningún fallo conocido. Puede ser una versión nueva con otro formato.'
  fi
}

# rt_parse_validate <log>
rt_parse_validate() {
  local log="$1" text
  if ! text="$(_rt_text "${log}")" || [[ -z "${text}" ]]; then
    _fail "apex validate no dejó ni una línea de salida.
   SQLcl ni siquiera llegó a correr dentro del contenedor de ORDS." \
      "docker compose logs ords"
    return 1
  fi

  if grep -qxF "${RT_MARK_VALIDATE}" <<< "${text}"; then
    _ok "APEXlang compila (${RT_MARK_VALIDATE})"
    return 0
  fi

  _fail "apex validate no dijo '${RT_MARK_VALIDATE}'.
   $(_rt_diagnose "${text}")

$(_rt_excerpt "${text}" 12)" \
    "corregí el origen y volvé a correr; el log completo queda en validate.log"
  return 1
}

# rt_parse_import <log>
rt_parse_import() {
  local log="$1" text
  if ! text="$(_rt_text "${log}")" || [[ -z "${text}" ]]; then
    _fail "apex import no dejó ni una línea de salida.
   SQLcl ni siquiera llegó a correr dentro del contenedor de ORDS." \
      "docker compose logs ords"
    return 1
  fi

  if grep -qxF "${RT_MARK_IMPORT}" <<< "${text}"; then
    _ok "importada ($(grep -m1 '^Importing application' <<< "${text}" || printf '%s' "${RT_MARK_IMPORT}"))"
    return 0
  fi

  _fail "apex import no dijo '${RT_MARK_IMPORT}'.
   $(_rt_diagnose "${text}")

$(_rt_excerpt "${text}" 12)" \
    "el log completo queda en import.log"
  return 1
}

# ---------------------------------------------------------------------------
# Inventario del origen, en el host. También sin Docker: lo usa el self-test.
# ---------------------------------------------------------------------------

# Cuenta las páginas del árbol APEXlang. Una por archivo pages/p*.apx.
rt_source_pages() {
  local src="$1"
  [[ -d "${src}/pages" ]] || { printf '0'; return 0; }
  find "${src}/pages" -maxdepth 1 -type f -name 'p*.apx' | wc -l | tr -d ' '
}

# Nombres de los static files, relativos y ordenados: es como los guarda APEX
# en apex_application_static_files.file_name, así que las dos listas se
# comparan directo.
rt_source_statics() {
  local src="$1" base="$1/shared-components/static-files" f
  [[ -d "${base}" ]] || return 0
  while IFS= read -r f; do
    printf '%s\n' "${f#"${base}/"}"
  done < <(find "${base}" -type f | LC_ALL=C sort)
}

# ---------------------------------------------------------------------------
# Ejecutores: acá sí hay Docker. Escriben el log y devuelven su ruta.
# ---------------------------------------------------------------------------

# SQLcl sin conexión: alcanza para `generate` y `validate`, que no tocan la
# base. Verificado: los dos funcionan con /nolog.
rt_sqlcl_nolog() {
  docker exec -i "${RT_ORDS}" bash -c \
    'printf "%s\nexit\n" "$1" | timeout '"${RT_SQLCL_TIMEOUT}"' sql -s /nolog' \
    _ "$1" 2>&1
}

# SQLcl conectado como el esquema de la app.
#
# La contraseña NO viaja por el argumento: se arma dentro del contenedor a
# partir de APP_SCHEMA/APP_PASSWORD, que compose ya le pasa al servicio ords
# (por eso están en compose.yml; ver apps.example/README.md). Así no aparece
# en la línea de comandos del host ni en un `ps`.
rt_sqlcl_conn() {
  docker exec -i "${RT_ORDS}" bash -c \
    'printf "%s\nexit\n" "$1" | timeout '"${RT_SQLCL_TIMEOUT}"' sql -s "$APP_SCHEMA/$APP_PASSWORD@'"${RT_JDBC}"'"' \
    _ "$1" 2>&1
}

# Genera la app de referencia dentro del contenedor y devuelve su ruta.
#
# Se usa `apex generate` y no un fixture versionado a propósito: es el
# generador oficial de Oracle, así que el árbol siempre coincide con el
# mmdVersion del SQLcl instalado. Un .apx a mano en el repo se desactualiza en
# el próximo upgrade de APEX y empieza a fallar por algo que no es el bug que
# el test busca.
rt_run_generate() {
  local workspace="$1" schema="$2" app_id="$3" dest="$4" log="$5"
  rt_sqlcl_nolog "apex generate -dir ${dest} -alias ${RT_ALIAS} -id ${app_id} -name \"${RT_APP_NAME}\" -schema ${schema} -workspace ${workspace}" \
    > "${log}" 2>&1 || true
  # `apex generate` tambien sale con 0 cuando no genera nada: la unica senal
  # es esta linea. Igual que todo lo demas en esta cadena.
  grep -q 'Files created at' "${log}"
}

rt_run_validate() {
  local remote_src="$1" workspace="$2" log="$3"
  rt_sqlcl_nolog "apex validate -input ${remote_src} -workspace ${workspace}" \
    > "${log}" 2>&1 || true
}

rt_run_import() {
  local remote_src="$1" workspace="$2" schema="$3" app_id="$4" log="$5"
  rt_sqlcl_conn "apex import -input ${remote_src} -workspace ${workspace} -schema ${schema} -id ${app_id} -alias ${RT_ALIAS}" \
    > "${log}" 2>&1 || true
}

# ---------------------------------------------------------------------------
# Consultas al diccionario. Todo el SQL de acá es 100 % ASCII, igual que el de
# sql/: corre dentro del contenedor con el NLS_LANG que herede.
# ---------------------------------------------------------------------------

# Varias filas, o nada si la consulta falló. Mismo criterio que _sql1: nunca
# devuelve rc!=0, para no abortar por `set -e` en un $( ).
_rt_sql_lines() {
  local out rc=0
  out="$(_sql "$1")" || rc=$?
  [[ ${rc} -eq 0 ]] || return 0
  grep -qE '^(ORA-|SP2-|ERROR |Usage:)' <<< "${out}" && return 0
  printf '%s' "${out}" | tr -d '\r' | sed -e '/^[[:space:]]*$/d' \
    -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

# Alias de la app que ocupa un ID, o vacío si el ID está libre.
#
# El sentinel no es decorativo: sin él, "el ID está libre" y "la consulta se
# rompió" son la misma salida vacía, y la guarda de propiedad se saltearía
# justo cuando no puede verificar nada. Misma trampa que el LISTAGG sobre cero
# filas de checks-runtime.sh.
rt_app_alias() {
  local app_id="$1"
  _sql1 "SELECT NVL(MAX(alias), 'LIBRE') FROM apex_applications WHERE application_id = ${app_id};"
}

# ---------------------------------------------------------------------------
# Prerequisitos propios
#
# El round-trip necesita db y ords, y NADA más. Usar acá el
# check_containers_health del doctor —que exige los tres servicios— haría que
# tener Mailpit parado bloqueara un test que no le manda un solo correo: un
# falso bloqueo, que es la forma más rápida de que una herramienta se empiece
# a ignorar. El chequeo se comparte; la política es de cada consumidor.
# ---------------------------------------------------------------------------
rt_require_services() {
  local ps_out svc estado faltan=()
  ps_out="$(_compose ps --format '{{.Service}} {{.State}} {{.Health}}' || true)"
  [[ -n "${ps_out}" ]] || {
    _fail "El stack no esta levantado. Este script no lo levanta: el primer
   arranque de un proyecto copia ~4,5 GB al volumen y esa no es una espera que
   deba decidir un test." "docker compose up -d"
    return 1; }

  for svc in db ords; do
    estado="$(awk -v s="${svc}" '$1==s {print $2}' <<< "${ps_out}")"
    [[ "${estado}" == "running" ]] || faltan+=("${svc}=${estado:-ausente}")
  done
  if [[ ${#faltan[@]} -gt 0 ]]; then
    _fail "El round-trip necesita db y ords corriendo: ${faltan[*]}." \
      "docker compose up -d db ords"
    return 1
  fi

  local health
  health="$(awk '$1=="db" {print $3}' <<< "${ps_out}")"
  if [[ -n "${health}" && "${health}" != "healthy" ]]; then
    _fail "db corre pero esta '${health}'. El import fallaria a medias, que es
   peor que no empezar: el healthcheck tarda hasta un minuto tras el arranque." \
      "docker compose ps db   # esperar a healthy"
    return 1
  fi
  _ok "db y ords corriendo (db ${health:-sin healthcheck})"
}

# ---------------------------------------------------------------------------
# Chequeos de runtime: comparan el ARTEFACTO contra lo que quedó en la base.
#
# Es lo que separa un round-trip de un "importó sin gritar". `apex import`
# dice "Import successful." aunque la app termine incompleta: medido, una app
# a la que le falta la página de inicio importa igual y sin una sola queja.
# ---------------------------------------------------------------------------

rt_check_app_row() {
  local app_id="$1" workspace="$2" schema="$3" row
  row="$(_sql1 "SELECT NVL(MAX(alias||'|'||workspace||'|'||owner||'|'||application_name), 'NINGUNA')
                  FROM apex_applications WHERE application_id = ${app_id};")"

  [[ -n "${row}" ]] || { _skip "no se pudo consultar apex_applications"; return 3; }
  if [[ "${row}" == "NINGUNA" ]]; then
    _fail "La app ${app_id} no existe en apex_applications despues del import.
   SQLcl reporto exito pero no quedo nada." "revisar import.log"
    return 1
  fi

  local alias="${row%%|*}" resto="${row#*|}"
  local ws="${resto%%|*}"; resto="${resto#*|}"
  local owner="${resto%%|*}" nombre="${resto#*|}"

  local mal=()
  [[ "${alias}" == "${RT_ALIAS}" ]]   || mal+=("alias=${alias} (esperado ${RT_ALIAS})")
  [[ "${ws}"    == "${workspace}" ]]  || mal+=("workspace=${ws} (esperado ${workspace})")
  [[ "${owner}" == "${schema}" ]]     || mal+=("parsing schema=${owner} (esperado ${schema})")

  if [[ ${#mal[@]} -gt 0 ]]; then
    _fail "La app ${app_id} quedo importada con metadatos distintos de los pedidos:
$(printf '       %s\n' "${mal[@]}")" ""
    return 1
  fi
  _ok "app ${app_id} '${nombre}' en ${ws}, parseando como ${owner}"
}

# Fidelidad de páginas: un archivo pages/p*.apx por fila de
# apex_application_pages. Si el import se comió una página, acá se ve.
rt_check_pages_fidelity() {
  local app_id="$1" src="$2" n_src n_db
  n_src="$(rt_source_pages "${src}")"
  n_db="$(_sql1 "SELECT COUNT(*) FROM apex_application_pages WHERE application_id = ${app_id};")"

  [[ -n "${n_db}" ]] || { _skip "no se pudo consultar apex_application_pages"; return 3; }
  if [[ "${n_src}" != "${n_db}" ]]; then
    _fail "El origen trae ${n_src} pagina(s) y la base quedo con ${n_db}.
   El import dijo que salio bien igual: por eso este chequeo existe." \
      "diff entre pages/*.apx y apex_application_pages"
    return 1
  fi
  _ok "${n_db} pagina(s), igual que el origen"
}

# Fidelidad de static files. Es la que más suele romperse al mover una app:
# son binarios, y compara los NOMBRES, no solo cuántos hay.
rt_check_static_fidelity() {
  local app_id="$1" src="$2" n_src n_db lista_src lista_db
  lista_src="$(rt_source_statics "${src}")"
  n_src="$(printf '%s' "${lista_src}" | grep -c . || true)"
  n_db="$(_sql1 "SELECT COUNT(*) FROM apex_application_static_files WHERE application_id = ${app_id};")"

  [[ -n "${n_db}" ]] || { _skip "no se pudo consultar apex_application_static_files"; return 3; }

  if [[ "${n_src}" -eq 0 && "${n_db}" -eq 0 ]]; then
    _ok "la app no trae static files"
    return 0
  fi
  if [[ "${n_src}" != "${n_db}" ]]; then
    _fail "El origen trae ${n_src} static file(s) y la base quedo con ${n_db}." \
      "revisar shared-components/static-files/ contra apex_application_static_files"
    return 1
  fi

  # Con las cantidades ya iguales y > 0, la consulta no puede devolver cero
  # filas: una salida vacía acá es un fallo de la consulta, no una app vacía.
  lista_db="$(_rt_sql_lines "SELECT file_name FROM apex_application_static_files
                               WHERE application_id = ${app_id} ORDER BY file_name;")"
  [[ -n "${lista_db}" ]] || { _skip "no se pudieron listar los static files"; return 3; }

  local dif
  dif="$(LC_ALL=C diff <(printf '%s\n' "${lista_src}") <(printf '%s\n' "${lista_db}") || true)"
  if [[ -n "${dif}" ]]; then
    _fail "Los static files coinciden en cantidad (${n_db}) pero no en nombre:
$(printf '%s\n' "${dif}" | head -10 | sed 's/^/       /')" ""
    return 1
  fi
  _ok "${n_db} static file(s), mismos nombres que el origen"
}

# Los supporting objects del import pueden dejar PL/SQL sin compilar.
rt_check_schema_objects() {
  local schema="$1" n
  n="$(_sql1 "SELECT COUNT(*) FROM dba_objects WHERE owner = UPPER('${schema}') AND status <> 'VALID';")"
  [[ -n "${n}" ]] || { _skip "no se pudo consultar dba_objects"; return 3; }
  if [[ "${n}" -gt 0 ]]; then
    _warn "El esquema ${schema} tiene ${n} objeto(s) invalido(s) despues del import.
   Puede venir de los supporting objects de la app." \
      "ALTER ... COMPILE, o revisar dba_errors para ver el detalle"
    return 2
  fi
  _ok "0 objetos invalidos en ${schema}"
}

# ---------------------------------------------------------------------------
# Smoke test
#
# Determinista y sin login: verifica que la app SE SIRVE, no que un usuario
# pueda operarla —eso necesitaría credenciales de workspace y dejaría de ser
# determinista—.
#
# El código HTTP NO alcanza. Medido: una app a la que le falta la página de
# inicio devuelve **200** con "Sorry, this page isn't available". El único
# discriminante fiable es que el HTML traiga el nombre de la app, que sale del
# propio .apx importado.
# ---------------------------------------------------------------------------

# rt_smoke_app <app_id> <nombre-de-la-app> <archivo-de-salida>
rt_smoke_app() {
  local app_id="$1" nombre="$2" out="$3"
  local url="${RT_ORDS_URL}/ords/f?p=${app_id}:1" jar meta code ctype

  # APEX negocia la sesión con una cookie y, sin frasco donde guardarla, curl
  # rebota entre /home y /login indefinidamente. Con cookie jar resuelve en un
  # solo redirect. Verificado.
  jar="$(mktemp)"
  meta="$(curl -sL --max-time 30 -c "${jar}" -b "${jar}" -o "${out}" \
            -w '%{http_code} %{content_type}' "${url}" 2>/dev/null || true)"
  rm -f "${jar}"
  code="${meta%% *}"; ctype="${meta#* }"

  if [[ "${code}" == "000" || -z "${code}" ]]; then
    _fail "La app no responde en ${url}. ORDS no esta atendiendo." \
      "docker compose ps ords && docker compose logs ords"
    return 1
  fi
  if [[ "${code}" != "200" ]]; then
    _fail "La app devolvio HTTP ${code} en ${url}." "docker compose logs ords"
    return 1
  fi
  if [[ "${ctype}" != text/html* ]]; then
    _fail "La app respondio 200 pero con content-type '${ctype}', no text/html." ""
    return 1
  fi
  if ! grep -qF "${nombre}" "${out}"; then
    _fail "La app respondio 200 text/html pero la pagina NO trae su propio nombre
   ('${nombre}'). Es lo que devuelve APEX cuando la app quedo incompleta:
   200 con 'Sorry, this page isn't available'. El codigo HTTP miente." \
      "abrir ${url} en el navegador"
    return 1
  fi
  _ok "${url} -> 200 text/html con el nombre de la app ($(wc -c < "${out}" | tr -d ' ') bytes)"
}

# rt_smoke_static <app_id> <workspace> <alias>
#
# Pide UN static file de la app. Es lo que prueba que los binarios
# sobrevivieron el round-trip, que es justo lo que un f100.sql suele romper.
rt_smoke_static() {
  local app_id="$1" workspace="$2" alias="$3" archivo meta code ctype url
  archivo="$(_sql1 "SELECT NVL(MIN(file_name), 'NINGUNO')
                      FROM apex_application_static_files WHERE application_id = ${app_id};")"

  [[ -n "${archivo}" ]] || { _skip "no se pudo consultar apex_application_static_files"; return 3; }
  [[ "${archivo}" != "NINGUNO" ]] || { _skip "la app no trae static files que probar"; return 3; }

  # Ruta pública de los static files de aplicación en ORDS. El workspace y el
  # alias van en minúscula, como los publica APEX.
  url="${RT_ORDS_URL}/ords/r/${workspace,,}/${alias,,}/files/static/v0/${archivo}"
  meta="$(curl -s -o /dev/null -w '%{http_code} %{content_type}' --max-time 15 "${url}" 2>/dev/null || true)"
  code="${meta%% *}"; ctype="${meta#* }"

  if [[ "${code}" != "200" ]]; then
    _fail "El static file '${archivo}' da HTTP ${code}.
   Esta en la base pero ORDS no lo sirve: la app se veria sin sus imagenes
   ni su JavaScript." "${url}"
    return 1
  fi
  _ok "${archivo} -> 200 ${ctype}"
}
