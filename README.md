# apex-lab

Entorno local desechable para prototipar con Oracle APEX. Un build de unos 7 minutos
cada vez que sale una versión nueva; después, cada proyecto arranca en segundos.

| Componente | Versión | Cómo se actualiza |
|---|---|---|
| Oracle Database Free | 23.26.3 (`gvenzl/oracle-free`) | `versions.env` + `./build.sh` |
| Oracle APEX | 26.1 | `versions.env` + `./build.sh` |
| ORDS | 26.1.2 (imagen oficial) | solo cambiar el tag, sin rebuild |
| Mailpit | latest | — |

---

## Arranque rápido

```bash
git clone <tu-repo> apex-lab && cd apex-lab

./build.sh              # ~7 min en una máquina rápida, una sola vez por versión
docker compose up -d    # copia los datafiles al volumen; suele tardar segundos
```

No hace falta copiar el `.env`: `build.sh` lo genera desde `.env.example` con
los valores de `versions.env` ya resueltos, y en cada corrida posterior verifica
que no haya divergido.

- **APEX Builder** → http://localhost:8080/ords/apex — workspace `INTERNAL`, usuario `ADMIN`
- **Mailpit** (todo el correo saliente cae acá) → http://localhost:8025
- **SQL** → `system/oracle@localhost:1521/FREEPDB1`

---

## Estructura

```
build.sh                    entry point del build
compose.yml                 stack: db + ords + mail
versions.env                única fuente de verdad de versiones y credenciales
.env.example                plantilla; build.sh genera el .env real
scripts/
├── base-profile.sh         convenciones por imagen base (se sourcea)
└── install-apex.sh         corre DENTRO del contenedor de build
sql/
├── 10_apex_instance.sql    cuenta ADMIN, SMTP, parámetros de instancia
└── 20_network_acl.sql      ACLs de red del engine de APEX
init.example/               plantilla de semillas; build.sh siembra ./init (no versionado)
docs/                       registro de la validación end-to-end
.github/workflows/          vigilancia de versiones upstream + shellcheck
```

---

## Un proyecto nuevo

La imagen se construye una vez y se reutiliza. Cada proyecto es un stack aislado
sobre la misma imagen:

```bash
mkdir -p ~/proyectos/proyecto-x && cd ~/proyectos/proyecto-x

# Se copia el .env ya generado, no el .example: trae los valores derivados
# (imagen, ORDS_TAG, contraseña, perfil) resueltos por el build.
cp ~/apex-lab/compose.yml ~/apex-lab/.env .
cp -r ~/apex-lab/init.example init            # semillas de este proyecto

sed -i 's/^COMPOSE_PROJECT_NAME=.*/COMPOSE_PROJECT_NAME=proyecto-x/' .env
sed -i 's/^DB_PORT=.*/DB_PORT=1522/;s/^ORDS_PORT=.*/ORDS_PORT=8081/;s/^MAILPIT_PORT=.*/MAILPIT_PORT=8026/' .env
docker compose up -d
```

Cambiar los puertos permite tener varios proyectos corriendo en paralelo.
Para destruir el entorno completo: `docker compose down -v`.

### Semillas del proyecto

Los `.sql` y `.sh` que dejes en `./init/` se ejecutan **como SYS, contra la CDB
y una sola vez**, en el primer arranque del volumen.

**`init/` no se versiona en este repo** (está en `.gitignore`): ahí viven el DDL,
los datos de prueba y las credenciales de cada proyecto, y no tienen por qué
viajar acá. Lo versionado es la plantilla `init.example/`, desde la cual
`./build.sh` siembra `init/` si no existe. Si un proyecto quiere versionar sus
semillas, que lo haga en el repo de ese proyecto.

En la plantilla también está la receta para otorgar la ACL de red al esquema de
tu aplicación, que el build **no** cubre: sin ella, cualquier llamada saliente
desde tu propio PL/SQL falla con `ORA-29273`.

→ [`init.example/README.md`](init.example/README.md)

---

## Actualizar versiones

1. Editar `versions.env`: nuevo `DB_BASE_IMAGE` y/o `APEX_VERSION`, vaciar `APEX_SHA256`.
2. **Revisar compatibilidad antes de correr nada.** APEX 26.1 exige ORDS ≥ 26.1.1
   y base ≥ 23.26.0. Cada release puede cambiar esos mínimos.
3. `rm -rf cache/apex` → el instalador viejo queda en cache.
4. `./build.sh` → imprime el SHA256 nuevo; pegarlo en `versions.env` y commitear.
5. Etiquetar el commit: `git tag apex-26.1 && git push --tags`.

El workflow `check-upstream.yml` corre mensualmente y abre un issue cuando
aparece una versión nueva, para que no dependa de acordarte.

---

## Cambiar de imagen base

La base por defecto es `gvenzl/oracle-free`. Si en algún momento es necesario
 el cambio por mantenimiento, política interna, etc. el plan B es la imagen
oficial de Oracle, y la migración está preparada.

Las convenciones que difieren entre imágenes (nombre de la variable de
contraseña, healthcheck, directorio de scripts de init) están aisladas en
`scripts/base-profile.sh`. Migrar es:

1. En `versions.env`: `DB_IMAGE_PROFILE="oracle"` y descomentar el `DB_BASE_IMAGE`
   oficial (tag `full`, nunca `lite`). `build.sh` valida que perfil e imagen sean
   de la misma familia y aborta si los cruzás.
2. `./build.sh`. El `.env` viejo va a divergir: el build corta indicando las dos
   líneas exactas a corregir (`DB_HEALTHCHECK_CMD`, `DB_INITDB_DIR`).
   Corregilas y volvé a correr.

| | `gvenzl` | `oracle` |
|---|---|---|
| Contraseña | `ORACLE_PASSWORD` | `ORACLE_PWD` |
| Healthcheck | `healthcheck.sh` | `/opt/oracle/checkDBStatus.sh` |
| Scripts de init | `/container-entrypoint-initdb.d` | `/opt/oracle/scripts/setup` |
| Cambiar contraseña | `resetPassword` | `setPassword.sh` |
| Crear usuario de app | `createAppUser` | a mano (`CREATE USER ...`) |

Las dos últimas filas no están abstraídas: son comandos que ejecutás vos, no
parte del build. Si migrás, ajustá los ejemplos de este README.

Lo que **no** cambia al migrar: la instalación de APEX (`scripts/install-apex.sh`,
`sql/*.sql`), ORDS, Mailpit y el flujo de proyectos. El engine de APEX se instala
igual sobre cualquier base Oracle.

---

## Decisiones de diseño

**Por qué `run` + `commit` y no un `Dockerfile`.** La base tiene que estar
levantada para correr `apexins.sql`, y un `RUN` de BuildKit no permite fijar
`--shm-size`: con los 64 MB por defecto la SGA no arranca. Con `run` + `commit`
se controlan memoria, `/dev/shm` y el apagado limpio de la instancia.

**Por qué ORDS va aparte.** APEX y ORDS tienen ciclos de release
independientes. Con ORDS fuera de la imagen, subir de versión es cambiar un tag
en `.env` en vez de rehornear 16 GB. Además la imagen oficial de Oracle ya
resuelve su propia instalación de esquema.

**Por qué versiones fijas y no `apex-latest.zip`.** Un build tiene que dar el
mismo resultado hoy y en seis meses. Oracle re-publica archivos con el
mismo nombre, así que el SHA256 fijado es la única defensa contra un cambio
silencioso.

**Por qué el tamaño de la imagen es alto (~16 GB).** Instalar APEX reescribe los
datafiles y el copy-on-write duplica varios GB en la capa nueva: medido, la base
son 11,6 GB y la capa de APEX agrega ~4,7 GB. Se puede aplanar con
`docker export | docker import`, pero hay que re-declarar a mano
`ENV`/`ENTRYPOINT`/`USER` con `--change`, y un error ahí produce una imagen que
no arranca.

Ojo con `docker image inspect --format '{{.Size}}'`: con el image store de
containerd devuelve el tamaño de los blobs (~3 GB), no lo que ocupa en disco.
El número que importa es el de `docker images`.

---

## Credenciales

Están **horneadas en la imagen** (`versions.env` → `BUILD_*`). Es un entorno
local desechable, no un servidor: la decisión es DELIBERADA, a cambio de que
`docker compose up` funcione sin pasos manuales.

### Cambiarlas

Se cambian en `versions.env`, **nunca en `.env`**: ese lo genera `build.sh` y si
lo editás a mano el build aborta por divergencia.

```bash
# Opción A — editar versions.env y correr ./build.sh. Sin fricción, pero
# la contraseña queda en el repo.

# Opción B — por entorno, para no versionarla:
BUILD_ORACLE_PASSWORD='...' BUILD_APEX_ADMIN_PASSWORD='...' ./build.sh
```

Con la opción B hay que exportar las variables **en cada corrida** de
`build.sh`: si las omitís, `versions.env` vuelve a sus defaults, el `.env` queda
divergente y el build corta indicando la línea. Para saltear ese chequeo,
`ALLOW_ENV_DRIFT=1 ./build.sh`.

Cualquiera de las dos exige rebuild: las contraseñas viven dentro de la imagen.

### Tres consecuencias

- No pongas ahí **ninguna contraseña** que uses en otro lado.
- Las contraseñas viajan a los `.sql` por sustitución de SQL*Plus, así que
  `build.sh` rechaza `&`, comillas, `\`, `$` y espacios: partirían el valor en
  dos y la imagen quedaría con una contraseña distinta de la documentada, sin
  error visible hasta el primer login.
- Las variables `ORACLE_PASSWORD` y `APP_USER` de la imagen base **ya no aplican**:
  solo actúan en la primera inicialización de la base, que se consumió durante el
  build. Para cambiar la contraseña después: `docker exec <db> resetPassword <nueva>`.

Las ACLs de red se otorgan con `host => '*'` (ver `sql/20_network_acl.sql`).
Es lo correcto en un **entorno local** aislado y lo incorrecto en cualquier otro
lado — no copiar ese script a un servidor compartido.

### Por qué los puertos escuchan solo en localhost

Como las credenciales son públicas y APEX corre sin HTTPS, el stack publica sus
puertos en `127.0.0.1` y no en `0.0.0.0`. Sin eso, cualquiera en tu red llega a
`system/<pass>@tu-ip:1521` y al Builder como `ADMIN` — en un coworking o la wifi
de un café eso es un problema real, no teórico.

Para abrirlo a propósito (mostrarle la app a alguien en la misma red):

```bash
sed -i 's/^BIND_ADDR=.*/BIND_ADDR=0.0.0.0/' .env && docker compose up -d
```

Y volvé a `127.0.0.1` cuando termines.

---

## Distribución

Este repo publica **la receta, no la imagen**. La imagen queda en el cache local
de Docker tras `./build.sh`.

Razones: 16 GB por versión son incómodos de subir y bajar; y aunque APEX y ORDS
se distribuyen bajo *Oracle Free Use Terms and Conditions* — que permite
redistribuir los programas **sin modificar**, sin cobrar y adjuntando la licencia —
una base de datos *con APEX ya instalado dentro* es discutiblemente un derivado,
no un binario sin modificar. Publicar la receta evita la discusión por completo.

Si en algún momento necesitás la imagen en varias máquinas, `ghcr.io` privado es
la opción: el almacenamiento del Container Registry es gratuito hoy (GitHub avisa
con un mes de anticipación si eso cambia). En ese caso, incluí el `LICENSE` del
FUTC en el repo.

---

## Problemas frecuentes

| Síntoma | Causa probable |
|---|---|
| `ORA-00845` o la base no arranca | Falta `shm_size: 2gb` / `--shm-size=2g` |
| APEX carga sin estilos, todo texto plano | El montaje de `./cache/apex` en ORDS no está o quedó vacío |
| `ORA-29273` (con `ORA-24247` adentro) desde tu propio PL/SQL | El build otorga ACLs a APEX, no al esquema de tu app. Receta en `init.example/README.md` |
| `ORA-24247` desde una REST Data Source de APEX | Faltan las ACLs del engine (`sql/20_network_acl.sql`) |
| `ORA-29024` / `ORA-28860` con un endpoint HTTPS | La ACL está, falta la cadena de certificados en el wallet |
| `ORA-28002` meses después | Contraseña expirada; el build lo previene con `PASSWORD_LIFE_TIME UNLIMITED` |
| El build falla al descargar APEX | Oracle cambió la URL o re-publicó el zip; verificar `APEX_URL` y el SHA256 |
| `docker compose up` tarda en el primer arranque | Se copian los datafiles (~4,5 GB) al volumen. Solo ocurre una vez por proyecto |

---

## Estado

**Validado end-to-end el 26/08/2026** sobre Docker 29.7.2 en WSL2 (Ubuntu 24.04):
build limpio en 6 m 58 s, APEX 26.1 `VALID` con 0 objetos inválidos, el Builder
sirviendo sus estáticos, correo cayendo en Mailpit y las ACLs de red
funcionando desde un esquema de aplicación.

El plan B de la imagen oficial sigue **sin ejercitar** es el perfil `oracle` de
`scripts/base-profile.sh`: es fallback, no el camino principal. Cuando lo
necesites, esperá tener que ajustar algún detalle.
