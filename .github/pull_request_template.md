## Qué cambia y por qué

<!-- El porqué importa más que el qué: el diff ya dice qué cambió. -->

## Cómo lo verificaste

<!-- Este repo tiene una regla escrita en docs/validacion-e2e.md: de los ocho
     bugs que destapó la primera corrida end-to-end, NINGUNO era detectable sin
     ejecutar. "Lo leí y está bien" no cuenta como verificación.
     Contá qué corriste y qué te devolvió. -->

## Antes de pedir review

- [ ] `shellcheck -x build.sh doctor.sh scripts/*.sh scripts/lib/*.sh` limpio
- [ ] `./scripts/test-doctor.sh` y `./scripts/test-roundtrip.sh` en verde
- [ ] `./doctor.sh --static` en verde

### Si agregaste un `.sh` ejecutable

- [ ] `git update-index --chmod=+x <archivo>`

> `core.fileMode` está en `false` en este repo: tu `chmod +x` **no llega al
> índice**. En tu máquina anda y en el clon no, que es la peor combinación para
> diagnosticar. Ya rompió CI dos veces. Lo vigila el chequeo `git-exec-bit`.

### Si tocaste SQL

- [ ] 100 % ASCII, también dentro de los heredocs de `scripts/install-apex.sh`

> No lo chequees a mano: lo hace `sql-ascii` y corre en CI.

### Si agregaste un chequeo a `doctor.sh`

- [ ] Tiene self-test en `scripts/test-doctor.sh`, con el caso sano **y** el roto
- [ ] Recibe por parámetro lo que necesita (rutas, sondas), para poder apuntarlo a un fixture
- [ ] Si su insumo puede no existir todavía, devuelve `[SKIP]` con el motivo, nunca `[FAIL]`
- [ ] Actualizaste el conteo de chequeos donde el README lo menciona
- [ ] Si cubre un síntoma conocido, tiene su fila en "Problemas frecuentes"

> Un chequeo que devuelve `[OK]` porque su `grep` está mal escrito es peor que
> no tenerlo: da confianza falsa.

### Si agregaste una variable de configuración

- [ ] Vive en **un solo** archivo

> Si sale de una versión o del perfil de imagen, va en `versions.env` y se suma a
> `DERIVED_KEYS`. Si varía por proyecto, va solo en `.env.example`. Duplicar un
> valor en dos archivos con un comentario "deben coincidir" es exactamente el
> patrón que se sacó de este repo.
