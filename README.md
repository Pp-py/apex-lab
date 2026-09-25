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
./doctor.sh             # ¿está todo sano? 29 chequeos, ninguno destructivo
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
doctor.sh                   entry point del diagnóstico
compose.yml                 stack: db + ords + mail
versions.env                única fuente de verdad de versiones y credenciales
.env.example                plantilla; build.sh genera el .env real
scripts/
├── base-profile.sh         convenciones por imagen base (se sourcea)
├── install-apex.sh         corre DENTRO del contenedor de build
├── apex-roundtrip.sh       valida el round-trip de una app APEXlang
├── test-doctor.sh          self-test de doctor.sh contra fixtures rotas
├── test-roundtrip.sh       self-test de los parsers de SQLcl
└── lib/                    chequeos compartidos por build.sh y doctor.sh
    ├── checks.sh           constantes + lo que build.sh también usa
    ├── checks-env.sh       chequeos estáticos
    ├── checks-runtime.sh   chequeos contra el stack levantado
    └── roundtrip.sh        etapas y parsers del round-trip
sql/
├── 10_apex_instance.sql    cuenta ADMIN, SMTP, parámetros de instancia
└── 20_network_acl.sql      ACLs de red del engine de APEX
init.example/               plantilla de semillas; build.sh siembra ./init (no versionado)
apps.example/               donde van las apps exportadas; ./apps no se versiona
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
# Ni doctor.sh ni apex-roundtrip.sh viajan solos: necesitan su scripts/lib/.
cp ~/apex-lab/compose.yml ~/apex-lab/.env ~/apex-lab/doctor.sh .
mkdir -p scripts && cp -r ~/apex-lab/scripts/lib scripts/
cp ~/apex-lab/scripts/apex-roundtrip.sh scripts/

# Los estáticos de APEX. compose los monta desde ./cache/apex, ruta RELATIVA a
# ESTE directorio: sin esto Docker crea el directorio vacío, lo monta igual y
# el Builder carga en texto plano.
ln -s ~/apex-lab/cache cache

# Semillas de este proyecto. Se les quita el sufijo o el entrypoint las ignora
# —solo ejecuta *.sh, *.sql, *.sql.zip y *.sql.gz— y el proyecto arrancaría sin
# workspace, sin esquema y sin ACL, sin un solo mensaje de error.
cp -r ~/apex-lab/init.example init
for f in init/*.example; do mv "$f" "${f%.example}"; done

sed -i 's/^COMPOSE_PROJECT_NAME=.*/COMPOSE_PROJECT_NAME=proyecto-x/' .env
sed -i 's/^DB_PORT=.*/DB_PORT=1522/;s/^ORDS_PORT=.*/ORDS_PORT=8081/;s/^MAILPIT_PORT=.*/MAILPIT_PORT=8026/' .env

./doctor.sh --static    # confirma que no falta nada ANTES de levantar
docker compose up -d
./doctor.sh             # y que todo quedó sano después
```

Cambiar los puertos permite tener varios proyectos corriendo en paralelo.
Para destruir el entorno completo: `docker compose down -v`.

Los dos pasos que parecen de más —el `ln -s` del cache y el renombrado de las
semillas— no lo son: sin ellos el proyecto arranca **y parece andar**, pero el
Builder sale sin estilos y la base sin workspace. Ninguno de los dos produce un
error. Por eso `./doctor.sh --static` va antes del primer `up`.

### Semillas del proyecto

Los `.sql` y `.sh` que dejes en `./init/` se ejecutan **como SYS, contra la CDB
y en CADA arranque del contenedor**, así que tienen que ser idempotentes.

No es un descuido: el entrypoint corre `initdb.d` solo cuando la base no existe,
y esta imagen ya la trae creada (`-faststart` + `docker commit`), así que ese
directorio se saltea siempre —incluso con un volumen recién creado—. Por eso las
semillas van a `startdb.d`. A cambio, cambiar el `.env` y reiniciar alcanza para
que tomen efecto: no hace falta destruir el volumen.

El workspace, el esquema y sus contraseñas salen del bloque `Semillas de ./init`
de tu `.env`, que es el único punto de seteo.

**`init/` no se versiona en este repo** (está en `.gitignore`): ahí viven el DDL,
los datos de prueba y las credenciales de cada proyecto, y no tienen por qué
viajar acá. Lo versionado es la plantilla `init.example/`, desde la cual
`./build.sh` siembra `init/` si no existe. Si un proyecto quiere versionar sus
semillas, que lo haga en el repo de ese proyecto.

En la plantilla también está la receta para otorgar la ACL de red al esquema de
tu aplicación, que el build **no** cubre: sin ella, cualquier llamada saliente
desde tu propio PL/SQL falla con `ORA-29273`.

→ [`init.example/README.md`](init.example/README.md)

### Apps exportadas

Las apps de APEX exportadas van en `./apps/`, una carpeta por app. **Tampoco se
versiona acá** (mismo criterio que `init/`): son el código de tu aplicación, no
del entorno, y arrastran los static files binarios, que no diffean.

El formato recomendado es **APEXlang** (`-exptype APEXLANG`): un DSL declarativo
con un archivo por componente, en vez de un único `f100.sql` de
`wwv_flow_api.create_*`. Cambiar el título de una página toca una línea y nada
más.

```bash
docker exec -i apexlab-ords bash -c '
  rm -rf /tmp/apexlang && mkdir -p /tmp/apexlang && cd /tmp/apexlang
  echo -e "apex export -applicationid 100 -exptype APEXLANG\nexit" \
    | sql -s $APP_SCHEMA/$APP_PASSWORD@db:1521/FREEPDB1'

mkdir -p apps && docker cp apexlab-ords:/tmp/apexlang/<alias> apps/<alias>
```

Ojo con un detalle que no se adivina: **SQLcl está en el contenedor de ORDS, no
en el de la base.** Y ahí la base se llama `db`, no `localhost`.

Que lo exportado **vuelva a entrar** lo comprueba
[`./scripts/apex-roundtrip.sh`](#round-trip-de-una-app-scriptsapex-roundtripsh).

→ [`apps.example/README.md`](apps.example/README.md)

---

## Diagnóstico: `./doctor.sh`

Todo lo que este README documenta como "problema frecuente" está también
ejecutable. `./doctor.sh` corre 29 chequeos y explica cada hallazgo:

```bash
./doctor.sh              # completo (necesita el stack levantado para 12 de ellos)
./doctor.sh --static     # solo lo que no necesita Docker; es lo que corre en CI
./doctor.sh --help       # incluye qué queda deliberadamente fuera y por qué
```

```
  [FAIL] init-exec-bit          Semillas sin bit de ejecucion: 01_workspace.sh.
         El entrypoint las SOURCEA en vez de ejecutarlas, y esa rama tiene un
         bug de upstream que les pasa el echo siguiente como argumento: el
         fallo es real pero ilegible.
         -> chmod +x init/*.sh

  16 OK   1 WARN   1 FAIL   0 SKIP
```

**No repara nada.** Imprime el comando y lo corrés vos: varias reparaciones acá
son destructivas —un `down -v` borra la base— y esa no es una decisión que deba
tomar una herramienta de diagnóstico.

Sale con **0** si está todo bien, **2** si hay avisos y **1** si hay algo roto.

Corre igual en este repo y en un directorio de proyecto. Allá no existen
`versions.env` ni `sql/`, así que los seis chequeos que dependen de eso se
reportan como `[SKIP]` **con el motivo, nunca como `[OK]`**: un chequeo que no
se pudo hacer no es un chequeo que pasó. Por la misma razón, un clon recién
hecho —sin `.env`, sin `init/`, sin `cache/`— sale 0 y no una pared de rojo.

Que los chequeos de verdad detecten lo que dicen lo verifica
`./scripts/test-doctor.sh`, que arma directorios rotos a propósito y comprueba
cada código de salida. Un chequeo que devuelve `[OK]` porque su `grep` está mal
escrito es peor que no tenerlo.

---

## Round-trip de una app: `./scripts/apex-roundtrip.sh`

Exportar una app a APEXlang es fácil de verificar a ojo; que vuelva a entrar,
no. Este script cierra el ciclo y lo deja ejecutable:

```
fuente .apx -> apex validate -> apex import -> app corriendo -> smoke test
```

```bash
./scripts/apex-roundtrip.sh              # genera la app de referencia y la prueba
./scripts/apex-roundtrip.sh apps/mi-app  # prueba un arbol APEXlang propio
./scripts/apex-roundtrip.sh --help       # opciones y codigos de salida
```

Sin argumentos usa la app que genera **el propio SQLcl** (`apex generate`), no
un fixture versionado: así el árbol siempre coincide con la versión de APEXlang
instalada en vez de quedar desactualizado en el próximo upgrade.

### Qué valida

| Etapa | Qué comprueba |
|---|---|
| **validate** | El APEXlang compila. Corre sin base |
| **import** | Entra en la instancia. Antes verifica que el ID destino no sea de otra app |
| **runtime** | APEX `VALID`, ORDS responde, y la fila de `apex_applications` tiene el alias, el workspace y el esquema de parseo pedidos |
| **fidelidad** | Las páginas y los static files que quedaron en la base coinciden —en cantidad y en nombre— con los del árbol de origen |
| **smoke** | La app se sirve de verdad: `f?p=<id>:1` devuelve HTML con el nombre de la app, y un static file suyo baja con su content-type |

**El código HTTP y el exit code no alcanzan, y esa es la razón de ser del
script.** Medido contra ORDS 26.1.2: `apex validate` sale con `0` aunque el
`.apx` no compile, `apex import` sale con `0` aunque no pueda ni conectar, y
una app a la que le falta la página de inicio responde **HTTP 200** con "Sorry,
this page isn't available". Por eso cada etapa exige una señal positiva —la
línea de éxito literal, el nombre de la app dentro del HTML— en vez de buscar
errores conocidos.

### Prerequisitos

El stack tiene que estar **levantado** (`db` y `ords`; Mailpit no hace falta).
Corre igual en este repo y en un directorio de proyecto, siempre que hayas
copiado `scripts/apex-roundtrip.sh` junto a `scripts/lib/` (está en la receta
de [Un proyecto nuevo](#un-proyecto-nuevo)).
El script no lo levanta ni lo baja, no borra apps y no toca el `.env`. Lo único
que escribe es la app destino y su directorio de evidencia.

Por defecto importa en el **ID 9000**, con el alias `APEXLAB-RT-9000` — el ID
va dentro del alias porque APEX exige alias único por workspace y **renombra
solo, sin avisar**, el que ya esté tomado. Si el ID destino lo ocupa una app
que no creó este script, **aborta**: `apex import` sobrescribe sin preguntar y
no hay deshacer. Para forzarlo, `--force`; para usar otro ID, `--id`.

### Evidencia

Queda en `artifacts/roundtrip/` (no se versiona):

```
summary.txt        PASS, o FAIL con la etapa que fallo
roundtrip.log      la transcripcion completa de la corrida
validate.log       salida cruda de apex validate
import.log         salida cruda de apex import
runtime.log        veredicto de cada chequeo de runtime
smoke-test.log     veredicto de cada peticion HTTP
app/               copia exacta del arbol que se valido e importo
app-response.html  lo que devolvio la app
```

Sale con **0** si pasó todo, y si no, con el número de la etapa: **1** validate,
**2** import, **3** runtime, **4** smoke test. `75` es un prerequisito sin
cumplir (stack abajo, o el ID destino es de otra app).

### Limitaciones

- **No re-exporta para diffear contra el origen.** `generate` y `export`
  normalizan distinto y el diff sería ruido. La fidelidad se mide contra el
  diccionario de datos, que no depende del formato del texto.
- **No inicia sesión.** Verifica que la app se sirve, no que un usuario pueda
  operarla: eso necesitaría credenciales y dejaría de ser determinista.
- **Atado a la versión de APEXlang del SQLcl instalado.** Un `.apx` exportado
  con otra versión puede no validar; es una propiedad del formato.
- El round-trip completo **no corre en CI** (necesita la base). Sí corren el
  self-test de los parsers y la etapa `validate` contra el SQLcl real.

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
   líneas exactas a corregir (`DB_HEALTHCHECK_CMD`, `DB_SEED_DIR`).
   Corregilas y volvé a correr.

| | `gvenzl` | `oracle` |
|---|---|---|
| Contraseña | `ORACLE_PASSWORD` | `ORACLE_PWD` |
| Healthcheck | `healthcheck.sh` | `/opt/oracle/checkDBStatus.sh` |
| Semillas (`DB_SEED_DIR`) | `/container-entrypoint-startdb.d` | `/opt/oracle/scripts/startup` |
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

La última columna es el chequeo de `./doctor.sh` que lo detecta. Mantenerla es
lo que hace visible la deriva entre esta tabla y la herramienta: una fila sin
chequeo es una oportunidad, y un chequeo sin fila es documentación que falta.

| Síntoma | Causa probable | Lo detecta |
|---|---|---|
| `ORA-00845` o la base no arranca | Falta `shm_size: 2gb` / `--shm-size=2g` | `compose-shm`, `db-shm-runtime` |
| APEX carga sin estilos, todo texto plano | El montaje de `./cache/apex` en ORDS no está o quedó vacío | `ords-static-mount`, `ords-statics-http` |
| `ORA-29273` (con `ORA-24247` adentro) desde tu propio PL/SQL | El build otorga ACLs a APEX, no al esquema de tu app. Receta en `init.example/README.md` | `app-acl` |
| `ORA-24247` desde una REST Data Source de APEX | Faltan las ACLs del engine (`sql/20_network_acl.sql`) | `engine-acl` |
| `ORA-29024` / `ORA-28860` con un endpoint HTTPS | La ACL está, falta la cadena de certificados en el wallet | — (depende del endpoint) |
| `ORA-28002` meses después | Contraseña expirada; el build lo previene con `PASSWORD_LIFE_TIME UNLIMITED` | `account-expiry` |
| El build falla al descargar APEX | Oracle cambió la URL o re-publicó el zip; verificar `APEX_URL` y el SHA256 | `apex-sha` |
| Las semillas de `init/` no tuvieron efecto | Quedaron con el sufijo `.example`, o sin `+x`, o montadas en `initdb.d` | `init-inert-example`, `init-exec-bit`, `seed-dir-mount`, `init-ran` |
| La base abre pero le falta el `datapatch` | Subiste la versión conservando el volumen: datafiles viejos bajo binarios nuevos | `datapatch-pending` |
| Un `.sh` del repo llega sin permiso de ejecución al clonar | `core.fileMode=false`: el `chmod +x` local nunca llegó al índice de git | `git-exec-bit` |
| Una app importada de APEXlang no abre, o abre sin sus imágenes | El import dijo `Import successful.` igual: APEX devuelve 200 con "Sorry, this page isn't available" | `./scripts/apex-roundtrip.sh` |
| `docker compose up` tarda en el primer arranque | Se copian los datafiles (~4,5 GB) al volumen. Solo ocurre una vez por proyecto | — (es normal) |

---

## Estado

**Validado end-to-end el 26/08/2026** sobre Docker 29.7.2 en WSL2 (Ubuntu 24.04):
build limpio en 6 m 58 s, APEX 26.1 `VALID` con 0 objetos inválidos, el Builder
sirviendo sus estáticos, correo cayendo en Mailpit y las ACLs de red
funcionando desde un esquema de aplicación.

**Revalidado el 03/09/2026** al subir la base a 23.26.3: la corrida pasó
completa y sin bugs nuevos. Detalle en
[`docs/validacion-e2e.md`](docs/validacion-e2e.md). Tené en cuenta que subir la
versión de la base **obliga a `docker compose down -v`**: el volumen guarda los
datafiles de la versión anterior y el faststart solo los copia cuando está
vacío, así que conservarlo deja binarios nuevos sobre datafiles viejos.

El plan B de la imagen oficial sigue **sin ejercitar** es el perfil `oracle` de
`scripts/base-profile.sh`: es fallback, no el camino principal. Cuando lo
necesites, esperá tener que ajustar algún detalle.
