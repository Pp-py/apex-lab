# CLAUDE.md

Guía para trabajar en este repo. Idioma de trabajo: español.

## Qué es esto

`apex-lab` es un **entorno local desechable** para prototipar con Oracle APEX.
No es infraestructura productiva y no debe tratarse como tal.

Publica **la receta, no la imagen**: un build de unos 7 minutos genera una imagen
de Oracle Database Free con APEX ya instalado dentro; después cada proyecto
arranca en segundos sobre esa misma imagen.

| Componente | Versión | Se actualiza |
|---|---|---|
| Oracle Database Free | 23.26.3 (`gvenzl/oracle-free`) | `versions.env` + `./build.sh` |
| Oracle APEX | 26.1 | `versions.env` + `./build.sh` |
| ORDS | 26.1.2 (imagen oficial) | solo el tag, sin rebuild |
| Mailpit | latest | — |

## Comandos

```bash
./build.sh              # ~7 min, una vez por versión de APEX. Genera/valida .env
docker compose up -d    # copia los datafiles al volumen (~4,5 GB), segundos
docker compose down     # conserva los datos
docker compose down -v  # destruye la base

KEEP_ON_ERROR=1 ./build.sh    # no borra el contenedor de build si falla
ALLOW_ENV_DRIFT=1 ./build.sh  # sigue aunque .env difiera de versions.env
```

Verificación estática, para cuando no tenés Docker a mano:

```bash
bash -n build.sh scripts/*.sh
shellcheck -x build.sh scripts/*.sh   # también corre en CI
```

Servicios: APEX Builder en `:8080/ords/apex` (workspace `INTERNAL`, usuario
`ADMIN`), Mailpit en `:8025`, SQL en `system/oracle@localhost:1521/FREEPDB1`.

## Estructura

```
build.sh                  entry point del build (queda en la raíz a propósito)
compose.yml               stack: db + ords + mail
versions.env              ÚNICA fuente de verdad de versiones y credenciales
.env.example              plantilla; ./build.sh genera el .env real
scripts/base-profile.sh   convenciones por imagen base (se sourcea, no se ejecuta)
scripts/install-apex.sh   corre DENTRO del contenedor de build
sql/                      post-configuración de APEX, se copia al contenedor
init.example/             plantilla de semillas; build.sh siembra ./init (no versionado)
docs/                     registro de la validación end-to-end
```

## Arquitectura: por qué es así

**`docker run` + `docker commit`, no un Dockerfile.** La base tiene que estar
levantada para correr `apexins.sql`, y un `RUN` de BuildKit no permite fijar
`--shm-size`: con los 64 MB por defecto la SGA no arranca. Con run+commit se
controla memoria, `/dev/shm` y el apagado limpio de la instancia.

**ORDS va aparte, fuera de la imagen.** APEX y ORDS tienen ciclos de release
independientes; subir ORDS es cambiar un tag en vez de rehornear 16 GB.

**Versiones fijas + SHA256, nunca `apex-latest.zip`.** Oracle re-publica
archivos con el mismo nombre. El hash fijado es la única defensa contra un
cambio silencioso.

## Modelo de configuración (importante)

`versions.env` + `scripts/base-profile.sh` son la **única fuente de verdad**.

`build.sh` **propaga** los valores derivados al `.env` que consume compose
(`APEX_DB_IMAGE`, `ORDS_TAG`, `ORACLE_PASSWORD`, `DB_HEALTHCHECK_CMD`,
`DB_SEED_DIR`) y **aborta** si un `.env` existente divergió, indicando la
línea exacta. El resto de `.env` —`COMPOSE_PROJECT_NAME` y los puertos— es
legítimamente por-proyecto y `build.sh` no lo toca.

Al agregar una variable, decidí de qué lado está: si sale de una versión o del
perfil de imagen, va en `versions.env` y se suma a `DERIVED_KEYS` en `build.sh`.
Si varía por proyecto, va solo en `.env.example`.

**No dupliques un valor en dos archivos con un comentario "deben coincidir".**
Ese patrón es exactamente lo que se sacó de este repo.

## Convenciones

**Todo el SQL es 100 % ASCII**, sin tildes ni eñes ni siquiera en los
comentarios. Corre dentro del contenedor con el `NLS_LANG` heredado del entorno.
La regla vale para los `.sql` **y para el SQL embebido en los heredocs de
`scripts/install-apex.sh`** — es fácil pasar por alto un literal acentuado ahí
adentro. Chequeo:

```bash
LC_ALL=C grep -nP '[^\x09\x0A\x0D\x20-\x7E]' sql/*.sql
awk '/<<SQL$/,/^SQL$/' scripts/install-apex.sh | LC_ALL=C grep -nP '[^\x09\x0A\x0D\x20-\x7E]'
```

Siempre `WHENEVER SQLERROR EXIT FAILURE` y `SET SERVEROUTPUT ON`: sin lo
segundo, los `DBMS_OUTPUT` se descartan y un build mudo se lee igual que uno
exitoso.

**El `SET SERVEROUTPUT ON` va DESPUÉS del `ALTER SESSION SET CONTAINER`**, nunca
antes: cambiar de contenedor descarta el buffer del lado del servidor. Lo
traicionero es que `SHOW SERVEROUTPUT` sigue diciendo `ON`, así que el único
síntoma es que faltan líneas. Por eso `install-apex.sh` los emite juntos en
`SQLPLUS_ENTER_PDB` en vez de poner el `SERVEROUTPUT` en el header.

**Nada de `WHEN OTHERS` comparando `SQLERRM` contra literales en inglés.** Se
rompe con `NLS_LANGUAGE` distinto de `AMERICAN`. Para idempotencia, consultá el
estado antes de actuar (patrón en `sql/10_apex_instance.sql`).

**Metadatos de APEX**: resolvelos en tiempo de ejecución desde vistas
autoritativas (`dba_registry` para el esquema de APEX), nunca hardcodeados ni
adivinados por regex sobre `dba_users` — tras un upgrade conviven varios
esquemas `APEX_*`.

**Shell**: `set -Eeuo pipefail`, funciones `log`/`warn`/`die`, comentarios que
explican el *porqué* de la decisión no obvia. Los comentarios en `.sh` sí llevan
acentos; la regla ASCII es solo para el PL/SQL.

**Un `timeout` en el host sobre `docker exec` mata al cliente, no al proceso.**
Si necesitás acotar algo que corre dentro del contenedor, el `timeout` va
adentro.

## Trampas conocidas

- **`shm_size: 2gb` es obligatorio.** Sin eso: `ORA-00845`, la base no arranca.
- **El primer `up` copia los datafiles al volumen** (~4,5 GB). Medido: 9 s en
  WSL2 sobre ext4; en Docker Desktop con montajes lentos puede ser bastante más.
  Pasa una sola vez por proyecto.
- **Las credenciales están horneadas en la imagen**, deliberadamente
  (`versions.env` → `BUILD_*`), para que `docker compose up` funcione sin pasos
  manuales. Nunca poner ahí una contraseña que se use en otro lado. `build.sh`
  rechaza contraseñas con `&`, comillas, `\`, `$` o espacios: romperían la
  sustitución de SQL*Plus.
- **Los puertos se publican en `127.0.0.1` por defecto** (`BIND_ADDR` en `.env`).
  No es paranoia: las credenciales están en el repo público y APEX corre sin
  HTTPS, así que un `0.0.0.0` deja la base y el Builder abiertos a toda la red
  local. Si alguna vez lo abrís para una demo, volvelo a loopback después.
- **`sql/20_network_acl.sql` usa `host => '*'`.** Correcto en un entorno local
  aislado, **incorrecto en cualquier otro lado**. No copiar a un servidor
  compartido.
- **Las ACLs del build no cubren el esquema de la aplicación.** Un
  `APEX_WEB_SERVICE` desde código propio da `ORA-24247` hasta otorgarla; la
  receta está en `init.example/README.md`.
- **Los scripts de `init/` corren una sola vez, como SYS y contra la CDB.**
  Necesitan `ALTER SESSION SET CONTAINER=FREEPDB1`.
- **`init/` está en `.gitignore` a propósito**: ahí va el DDL y los datos de cada
  proyecto, que no deben subir a este repo. Lo versionado es `init.example/`, y
  `build.sh` siembra `init/` desde ahí si falta. No agregues `init/` al índice
  ni le pongas un `.gitkeep`.

## Estado

El entorno **está validado end-to-end** (26/08/2026, Docker 29.7.2 sobre WSL2):
build en 6 m 58 s, APEX 26.1 VALID, ORDS sirviendo el Builder con estáticos,
correo cayendo en Mailpit y ACLs funcionando. **Revalidado el 03/09/2026** sobre
la base 23.26.3, sin bugs nuevos.

**Subir la versión de la base obliga a `docker compose down -v`.** El volumen
guarda los datafiles de la versión anterior y el faststart solo los copia cuando
está vacío: conservarlo deja binarios nuevos sobre datafiles viejos, sin el
`datapatch` que corresponde.

[`docs/validacion-e2e.md`](docs/validacion-e2e.md) registra qué se verificó y
cómo, más los siete bugs que la corrida destapó — ninguno era detectable sin
ejecutar. Leelo antes de tocar `install-apex.sh` o los `.sql`: varias decisiones
que parecen arbitrarias (el orden de `SERVEROUTPUT`, el `chown` tras `docker cp`,
los prompts por stdin) están ahí porque sin ellas el build falla o miente.

Lo único sin ejercitar es el **perfil `oracle`** de `base-profile.sh`: es el plan
B, no el camino principal.
