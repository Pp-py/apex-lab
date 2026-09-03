# Validación end-to-end

El entorno **se corrió completo el 26/08/2026** y quedó funcionando. Este
documento reemplaza a la lista de pendientes: registra qué se verificó, con qué
método, y los siete bugs que la corrida destapó.

Entorno de la corrida: Docker 29.7.2 sobre WSL2 (Ubuntu 24.04), ext4.

El **03/09/2026 se repitió sobre la base 23.26.3** y volvió a pasar completa;
está registrado en [Revalidación sobre 23.26.3](#revalidación-sobre-23263).

## Resultado

| Punto | Estado | Cómo se verificó |
|---|---|---|
| Build completo | ✅ `RC_FINAL=0` en 6 m 58 s | `./build.sh` desde cero, imagen y volúmenes borrados |
| SHA256 de APEX | ✅ fijado y validado | 2ª corrida imprime `SHA256 verificado` |
| Engine de APEX | ✅ `26.1.0 VALID`, 0 objetos inválidos | `dba_registry` + `dba_objects` |
| Usuarios REST | ✅ los tres `OPEN` | `APEX_LISTENER`, `APEX_REST_PUBLIC_USER`, `APEX_PUBLIC_USER` |
| ORDS | ✅ conecta e instala su esquema | `docker compose logs ords` |
| APEX Builder | ✅ HTTP 302 al sign-in tras 45 s | `curl /ords/apex` |
| Estáticos `/i/` | ✅ CSS, JS e iconos con 200 y content-type correcto | `curl /i/apex_ui/css/Core.min.css` → `200 text/css` |
| ACLs del engine | ✅ otorgadas a `APEX_260100` y `APEX_REST_PUBLIC_USER` | `dba_host_aces` |
| ACL de esquema de app | ✅ receta verificada | sin ACL falla, con ACL `status=200` |
| SMTP → Mailpit | ✅ correo real capturado | `APEX_MAIL.send` + `push_queue` → API de Mailpit |
| Idempotencia del SQL | ✅ 2 pasadas seguidas `rc=0` | rama `create_user` y rama `edit_user` |
| `sync_env()` | ✅ genera y detecta deriva | 1ª corrida genera `.env`, 2ª valida |

## Números medidos (los documentados estaban muy lejos)

| | Decía | Es |
|---|---|---|
| Build | ~30 min | **6 m 58 s** |
| Imagen | ~7 GB | **16,3 GB** (base 11,6 + capa 4,7) |
| Primer `up` | "tarda muchísimo" | **9 s**, volumen de 4,5 GB |

## Revalidación sobre 23.26.3

El 03/09/2026 se subió la base a `gvenzl/oracle-free:23.26.3-full-faststart` y se
rehorneó. Mismo entorno (Docker 29.7.2 sobre WSL2, Ubuntu 24.04). **La corrida
pasó completa y no destapó ningún bug nuevo**: ninguno de los siete de arriba
volvió.

| Punto | Estado |
|---|---|
| Build | ✅ `exit 0` en 14 m 52 s |
| Imagen | ✅ `apex-lab:db23.26.3-apex26.1`, 16,3 GB |
| BD | ✅ `23.26.3.0.0` (`v$version`) |
| `dba_registry` | ✅ todo `VALID`; RAC en `OPTION OFF` |
| Engine de APEX | ✅ `26.1.0 VALID`, 0 objetos inválidos |
| Builder | ✅ HTTP 302 al sign-in |
| Estáticos `/i/` | ✅ CSS `200 text/css` (667 KB), JS `200 text/javascript` |
| ACLs del engine | ✅ `APEX_260100` y `APEX_REST_PUBLIC_USER`, CONNECT + RESOLVE |
| SMTP → Mailpit | ✅ correo real capturado |
| `up -d` con volumen nuevo | ✅ 13,6 s |

Los **14 m 52 s no se comparan con los 6 m 58 s** de la primera corrida: acá
entró el `docker pull` de una base nueva (2,6 GiB comprimidos, ~11,6 GB
extraídos), que en la corrida original ya estaba local.

Subir la base **obliga a `down -v`**. El volumen conserva los datafiles de la
versión anterior, y como el faststart solo los copia cuando el volumen está
vacío, un `down` común deja binarios nuevos sobre datafiles viejos: la base
abre, pero sin el `datapatch` que le corresponde. En un entorno desechable la
respuesta es destruir el volumen; si algún día no lo es, hay que sacar un dump
antes.

### Dos trampas al verificar, no del entorno

- **`apex_mail_queue` filtra por workspace.** En una sesión sin
  `apex_util.set_security_group_id(...)` devuelve 0 filas siempre, así que
  "la cola está vacía" no prueba nada. Con el contexto puesto sí se ve, y ahí
  `MAIL_SEND_ERROR` dice por qué no salió. Ojo también con el nombre de la
  columna: es `MAIL_SUBJ`, no `MAIL_SUBJECT`.
- **`push_queue` entrega recién al commit.** Consultar la API de Mailpit
  inmediatamente después del bloque PL/SQL da `total: 0` aunque todo esté bien.
  Es una carrera del test, no una falla del SMTP: hay que commitear (o cerrar la
  sesión) y recién ahí mirar.

## Bugs que la corrida destapó

Ninguno era detectable sin ejecutar. Los seis primeros abortaban o degradaban el
build; el séptimo desinformaba.

1. **`SP2-0606: Cannot create SPOOL file`** — `docker cp` preserva el uid/gid
   *numérico del host* (1000), que dentro del contenedor no le corresponde a
   nadie: el runtime es `oracle` (54321). `apexins.sql` spoolea en el cwd y moría
   a los 2 s. → `chown` al uid runtime, resuelto dinámicamente.

2. **`ORA-01741: illegal zero-length identifier`** — `apex_rest_config.sql` no
   acepta contraseñas como parámetros posicionales; su cabecera dice *"You will
   be prompted"*. Los argumentos se ignoraban, el prompt se comía el EOF del
   heredoc y los usuarios quedaban con contraseña vacía. → dos líneas por stdin.

3. **`PLS-00306` en `EDIT_USER`** — asimetría de la API de Oracle:
   `CREATE_USER` recibe `P_DEVELOPER_PRIVS`, `EDIT_USER` recibe
   `P_DEVELOPER_ROLES`. Como PL/SQL compila el bloque entero antes de ejecutarlo,
   reventaba incluso en un build limpio donde esa rama nunca corre.

4. **`ORA-20987` en `ACCOUNT_LIFETIME_DAYS`** — APEX 26.1 valida contra
   `[1-9][0-9]{0,3}`: el `'0'` que uno espera para "nunca" **no existe**. Abortaba
   el bloque y dejaba SMTP y las ACLs sin aplicar. → `9999`.

5. **`SP2-0552: Bind variable "1" not declared`** — `utlrp.sql` llama a
   `@@utlprp.sql 0` y `utlprp.sql` lee el argumento con `&&1`; el `SET DEFINE OFF`
   del header lo rompía. Peor: los errores `SP2-` **no** disparan
   `WHENEVER SQLERROR`, así que la recompilación se salteaba en silencio.

6. **`DBMS_OUTPUT` descartado** — `ALTER SESSION SET CONTAINER` descarta el
   buffer de DBMS_OUTPUT del lado del servidor. Activar `SERVEROUTPUT` *antes*
   del `ALTER SESSION` no sirve, y lo traicionero es que `SHOW SERVEROUTPUT`
   sigue respondiendo `ON`: no hay forma de notarlo salvo que falten las líneas.
   → entrar a la PDB y recién ahí activarlo.

7. **`docker commit --change "LABEL k=v con espacios"`** — el `--change` se
   parsea como línea de Dockerfile y parte por espacios. Fallaba con
   `Syntax error - can't find = in "Database"`, nombrando la segunda palabra del
   valor sin decir qué label era. → comillas internas.

## Detalles que corrigen la documentación

- **El error de ACL faltante es `ORA-29273: HTTP request failed`**, no
  `ORA-24247` a secas: el 24247 viene anidado y `SQLERRM` suele mostrar solo el
  primero. Si ves un 29273 contra un host que responde, sospechá de la ACL.
- **`docker image inspect --format '{{.Size}}'` no es el tamaño en disco** con el
  image store de containerd: devuelve ~3 GB para una imagen de 16 GB.

## Lo que sigue sin ejercitarse

**El perfil `oracle` de `scripts/base-profile.sh`.** Es el plan B (imagen oficial
de Oracle) y nunca se corrió. `build.sh` ahora valida que perfil e imagen sean de
la misma familia, pero el camino completo está sin probar: esperá ajustar
detalles, sobre todo el healthcheck y si la imagen crea la base en el primer
arranque en vez de traerla hecha.

Al migrar hay que actualizar además los ejemplos del README: `createAppUser` y
`resetPassword` son de la imagen `gvenzl` y no existen en la oficial.

## Cómo repetir la validación

```bash
./build.sh && docker compose up -d
```

Después, en orden de valor:

1. http://localhost:8080/ords/apex **con estilos** (si carga en texto plano, el
   montaje de `./cache/apex` en ORDS está mal).
2. http://localhost:8025 responde (Mailpit).
3. Los `DBMS_OUTPUT` del build aparecen: `Cuenta ADMIN creada.`,
   `Esquema de APEX detectado: APEX_...`, `APEX instalado y validado correctamente.`
   Si el build es mudo, el punto 6 volvió.
4. Llamada saliente real desde un esquema propio, tras aplicar la receta de
   [`init/README.md`](../init/README.md).
