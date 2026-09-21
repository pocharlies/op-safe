Necesito que instales en este Mac la capa de fiabilidad ya empaquetada para el CLI de
1Password (`op`), para que nunca me salte un prompt de Touch ID a destiempo ni se me
cuelguen los comandos.

Esto ya está diagnosticado, resuelto y empaquetado en un repo público:

  https://github.com/pocharlies/op-safe

NO re-investigues las causas ni intentes automatizar la GUI de 1Password: te paso el
diagnóstico cerrado y la solución verificada. Tu trabajo es clonar el repo, instalarlo
con su `install.sh`, y verificar que funciona en esta máquina.

## Contexto: los dos fallos reales

**FALLO 1 — bombardeo (el más frecuente).** 1Password **serializa** las peticiones de
autorización. Si lanzas varias llamadas `op` concurrentes o en ráfaga (p.ej. un
`for i in 1 2 3 4 5; do op ...; done`), se encolan, se atascan y se auto-cancelan,
dejándome un prompt de Touch ID colgado en pantalla y devolviendo errores. Firma en el
log de la app:

```
WARN  AppCancel invoked by a timed-out prompt due to serialized queue delay
WARN  System unlock failed: SystemAuthError(FailedSystemAuthenticationChallenge)
ERROR NoNewAccountsUnlocked
```

**FALLO 2 — app zombi tras auto-update.** Cuando 1Password se auto-actualiza, el proceso
principal queda vivo pero sordo, con los flags `--silent --just-updated --should-restart`.
El socket existe pero nadie responde al otro lado, así que `op` da
`[ERROR] authorization timeout` (y el prompt de huella ni siquiera llega a dibujarse,
porque lo dibuja la app, que está colgada). Se arregla reiniciando la app.

**FALLO 3 — ciclo de bloqueo (diseño, no bug).** 1Password se bloquea cuando la pantalla
duerme y se auto-desbloquea al desbloquear el Mac (`Device-based Unlock`), sin pedir
huella aparte para esa parte. No es un fallo, pero explica cuándo se manifiestan los
otros dos. Detalle completo, con los dos ciclos medidos, en el README del repo.

## Callejones sin salida ya explorados — NO los reintentes

- **`settings.json` no es editable a mano.** Está en
  `~/Library/Group Containers/2BUA8C4S2C.com.1password/Library/Application Support/1Password/Data/settings/settings.json`.
  Cada clave lleva un HMAC en el objeto `authTags`; escribirlo invalida la firma.
  Léelo si quieres diagnosticar, pero no lo modifiques.
- **La UI de ajustes de 1Password 8 no expone árbol de accesibilidad** (solo `AXGroup`
  vacíos). No se puede automatizar con osascript/System Events, ni con
  `AXEnhancedUserInterface` ni con `AXManualAccessibility`. Camino cerrado.
- **`security.autolock.minutes = -1` significa "nunca"**, no "sin configurar". Si ves ese
  valor, el autolock NO es el problema.
- **`op whoami` no sirve como health check** con integración de app de escritorio: devuelve
  siempre `account is not signed in` porque el CLI no tiene sesión propia, la delega en la
  app. Es un falso negativo. **Usa `op vault list`** para comprobar salud.
- **Service Account no es opción** si la cuenta es corporativa y no eres admin del tenant.

## Fuente de verdad para diagnosticar

`~/Library/Group Containers/2BUA8C4S2C.com.1password/Library/Application Support/1Password/Data/logs/1Password_rCURRENT.log`

Si muestra líneas `Server session extension succeeded for account: ...`, la app está
desbloqueada y el problema es otro (probablemente el FALLO 1).

## ⚠️ REGLA CRÍTICA MIENTRAS TRABAJAS

Estoy físicamente delante del Mac y **cada llamada a `op` (incluida `op-safe`) puede
dispararme un prompt de Touch ID**. Por tanto:

- **NUNCA** lances `op` ni `op-safe` en bucle ni en paralelo.
- Deja **mínimo 5 segundos** entre llamadas.
- Usa **como máximo 4 llamadas a `op`/`op-safe`** en toda la tarea.
- No uses `op whoami` (falso negativo conocido).

Si incumples esto me provocas exactamente el fallo que vienes a arreglar.

## Instalación (clona el repo, no pegues los scripts a mano)

```bash
git clone git@github.com:pocharlies/op-safe.git ~/Workspace/op-safe   # o donde prefieras
cd ~/Workspace/op-safe
./install.sh
```

Esto instala `op-safe` y `1password-bridge-heal.sh` en `~/.claude/bin` (usa
`./install.sh --prefix ~/.local/bin` para otra ruta), genera el LaunchAgent para tu
usuario a partir de la plantilla en `launchagents/`, lo instala en
`~/Library/LaunchAgents/` y lo carga con `launchctl bootstrap`. `install.sh` es
idempotente (se puede re-ejecutar sin duplicar el agente) y **no llama a `op` en ningún
momento**.

Si esta máquina necesita algún ajuste sobre los scripts ya instalados (p.ej. `op` vive en
una ruta de PATH distinta — el wrapper lo invoca por PATH, así que normalmente no hace
falta tocar nada), edítalos en el prefix de instalación, no en el repo clonado, salvo que
también quieras proponer el cambio de vuelta al repo.

## Cuenta por defecto (solo si hay más de una)

Si `op account list` devuelve más de una cuenta, exporta la de trabajo en `~/.zshrc`
(con backup previo del fichero):

```bash
export OP_ACCOUNT=<USER_ID_de_la_cuenta>
```

Aviso: esto **no** arregla `op whoami`, que seguirá fallando. Solo quita la ambigüedad
para el resto de subcomandos.

## Verificación (con salida literal, respetando el límite de 4 llamadas a op/op-safe)

1. `bash -n` sobre los dos scripts instalados (o `shellcheck` si está disponible).
2. `~/.claude/bin/op-safe vault list` → lista de vaults, exit 0. *(1 llamada)*
3. Prueba del lock, que es lo que de verdad importa:
   ```bash
   ( ~/.claude/bin/op-safe vault list >/dev/null 2>&1 & ~/.claude/bin/op-safe vault list >/dev/null 2>&1 & wait )
   ```
   Confirma **por el log** (`~/.claude/logs/op-safe.log`) que se ejecutaron en serie
   (timestamps que no se solapan) y que ambas dieron `exit=0`. *(2 llamadas)*
4. Comprueba que el dir de lock (`${TMPDIR:-/tmp}/.op-safe.lock`) **no existe** al terminar.
5. `launchctl list | grep 1password-bridge` → agente cargado.
6. `plutil -p ~/Library/LaunchAgents/com.<tuusuario>.1password-bridge-watchdog.plist` →
   aparece `WatchPaths`, no aparece `StartInterval`.
7. `cat ~/.claude/logs/op-safe.log` → ningún secreto.

## Criterios de aceptación

- [ ] Repo clonado, `./install.sh` corrido sin llamar a `op`
- [ ] `op-safe` y `1password-bridge-heal.sh` instalados, ejecutables, `bash -n` limpio
- [ ] `op-safe vault list` devuelve los vaults con exit 0
- [ ] Dos invocaciones simultáneas se serializan (evidencia: timestamps del log)
- [ ] El lock se libera siempre
- [ ] LaunchAgent cargado, con `WatchPaths` y sin `StartInterval`
- [ ] El log no contiene ningún secreto

Devuelve el checklist con `[x]`/`[blocked]` y la salida literal de las verificaciones.

## Al terminar

Guárdame en memoria durable, como GOTCHA: que en este Mac hay que usar
`~/.claude/bin/op-safe` en vez de `op` a secas, que **nunca** se llama a `op`/`op-safe`
en ráfaga porque se serializa y cuelga el prompt, que `op whoami` es un falso negativo
(usar `op vault list`), y que ante `authorization timeout` hay que mirar si el proceso
lleva `--just-updated`.
