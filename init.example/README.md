# `init.example/` — plantilla de semillas del proyecto

Esto es la **plantilla versionada**. El directorio que compose monta es `./init`,
que **no se versiona** (está en `.gitignore`): ahí van el DDL, los datos de
prueba y las credenciales de cada proyecto, que no tienen por qué subir al repo
de `apex-lab`.

`./build.sh` crea `init/` copiando este directorio si todavía no existe. A mano:

```bash
cp -r init.example init
```

El entrypoint de la imagen ejecuta lo que dejes en `init/` que termine en `.sh`,
`.sql`, `.sql.zip` o `.sql.gz`, en orden alfabético — de ahí el prefijo numérico.
Cualquier otro nombre se ignora, y eso es lo que hace **inertes** a las
plantillas de acá: terminan en `.example`.

```
init.example/                        init/  (lo que corre)
├── 00_pdbadmin.sh.example    ──cp──▶ 00_pdbadmin.sh
├── 01_workspace.sh.example   ──cp──▶ 01_workspace.sh
└── 02_acl_app.sh.example     ──cp──▶ 02_acl_app.sh
```

Para activar una:

```bash
cp init.example/01_workspace.sh.example init/01_workspace.sh
```

Y nada más: **no hay nada que editar adentro.** Los nombres del workspace y del
esquema, y las contraseñas, salen del bloque `Semillas de ./init` de tu `.env`,
que es el único punto de seteo. Los scripts los leen del entorno del contenedor,
que compose llena desde ese `.env`.

Qué hace cada una:

| Plantilla | Qué crea |
|---|---|
| `00_pdbadmin.sh` | Fija la clave de `PDBADMIN`, que la imagen base deja con una que nunca documenta. **Opcional**: `SYSTEM` ya alcanza para prototipar. |
| `01_workspace.sh` | El esquema de la aplicación, su workspace de APEX y el usuario administrador de ese workspace. |
| `02_acl_app.sh` | La ACL de red del esquema, para que su PL/SQL pueda hacer llamadas salientes. |

### El bit de ejecución no es opcional

El entrypoint **ejecuta** los `.sh` que tienen `+x` y **sourcea** los que no, y
su rama de sourcing tiene un bug: le falta un `;`, así que le pasa el `echo`
siguiente como argumento al script. Un `.sh` sin `+x` se rompe de una forma
bastante difícil de leer.

Las plantillas ya vienen con el bit puesto y `cp` preserva el modo, así que
copiando desde acá no hay nada que hacer. Si lo perdés:

```bash
chmod +x init/*.sh
```

## Tres cosas que se olvidan siempre

1. **Corren en CADA arranque del contenedor**, así que **tienen que ser
   idempotentes**: consultá el estado antes de actuar, como hacen las
   plantillas. Un `CREATE USER` a secas falla en el segundo `up`.

   Suena raro para algo llamado "init", y tiene una razón. El entrypoint corre
   `initdb.d` solo cuando la base **no** existe, y lo decide con
   `[ -d oradata/dbconfig/$ORACLE_SID ]`. Esta imagen sale de un `-faststart` +
   `docker commit`, así que ese directorio viaja dentro de la imagen y se copia
   al volumen en el primer `up`: el entrypoint loguea `database already
   initialized` y saltea `initdb.d` **siempre**, incluso con un volumen recién
   creado. Por eso `compose.yml` monta `./init` en `startdb.d`, que corre fuera
   de ese condicional.

   Lo bueno del cambio: **editar el `.env` y reiniciar alcanza**. No hace falta
   `down -v` para que una semilla nueva tome efecto —solo para volver a una base
   limpia—.
2. **Corren como SYS y contra la CDB**, no contra la PDB — los `.sql` por
   `sqlplus / as sysdba`, y los `.sh` porque conectan igual. Si tu script
   trabaja sobre la aplicación —que es lo normal— tiene que abrir el contenedor:
   ```sql
   ALTER SESSION SET CONTAINER = FREEPDB1;
   ```
   Y si vas a usar `DBMS_OUTPUT`, el `SET SERVEROUTPUT ON` va **después** de ese
   `ALTER SESSION`: cambiar de contenedor descarta el buffer del lado del
   servidor y las líneas se pierden sin aviso.
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

Esto ya está resuelto en `02_acl_app.sh.example`: toma el esquema de
`APP_SCHEMA` y le otorga `connect` + `resolve`. Activalo con

```bash
cp init.example/02_acl_app.sh.example init/02_acl_app.sh
```

El script usa `host => '*'`, igual que el del build: **correcto en un entorno
local aislado, incorrecto en cualquier otro lado.** Si lo llevás a un servidor
compartido, cambiá `ACL_HOST` por el host concreto que vas a llamar.

Como `append_host_ace` es acumulativo, re-ejecutarlo fusiona privilegios sobre
el ACE existente en vez de duplicarlo: el script es idempotente y se puede
correr a mano sin destruir el volumen.

```bash
docker exec <contenedor-db> /container-entrypoint-initdb.d/02_acl_app.sh
```

### Si el endpoint es HTTPS

La ACL resuelve el `ORA-24247`, no el TLS. Un `ORA-29024` o `ORA-28860` después
de la ACL significa que falta la cadena de certificados: hay que cargarla en el
wallet de la base y pasar `p_wallet_path` a `APEX_WEB_SERVICE`, o registrarla en
el wallet por defecto de la instancia.

Es lo primero a mirar cuando el endpoint usa una CA que la base no conoce
—típico de APIs internas, entornos de sandbox y organismos públicos que emiten
sus propios certificados.
