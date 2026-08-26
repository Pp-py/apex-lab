-- ---------------------------------------------------------------------------
-- 20_network_acl.sql
-- ACLs de red para el esquema de APEX.
--
-- Sin esto, APEX_WEB_SERVICE, las REST Data Sources y cualquier llamada
-- saliente (consumir una API externa, disparar un webhook) fallan con
-- ORA-24247. Es el error #1 que aparece al levantar un APEX recien instalado.
--
-- ALCANCE: cubre el engine de APEX y APEX_REST_PUBLIC_USER, que es lo que se
-- puede saber en tiempo de build. El esquema de TU aplicacion NO queda cubierto
-- aca: se crea despues y es distinto en cada proyecto. Si tu propio PL/SQL
-- llama a APEX_WEB_SERVICE o UTL_HTTP, vas a seguir viendo ORA-24247 hasta
-- otorgarle la ACL a ese esquema. La receta esta en init/README.md.
--
-- ATENCION: usa host => '*'. Aceptable SOLO en un entorno local desechable.
-- Nunca replicar este script tal cual en un servidor compartido o productivo:
-- ahi las ACLs se otorgan por host concreto.
--
-- Fuente ASCII puro a proposito (ver cabecera de 10_apex_instance.sql).
-- ---------------------------------------------------------------------------
WHENEVER SQLERROR EXIT FAILURE
SET SERVEROUTPUT ON SIZE UNLIMITED

DECLARE
    -- El esquema de APEX cambia con cada release (APEX_260100 para 26.1).
    -- Se lee de dba_registry, que es la fuente autoritativa: buscarlo por
    -- regex sobre dba_users devuelve tambien los esquemas de versiones
    -- anteriores, que sobreviven a un upgrade, y elegir "el ultimo alfabetico"
    -- entre ellos es una apuesta, no una respuesta.
    l_apex_schema  VARCHAR2(128);
    TYPE t_principals IS TABLE OF VARCHAR2(128);
    l_principals   t_principals;
BEGIN
    BEGIN
        SELECT r.schema
          INTO l_apex_schema
          FROM dba_registry r
         WHERE r.comp_id = 'APEX';
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            raise_application_error(-20010,
                'APEX no figura en dba_registry: el engine no se instalo.');
    END;

    l_principals := t_principals(l_apex_schema, 'APEX_REST_PUBLIC_USER');

    -- append_host_ace es acumulativo: re-ejecutar el script fusiona privilegios
    -- sobre el ACE existente en vez de duplicarlo, asi que es idempotente.
    FOR i IN 1 .. l_principals.COUNT LOOP
        DBMS_NETWORK_ACL_ADMIN.append_host_ace(
            host => '*',
            ace  => xs$ace_type(
                        privilege_list => xs$name_list('connect', 'resolve'),
                        principal_name => l_principals(i),
                        principal_type => xs_acl.ptype_db ) );
        DBMS_OUTPUT.put_line('ACL otorgada a ' || l_principals(i));
    END LOOP;

    COMMIT;
    DBMS_OUTPUT.put_line('Esquema de APEX detectado: ' || l_apex_schema);
END;
/

PROMPT ACLs de red configuradas (host => *, solo para desarrollo local).
