# `apps.example/` — dónde van las apps de APEX exportadas

Esto es la **plantilla versionada**. Las apps exportadas van en `./apps/`, que
**no se versiona** (está en `.gitignore`), por el mismo criterio que `init/`: son
el código de *tu* aplicación, no del entorno, y además arrastran los static files
binarios, que no diffean. Si una app tiene que versionarse, va en el repo de esa
app.

```
apps/
└── ux-pattern-catalog/           <- una carpeta por app, con el alias de la app
    ├── .apex/apexlang.json       metadatos del export (mmdVersion)
    ├── application.apx           la app: nombre, tema, navegación, seguridad
    ├── page-groups.apx
    ├── deployments/default.json  mapea el export a un application_id
    ├── pages/
    │   ├── p00000-global-page.apx
    │   ├── p00001-home.apx
    │   └── p00110-dashboard-simple.apx
    └── shared-components/
        ├── authentications.apx   authorizations, breadcrumbs, lists, lovs...
        ├── static-files.apx      + los binarios en static-files/
        └── themes/universal-theme/theme.apx
```

## Exportar

**SQLcl no está en el contenedor de la base**, está en el de ORDS
(`/usr/bin/sql`, con su propio GraalVM). El export corre ahí y se trae con
`docker cp`:

```bash
APP_ID=100
ALIAS=ux-pattern-catalog        # el nombre de carpeta que genera el export

docker exec -i apexlab-ords bash -c "
  rm -rf /tmp/apexlang && mkdir -p /tmp/apexlang && cd /tmp/apexlang
  echo -e 'apex export -applicationid ${APP_ID} -exptype APEXLANG\nexit' \
    | sql -s \$APP_SCHEMA/\$APP_PASSWORD@db:1521/FREEPDB1"

mkdir -p apps && docker cp apexlab-ords:/tmp/apexlang/${ALIAS} apps/${ALIAS}
```

Dentro del contenedor de ORDS la base se llama `db` (el nombre del servicio en
compose), no `localhost`.

## Por qué APEXlang y no un `f100.sql`

`-exptype APEXLANG` produce un DSL declarativo, un archivo por componente, en
vez de un único script de `wwv_flow_api.create_*`. Diffea de verdad: cambiar el
título de una página toca una línea de `pages/p00110-*.apx` y nada más.

Los otros `-exptype` de SQLcl, por si alguno encaja mejor:

| Valor | Para qué |
|---|---|
| `APEXLANG` | DSL legible, un archivo por componente. El más apto para git. |
| `READABLE_YAML` / `READABLE_JSON` | Misma idea, en YAML o JSON. |
| `APPLICATION_SOURCE` | El clásico `f100.sql` instalable. El default. |
| `EMBEDDED_CODE` | Solo el SQL, PL/SQL y JavaScript embebido. Útil para auditar. |
| `CHECKSUM-SH256` | Checksum independiente de los IDs, para detectar cambios. |

Un `apex export -applicationid 100 -split` también parte el `f100.sql` en varios
archivos, pero sigue siendo SQL generado, no legible.

## Al importar en otro entorno

Los IDs de aplicación, de workspace y de esquema son del entorno de origen. Al
llevar la app a otra base hay que revisar que el workspace destino exista y que
el esquema de parseo coincida, o reasignarlo en la importación. En este lab el
esquema y el workspace salen del `.env` (`APP_SCHEMA`, `APP_WORKSPACE`), así que
lo normal es que coincidan si no los cambiaste.

**Sin verificar en este entorno:** el round-trip. La app 100 se exportó y se
inspeccionó, pero no se re-importó, porque importar sobre el mismo ID sobrescribe
la app. Si lo probás, hacelo con un ID distinto.
