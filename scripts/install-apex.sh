#!/usr/bin/env bash
#
# install-apex.sh — Se ejecuta DENTRO del contenedor de build, como usuario
# `oracle`. Instala APEX en la PDB FREEPDB1 y la deja configurada para ORDS.
#
# Variables esperadas (las inyecta build.sh vía `docker exec -e`):
#   APEX_ADMIN_PASSWORD, APEX_ADMIN_EMAIL, APEX_PUBLIC_USER_PASSWORD
#
set -Eeuo pipefail

readonly PDB="${DB_PDB:-FREEPDB1}"
readonly APEX_HOME="/tmp/apex"
readonly SQL_DIR="/tmp/sql"

log() { printf '\n>>> %s\n' "$*"; }

: "${APEX_ADMIN_PASSWORD:?falta APEX_ADMIN_PASSWORD}"
: "${APEX_ADMIN_EMAIL:?falta APEX_ADMIN_EMAIL}"
: "${APEX_PUBLIC_USER_PASSWORD:?falta APEX_PUBLIC_USER_PASSWORD}"

# SQL*Plus devuelve 0 aunque haya errores, salvo que se lo pida explícitamente.
# WHENEVER SQLERROR/OSERROR EXIT FAILURE va en cada bloque para que el fallo
# se propague al script y aborte el build en vez de generar una imagen rota.
readonly SQLPLUS_HEADER='WHENEVER SQLERROR EXIT FAILURE
WHENEVER OSERROR EXIT FAILURE
SET DEFINE OFF
SET ECHO ON'

# Entrar a la PDB y RECIEN AHI activar SERVEROUTPUT. El orden importa y no es
# obvio: `ALTER SESSION SET CONTAINER` descarta el buffer de DBMS_OUTPUT del
# lado del servidor, asi que un SERVEROUTPUT activado antes queda inservible.
# Lo traicionero es que `SHOW SERVEROUTPUT` sigue respondiendo "ON": no hay
# forma de notarlo salvo que falten las lineas. Sin esto, los DBMS_OUTPUT de
# los .sql y del paso 5 se descartan y un build mudo se lee igual que uno bueno.
readonly SQLPLUS_ENTER_PDB="ALTER SESSION SET CONTAINER=${PDB};
SET SERVEROUTPUT ON SIZE UNLIMITED"

# ---------------------------------------------------------------------------
# 1. Instalación del engine de APEX
#    apexins.sql <tbs_apex> <tbs_files> <tbs_temp> <images_url>
#    /i/ es la ruta virtual de estáticos que después sirve ORDS.
# ---------------------------------------------------------------------------
log "Instalando el engine de APEX en ${PDB} (paso largo: 4-30 min según la máquina)"
cd "${APEX_HOME}"
sqlplus -s -L / as sysdba <<SQL
${SQLPLUS_HEADER}
${SQLPLUS_ENTER_PDB}
@apexins.sql SYSAUX SYSAUX TEMP /i/
SQL

# ---------------------------------------------------------------------------
# 2. Usuarios REST de APEX (APEX_LISTENER / APEX_REST_PUBLIC_USER)
#
#    apex_rest_config.sql NO acepta las contraseñas como parámetros
#    posicionales: su propia cabecera dice "You will be prompted to enter
#    passwords for both users". Internamente despacha a apex_rest_config_nocdb.sql,
#    que hace dos `accept ... HIDE` — primero APEX_LISTENER, después
#    APEX_REST_PUBLIC_USER.
#
#    Pasarlas como argumentos las ignora y el prompt se come el EOF del heredoc:
#    el usuario queda creado con contraseña vacía y el build muere con un
#    ORA-01741 (illegal zero-length identifier) que no menciona el prompt.
#    Por eso van como DOS LÍNEAS de stdin, en ese orden, justo después del @.
#
#    Si una versión futura de APEX cambia la cantidad de prompts, esto se
#    desalinea en silencio: el paso 5 verifica que ambos usuarios existan.
# ---------------------------------------------------------------------------
log "Configurando usuarios REST de APEX"
sqlplus -s -L / as sysdba <<SQL
${SQLPLUS_HEADER}
${SQLPLUS_ENTER_PDB}
@apex_rest_config.sql
${APEX_PUBLIC_USER_PASSWORD}
${APEX_PUBLIC_USER_PASSWORD}
SQL

# ---------------------------------------------------------------------------
# 3. Post-configuración: cuenta ADMIN, APEX_PUBLIC_USER, parámetros de instancia
# ---------------------------------------------------------------------------
log "Post-configuración de la instancia APEX"
cd "${SQL_DIR}"
sqlplus -s -L / as sysdba <<SQL
${SQLPLUS_HEADER}
${SQLPLUS_ENTER_PDB}
DEFINE apex_admin_pwd = "${APEX_ADMIN_PASSWORD}"
DEFINE apex_admin_email = "${APEX_ADMIN_EMAIL}"
DEFINE apex_public_pwd = "${APEX_PUBLIC_USER_PASSWORD}"
SET DEFINE ON
@${SQL_DIR}/10_apex_instance.sql
@${SQL_DIR}/20_network_acl.sql
SQL

# ---------------------------------------------------------------------------
# 4. Recompilación de objetos inválidos
#
#    utlrp.sql llama a `@@utlprp.sql 0` y utlprp.sql lee ese argumento con
#    `&&1` (grado de paralelismo). Con el `SET DEFINE OFF` del header la
#    sustitución no ocurre y el paso muere con `SP2-0552: Bind variable "1"
#    not declared`, que NO aborta el script: los errores SP2- son de SQL*Plus,
#    no de SQL, y `WHENEVER SQLERROR` no los ve. Resultado: la recompilación
#    se saltea en silencio. Por eso acá se reactiva DEFINE.
# ---------------------------------------------------------------------------
log "Recompilando objetos inválidos"
sqlplus -s -L / as sysdba <<SQL
${SQLPLUS_HEADER}
${SQLPLUS_ENTER_PDB}
SET DEFINE ON
@?/rdbms/admin/utlrp.sql
SQL

# ---------------------------------------------------------------------------
# 5. Verificación: si APEX no quedó VALID, el build tiene que fallar acá y no
#    producir una imagen aparentemente sana.
# ---------------------------------------------------------------------------
log "Verificando instalación"
sqlplus -s -L / as sysdba <<SQL
${SQLPLUS_HEADER}
${SQLPLUS_ENTER_PDB}
SET ECHO OFF FEEDBACK OFF PAGESIZE 50 LINESIZE 120
COLUMN comp_name FORMAT A40
SELECT comp_name, version_full, status
  FROM dba_registry
 WHERE comp_id = 'APEX';

DECLARE
  l_status dba_registry.status%TYPE;
  l_invalid PLS_INTEGER;
BEGIN
  SELECT status INTO l_status FROM dba_registry WHERE comp_id = 'APEX';
  IF l_status <> 'VALID' THEN
    raise_application_error(-20001, 'APEX quedo en estado ' || l_status);
  END IF;

  SELECT COUNT(*) INTO l_invalid
    FROM dba_objects
   WHERE status = 'INVALID'
     AND owner LIKE 'APEX%';
  IF l_invalid > 0 THEN
    raise_application_error(-20002, l_invalid || ' objetos APEX invalidos');
  END IF;

  dbms_output.put_line('APEX instalado y validado correctamente.');
END;
/
SQL

log "Instalación de APEX completada"
