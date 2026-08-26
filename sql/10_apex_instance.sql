-- ---------------------------------------------------------------------------
-- 10_apex_instance.sql
-- Post-configuracion de la instancia APEX. Se ejecuta como SYSDBA dentro de
-- la PDB, al final de la instalacion del engine.
--
-- Parametros (sustitucion de SQL*Plus, los define scripts/install-apex.sh):
--   &apex_admin_pwd, &apex_admin_email, &apex_public_pwd
--
-- Fuente ASCII puro a proposito: el script corre dentro del contenedor con el
-- NLS_LANG heredado del entorno, y un comentario acentuado en un charset
-- inesperado puede abortar el parseo. Sin tildes, sin enies, sin comillas
-- tipograficas.
-- ---------------------------------------------------------------------------
WHENEVER SQLERROR EXIT FAILURE
SET SERVEROUTPUT ON SIZE UNLIMITED

-- ---------------------------------------------------------------------------
-- Perfil de contrasenas
-- En un entorno de desarrollo, PASSWORD_LIFE_TIME por defecto (180 dias)
-- termina expirando APEX_PUBLIC_USER y rompiendo el login con un ORA-28002
-- meses despues, sin causa aparente. Se desactiva.
-- ---------------------------------------------------------------------------
ALTER PROFILE DEFAULT LIMIT PASSWORD_LIFE_TIME UNLIMITED;

-- ---------------------------------------------------------------------------
-- Usuario de conexion que usa ORDS contra APEX
-- ---------------------------------------------------------------------------
ALTER USER APEX_PUBLIC_USER IDENTIFIED BY "&apex_public_pwd" ACCOUNT UNLOCK;

-- ---------------------------------------------------------------------------
-- Cuenta ADMIN del workspace INTERNAL, sin prompt interactivo.
-- apxchpwd.sql es interactivo y no sirve en un build automatizado; la via
-- soportada es APEX_UTIL con el security group id 10 (workspace INTERNAL).
--
-- Idempotencia: se consulta si la cuenta existe ANTES de crearla, en vez de
-- crear y atrapar el error. Un WHEN OTHERS que compara SQLERRM contra un
-- literal ingles se rompe en cuanto el servidor tiene NLS_LANGUAGE distinto de
-- AMERICAN, y ahi el build aborta por una cuenta que ya estaba bien.
-- ---------------------------------------------------------------------------
DECLARE
    l_user_id NUMBER;
BEGIN
    APEX_UTIL.set_security_group_id( p_security_group_id => 10 );

    -- Segun la version, get_user_id devuelve NULL o levanta NO_DATA_FOUND
    -- cuando la cuenta no existe. Se contemplan las dos.
    BEGIN
        l_user_id := APEX_UTIL.get_user_id( p_username => 'ADMIN' );
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            l_user_id := NULL;
    END;

    IF l_user_id IS NULL THEN
        APEX_UTIL.create_user(
            p_user_name                    => 'ADMIN',
            p_email_address                => '&apex_admin_email',
            p_web_password                 => '&apex_admin_pwd',
            p_developer_privs              => 'ADMIN',
            p_default_schema               => 'SYS',
            p_change_password_on_first_use => 'N' );
        DBMS_OUTPUT.put_line('Cuenta ADMIN creada.');
    ELSE
        -- Rebuild sobre una base que ya tenia APEX: se reajusta la cuenta.
        -- Se pasan todos los atributos, no solo la clave: los parametros
        -- omitidos de edit_user no siempre conservan el valor previo.
        --
        -- OJO con la asimetria de la API: create_user recibe P_DEVELOPER_PRIVS
        -- y edit_user recibe P_DEVELOPER_ROLES. Usar el nombre equivocado da
        -- PLS-00306, y como PL/SQL compila el bloque entero antes de ejecutarlo,
        -- revienta incluso en un build limpio donde esta rama nunca corre.
        APEX_UTIL.edit_user(
            p_user_id                      => l_user_id,
            p_user_name                    => 'ADMIN',
            p_email_address                => '&apex_admin_email',
            p_web_password                 => '&apex_admin_pwd',
            p_developer_roles              => 'ADMIN',
            p_default_schema               => 'SYS',
            p_change_password_on_first_use => 'N' );
        DBMS_OUTPUT.put_line('Cuenta ADMIN ya existia: actualizada.');
    END IF;

    APEX_UTIL.set_security_group_id( p_security_group_id => NULL );
    COMMIT;
END;
/

-- ---------------------------------------------------------------------------
-- Parametros de instancia
-- SMTP apunta al contenedor Mailpit del compose: todo correo que emita APEX
-- (o tus paquetes tipo SEND_MAIL_HTML) queda atrapado en http://localhost:8025
-- y no sale nunca a internet. Es la unica forma segura de probar HTML de mail.
-- ---------------------------------------------------------------------------
BEGIN
    APEX_INSTANCE_ADMIN.set_parameter('SMTP_HOST_ADDRESS', 'mail');
    APEX_INSTANCE_ADMIN.set_parameter('SMTP_HOST_PORT',    '1025');
    APEX_INSTANCE_ADMIN.set_parameter('SMTP_FROM',         'apex@apex.local');

    -- Desarrollo local: sin HTTPS, no forzar cookies seguras ni el checksum
    -- de instancia, que solo complican el arranque.
    APEX_INSTANCE_ADMIN.set_parameter('REQUIRE_HTTPS',           'N');
    APEX_INSTANCE_ADMIN.set_parameter('DISABLE_ADMIN_LOGIN',     'N');

    -- Caducidad de cuentas de desarrollador lo mas lejos posible.
    -- APEX 26.1 valida este parametro contra "[1-9][0-9]{0,3}": el rango util
    -- es 1..9999 y el '0' que uno esperaria para "nunca" NO existe -- da un
    -- ORA-20987 que aborta el bloque entero y deja SMTP y las ACLs sin aplicar.
    -- 9999 dias son 27 anios: "nunca" para un entorno desechable.
    APEX_INSTANCE_ADMIN.set_parameter('ACCOUNT_LIFETIME_DAYS',   '9999');
    COMMIT;
    DBMS_OUTPUT.put_line('Parametros de instancia aplicados.');
END;
/

PROMPT Instancia APEX configurada.
