# `init.example/` — plantilla de semillas del proyecto

Esto es la **plantilla versionada**. El directorio que compose monta es `./init`,
que **no se versiona** (está en `.gitignore`): ahí van el DDL, los datos de
prueba y las credenciales de cada proyecto, que no tienen por qué subir al repo
de `apex-lab`.

`./build.sh` crea `init/` copiando este directorio si todavía no existe. A mano:

```bash
cp -r init.example init
```

Todo `.sql` y `.sh` que dejes en `init/` se ejecuta cuando arranca la base. Sirve
para crear el esquema de la aplicación, cargar datos de prueba o instalar
utilidades.

```
init/
├── 01_crear_esquema.sql
├── 02_acl_esquema_app.sql
└── 03_datos_demo.sql
```

Se ejecutan en orden alfabético, de ahí el prefijo numérico.

## Tres cosas que se olvidan siempre

1. **Corren UNA SOLA VEZ**, en el primer arranque del volumen `oradata`. Editar
   un script después no hace nada. Para volver a ejecutarlos:
   `docker compose down -v` (destruye la base) y `up` de nuevo.
2. **Corren como SYS y contra la CDB**, no contra la PDB. Si tu script trabaja
   sobre la aplicación —que es lo normal— tiene que abrir el contenedor:
   ```sql
   ALTER SESSION SET CONTAINER = FREEPDB1;
   ```
3. **Un error acá no siempre aborta el arranque.** Revisá `docker compose logs db`
   después del primer `up` en vez de asumir que salió bien.

Alternativa para crear un usuario en cualquier momento, sin destruir nada
(la imagen base ya trae el comando):

```bash
docker exec <contenedor-db> createAppUser MI_APP mi_password FREEPDB1
```

## Receta: ACL de red para el esquema de la aplicación

`sql/20_network_acl.sql` otorga ACLs al engine de APEX y a
`APEX_REST_PUBLIC_USER` durante el build. **No cubre el esquema de tu
aplicación**, que todavía no existe en ese momento.

Si tu propio PL/SQL llama a `APEX_WEB_SERVICE`, `UTL_HTTP` o `UTL_SMTP`
—consumir una API externa, disparar un webhook, mandar mail desde un paquete
propio— la llamada falla hasta otorgarle la ACL a ese esquema.

**El error que vas a ver es `ORA-29273: HTTP request failed`**, no `ORA-24247`
a secas: el 24247 viene anidado adentro y `SQLERRM` a veces solo muestra el
primero. Verificado en este entorno. Si ves un 29273 contra un host que sabés
que responde, la ACL es la primera sospechosa.

Copiá esto como `init/02_acl_esquema_app.sql` y cambiá el nombre del esquema:

```sql
-- ---------------------------------------------------------------------------
-- ACL de red para el esquema de la aplicacion.
-- Entorno local desechable: host => '*'. En un servidor compartido esto se
-- otorga por host concreto (y por puerto), nunca con comodin.
-- ---------------------------------------------------------------------------
ALTER SESSION SET CONTAINER = FREEPDB1;
SET SERVEROUTPUT ON SIZE UNLIMITED

DECLARE
    c_schema CONSTANT VARCHAR2(128) := 'MI_APP';   -- <-- cambiar
BEGIN
    DBMS_NETWORK_ACL_ADMIN.append_host_ace(
        host => '*',
        ace  => xs$ace_type(
                    privilege_list => xs$name_list('connect', 'resolve'),
                    principal_name => c_schema,
                    principal_type => xs_acl.ptype_db ) );
    COMMIT;
    DBMS_OUTPUT.put_line('ACL de red otorgada a ' || c_schema);
END;
/
```

### Si el endpoint es HTTPS

La ACL resuelve el `ORA-24247`, no el TLS. Un `ORA-29024` o `ORA-28860` después
de la ACL significa que falta la cadena de certificados: hay que cargarla en el
wallet de la base y pasar `p_wallet_path` a `APEX_WEB_SERVICE`, o registrarla en
el wallet por defecto de la instancia.

Es lo primero a mirar cuando el endpoint usa una CA que la base no conoce
—típico de APIs internas, entornos de sandbox y organismos públicos que emiten
sus propios certificados.
