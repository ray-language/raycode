<h1 align="center">raycode</h1>

<p align="center">
  Un agente de terminal escrito <b>enteramente en raylang</b>.<br>
  Arranca en <b>5 ms</b>, cabe en un binario de <b>3 MB</b> sin nada alrededor,
  y habla igual con <b>llama.cpp</b> local que con <b>OpenAI</b> o <b>Anthropic</b>.
</p>

```
$ raycode
raycode · a raylang harness for local and remote models
────────────────────────────────────────────────────────────────
profile  llama (openai-compatible)
endpoint http://127.0.0.1:8080/v1/chat/completions
model    local-model
served   qwen2.5-coder-7b-instruct · ctx 32.8k
sampling max_tokens 4096 · temperature 0.20 · max_steps 12 · streaming
workspace /Users/roberto/Dev/mi-proyecto
tools    read_file, write_file, list_dir
         run_command is off; start with --allow-exec to enable the shell
────────────────────────────────────────────────────────────────
/help for commands · Ctrl-D to quit

› resume qué hace este repo y dónde está el bucle principal
⠙ thinking · step 2 · esc to stop 1.4s
```

---

## Instalación

Una orden, sin dependencias, sin toolchain:

```sh
curl -sSfL https://raw.githubusercontent.com/ray-language/raycode/main/install.sh | sh
```

Detecta la plataforma, se trae el binario de la última GitHub Release, comprueba su
SHA-256 y lo deja en `~/.local/bin/raycode`. Se puede afinar con variables de entorno:

| Variable | Para qué |
|---|---|
| `RAYCODE_VERSION` | instalar un tag concreto (`v0.1.0`) en vez del último |
| `RAYCODE_BIN_DIR` | directorio de instalación (por defecto `~/.local/bin`) |
| `RAYCODE_REPO` | otro `owner/repo` del que descargar |
| `RAYCODE_DRY_RUN` | imprime el plan y no descarga nada |

```sh
RAYCODE_VERSION=v0.1.0 RAYCODE_BIN_DIR=/usr/local/bin ./install.sh
```

Se publica para **Linux** y **macOS**, en x86-64 y arm64. En Windows va por WSL: el
editor de línea entra al terminal a través de `std/term`/`std/io`, que son Unix por debajo.

### Desde el código

Con el toolchain de [raylang](https://github.com/ray-language/raylang) instalado y el
paquete `net` en su sitio (`../../raylang/packages/net`, como declara `ray.toml`):

```sh
ray build --native main.ray -o bin/raycode --release   # binario de código máquina
ln -sf "$PWD/bin/raycode" ~/.local/bin/raycode         # una vez
```

Hay que reconstruirlo tras cada cambio. Para probar sin reconstruir está
`bin/raycode-dev`, que ejecuta el fuente con `ray run` (28 ms) desde cualquier
directorio: como `ray run` resuelve las dependencias contra el directorio actual y no
contra el proyecto del archivo, el lanzador se coloca en el proyecto y manda el
directorio del usuario en `RAYCODE_WORKSPACE` — el **espacio de trabajo**, que el
banner muestra cuando no coincide con el del proceso.

Iterando sobre el propio harness, `ray dev` releva al ciclo de reconstruir a mano:

```sh
ray dev main.ray                       # relanza el REPL al guardar un .ray
RAYCODE_WORKSPACE=~/otro ray dev main.ray
```

Vigila los fuentes del proyecto (`.ray`, `.ray.html`, `ray.toml`) por sondeo de mtimes,
**compila antes de reiniciar** —un cambio a medio escribir imprime su diagnóstico y deja
en marcha el proceso anterior— y agrupa una ráfaga de guardados en un solo reinicio. No
es *hot reload*: es reinicio (SIGTERM al hijo), solo que con el arranque en milisegundos
el ciclo editar→ver son decenas de ms. Para un REPL eso significa que **cada reinicio se
lleva la conversación en curso**, así que vale para trabajar en `render`, `lineedit` o
`tools`, no para conversar. Y como `ray dev` se lanza desde el proyecto, el espacio de
trabajo es el propio raycode salvo que pases `RAYCODE_WORKSPACE`: eso es justo lo que
`bin/raycode-dev` automatiza para el uso normal desde otro directorio.

## Uso

```
raycode                                            # desde cualquier directorio
ray run                                            # llama.cpp en 127.0.0.1:8080
ray run main.ray -p anthropic                      # API de Anthropic
ray run main.ray -p openai -m gpt-4o-mini          # API de OpenAI
ray run main.ray --allow-exec "resume este repo"   # una sola petición, con shell
ray test                                           # las pruebas del harness
raycode --help                                     # banderas, entorno y ejemplos
```

Un turno del usuario dispara un bucle de herramientas hasta que el modelo responde;
cada petición se cronometra y se contabiliza. El binario no necesita nada alrededor
—ni el proyecto, ni las dependencias, ni el intérprete— y trabaja sobre el directorio
desde el que se invoca, que es lo que se quiere de un agente: `read_file`,
`write_file`, `list_dir`, `run_command` y el Tab operan ahí. Con un `.raycode/mcp.json`
se suman las herramientas de cualquier [servidor MCP](#servidores-mcp).

## Qué hace

- **Tres perfiles, un bucle.** `llama` y `openai` hablan `POST /v1/chat/completions`;
  `anthropic` habla `POST /v1/messages` con bloques de contenido. El agente no sabe
  con cuál está hablando: los adaptadores traducen desde y hacia el modelo canónico
  de `src/message.ray`.
- **Respuesta en directo.** Con `stream: true` el texto se pinta según llega, por
  bloques (y si el endpoint ignora el streaming y contesta un JSON normal, se lee como
  respuesta suelta en vez de quedarse en blanco): en cuanto un bloque cierra (una línea en blanco fuera de una cerca) ya es
  un documento completo y se renderiza. El indicador de actividad dura hasta el
  primer token. Se apaga al arrancar con `--no-stream` (o `RAYCODE_STREAM=off`).
- **Markdown en la respuesta.** El AST viene de `std/markdown` y aquí se pinta:
  negritas, cursivas, `código`, títulos, listas (anidadas y ordenadas), citas,
  reglas, enlaces, imágenes, **tablas GFM con su alineación** y bloques cercados
  (verbatim, enmarcados), repartido por palabras al ancho de la ventana.
  Además fija el ritmo vertical: una línea en blanco alrededor de lo que abre
  sección —títulos, reglas, bloques de código, tablas—, nunca dos seguidas y
  ninguna en los bordes; y cada bloque del turno (herramienta, respuesta, uso)
  queda separado del siguiente. Sin color, las marcas simplemente desaparecen.
- **Actividad a la vista.** Mientras el modelo piensa y mientras una herramienta
  trabaja se dibuja un indicador con el tiempo transcurrido (`⠙ thinking · step 2
  1.4s`). Lo anima una fibra aparte: funciona porque la petición HTTP y el drenado
  del proceso **aparcan** la fibra que espera. Sin terminal no se dibuja nada, así
  que la salida por tubería sigue limpia.
- **Herramientas.** `read_file`, `write_file` y `list_dir` siempre; `run_command`
  solo con `--allow-exec` (se ejecuta en streaming, con su plazo compuesto a mano:
  una fibra guardiana mata el grupo de proceso al vencer `timeout_ms`). Cada fallo — herramienta desconocida, argumentos rotos,
  error de E/S, `panic` — vuelve al modelo como texto para que se corrija, nunca
  tumba la sesión.
- **Respuestas cortadas, dichas.** Si el proveedor corta la respuesta por el tope de
  tokens (`length` en OpenAI, `max_tokens` en Anthropic) el harness lo avisa en vez de
  dejar una frase a medias que parece completa. El tope por defecto es 4096 y se sube
  en caliente con `/set max-tokens N` (o `RAYCODE_MAX_TOKENS`). El cuerpo HTTP en sí
  no tiene tope: se lee hasta EOF.
- **Uso a la vista.** Cada turno cierra con tokens de entrada/salida, lecturas de
  caché, número de peticiones, latencia y tokens/s; `/usage` da el acumulado y una
  línea `counts` que dice de dónde salen las cifras. Un endpoint que no devuelve
  `usage` no se muestra como cero: el harness cuenta en local (~4 caracteres por
  token) y marca el resultado con `≈`.
- **Modelo a la vista.** Al arrancar se interroga al endpoint (`/props` de
  llama.cpp, `/v1/models/{id}` de OpenAI y Anthropic, y el catálogo `GET /v1/models`
  como respaldo) para mostrar qué hay cargado de verdad y con qué ventana de
  contexto. `/model` lista lo que ofrece el servidor —el sobre de OpenAI, un arreglo
  pelado o `{"models":[…]}`— y `/model <id>` cambia sin perder el hilo.
- **Bloques verbatim.** En el protocolo Anthropic los bloques del asistente se
  reenvían tal cual llegaron, así los bloques de razonamiento firmados sobreviven
  al bucle de herramientas.

## Edición de línea y autocompletado

El REPL trae su propio editor de línea (`src/lineedit.ray`), porque `input()` solo lee
líneas enteras y nunca ve un Tab ni una flecha. El modo crudo del terminal y la lectura
byte a byte con plazo salen de `std/term` y `std/io` (`term.raw`, `term.decode`,
`io.read_timeout`), que envuelven la libc por debajo.

| Tecla | Qué hace |
|---|---|
| `Tab` | completa: órdenes de barra en primera posición, rutas de archivo en cualquier otra |
| `↑` / `↓` | historial, persistido entre sesiones en `~/.raycode_history` (`RAYCODE_HISTORY`) |
| `←` / `→`, `Inicio`/`Fin` | mover el cursor (también `Ctrl-B`/`Ctrl-F`, `Ctrl-A`/`Ctrl-E`) |
| `Ctrl-U` / `Ctrl-K` / `Ctrl-W` | borrar hasta el principio / hasta el final / la palabra anterior |
| `Ctrl-L` | limpiar la pantalla |
| `Ctrl-C` | abandonar la línea en curso (no la sesión) |
| `Ctrl-D` | salir con la línea vacía; borrar el carácter bajo el cursor si no lo está |

La ventana puede cambiar de tamaño a mitad de escritura: mientras espera teclas, el
editor se despierta cada 250 ms, y si el ancho cambió repinta al nuevo. No hace falta
`SIGWINCH`: la espera de tecla ya tiene plazo, y el ancho se pregunta a `term.size()`.

La línea puede ser más ancha que el terminal: el repintado sube al principio del
bloque, borra de ahí hacia abajo y lo pinta entero, así que editar en medio de una
línea envuelta coloca el cursor donde toca. El ancho se pregunta a `term.size()`
(`std/term`), con 80 como último recurso cuando no hay terminal que responda.

Con Tab, un único candidato se inserta entero (los directorios acaban en `/` para poder
seguir bajando); varios candidatos insertan el prefijo común y, si no hay nada que
insertar, se listan. Una barra en primera posición que no case ninguna orden se trata
como ruta absoluta, así que `/tm`+Tab da `/tmp/`.

Sin terminal —una tubería, `ray test`, stdin redirigido— el editor se apaga solo y se
vuelve a `input()`: el harness sigue siendo guionizable. `std/term` es Unix por debajo;
en otras plataformas se cae al mismo camino. Si el proceso muere de forma anómala mientras editas
(un `kill` externo), el terminal puede quedar en modo crudo: `reset` lo devuelve a su
sitio.

## El terminal, siempre en su sitio

El modo crudo lo pone y lo quita `std/term.raw`, que restaura el estado anterior pase
lo que pase dentro —incluido un panic— y también al salir el proceso. Eso cierra de
raíz la clase de fallo en la que una sesión muerta en modo crudo envenena a las
siguientes (sin post-proceso de salida, un `\n` deja de devolver el carro y **toda**
la salida sale en escalera).

En modo crudo el terminal no traduce nada, así que la salida del turno devuelve el
carro a mano, también en los saltos de dentro de un bloque.

## Parar un turno

`ESC` (o `Ctrl-C`) detiene lo que esté ocurriendo: la petición al modelo o la
herramienta en marcha. El turno acaba ahí y vuelve el prompt.

Para que la tecla llegue en el momento, el terminal se pone en modo crudo durante
todo el turno —si no, `ESC` se quedaría en el búfer de línea hasta el siguiente
Enter— y una fibra la sondea con `io.read_timeout` mientras otra hace el trabajo. Lo que se
abandona sigue vivo hasta que termine solo: una petición HTTP en vuelo se descarta al
llegar, y un mandato de shell sigue corriendo hasta su propio `timeout_ms`.

Lo que **no** se abandona es la conversación: si el corte pilla una herramienta a
medias, sus llamadas se cierran con un resultado sintético (`stopped by the user`),
porque un `tool_use` sin su `tool_result` invalida el historial para el siguiente
turno. El modelo, además, se entera de que le pararon.

Mientras el turno trabaja, las teclas que se escriban se descartan: no hay
escritura por adelantado.

## Órdenes del REPL

| Orden | Qué hace |
|---|---|
| `/help` | la lista de órdenes |
| `/usage` | tokens, peticiones y latencia de la sesión |
| `/model` | el modelo en uso y el catálogo del endpoint (`GET /v1/models`), con el actual marcado |
| `/model <id>` | cambia de modelo en caliente, conservando la conversación |
| `/tools` | las herramientas expuestas al modelo, con su origen |
| `/mcp` | los servidores MCP: mandato, herramientas y último error |
| `/mcp reload` | vuelve a descubrir los servidores MCP, conservando la conversación |
| `/set [clave valor]` | mandos en caliente: `max-tokens`, `temperature`, `max-steps`, `timeout-ms` (sin argumentos, los muestra junto a `stream`) |
| `/system <texto>` | reemplaza el prompt de sistema (vacío: lo muestra) |
| `/reset` | olvida la conversación, conserva los totales |
| `/verbose` | traza peticiones y respuestas en stderr |
| `/exit` (o `/quit`) | salir (igual que Ctrl-D) |
| `ESC` | detiene el turno en marcha (el modelo o su herramienta) |

## Servidores MCP

Las herramientas de un servidor [MCP](https://modelcontextprotocol.io) entran en el
catálogo junto a `read_file` y compañía, sin que el bucle del agente distinga unas de
otras. Se declaran en `.raycode/mcp.json` del espacio de trabajo (o, si no existe, en
`~/.raycode/mcp.json`) con el mismo sobre que Claude Code y Claude Desktop, así que un
bloque se puede copiar tal cual:

```json
{
  "mcpServers": {
    "raylang": { "command": "ray", "args": ["mcp"] }
  }
}
```

Campos por servidor: `command`, `args`, `env`, `dir` (relativo al espacio de trabajo)
y `disabled`. Cada herramienta se expone al modelo como `mcp__<servidor>__<tool>`
—`mcp__raylang__ray_check`—, así que no hay colisiones y el origen se lee en la traza.

```
tools    read_file, write_file, list_dir
         run_command is off; start with --allow-exec to enable the shell
mcp      raylang · ray mcp · 5 tools
```

**Opt-in por construcción**: sin archivo no hay servidores. Un servidor MCP es un
programa arbitrario que se lanza en nombre del usuario, y por eso el banner dice cuál,
con qué mandato y qué aportó. Un servidor que no arranca, que tarda más de 5 s o que
contesta basura no tumba nada: se marca en rojo con la causa, la sesión sigue con el
resto y `/mcp reload` reinicia todos los servidores sin perder la conversación.

El transporte es **stdio, una sesión por servidor**: cada servidor se lanza una vez al
abrir la sesión, con su stdin abierto (`stdin_pipe` de `std/process`), recibe el apretón
de manos (`initialize`, `initialized`) y desde ahí cada `tools/call` es una línea JSON-RPC
que espera su respuesta por `id`. El proceso lo posee una sola fibra —un actor por
servidor— y el resto del harness le habla por canal, que es lo que permite que la llamada
salga desde la fibra que atiende cada paso. Vale por tanto para servidores con estado, y
el arranque se paga una vez: una llamada a `ray mcp` cuesta unos 20 ms. Una llamada tiene
60 s; si el servidor no contesta se mata, el modelo recibe el error, y la siguiente
petición lo relanza —lo mismo si muere por su cuenta. Al salir, raycode cierra el stdin
de cada servidor y espera a que termine (a la fuerza tras 2 s). Las `instructions` que
un servidor declara en `initialize` se añaden al prompt de sistema, etiquetadas con su
nombre (`/system` muestra solo la parte del usuario; `/mcp` enseña las del servidor).
Los resultados llegan al modelo como texto: los bloques `text` tal cual, los demás
resumidos (`[image 12 KiB]`), e `isError` por el mismo camino que cualquier fallo de
herramienta —error legible, nunca un panic.

Con `ray mcp` el bucle es el de escribir raylang y verificarlo en el mismo turno:

```
› escribe en fib.ray una función fib(n) y comprueba que compila
⚙ write_file {"path":"fib.ray","content":"fn fib(n: int) -> int { ..."}
  │ wrote 118 bytes to fib.ray
⚙ mcp__raylang__ray_check {"path":"fib.ray"}
  │ exit: 0
  │ ok: 'fib.ray' compiles
```

Banderas: `--mcp-config <ruta>` fuerza un archivo concreto y `--no-mcp` apaga todo;
entorno: `RAYCODE_MCP_CONFIG` y `RAYCODE_MCP=off`.

## Configuración

Banderas: `-p/--provider`, `-u/--base-url`, `-m/--model`, `-k/--api-key`,
`-s/--system`, `--max-tokens`, `-t/--temperature`, `--timeout-ms`, `--max-steps`,
`--no-stream`, `--allow-exec`, `--mcp-config`, `--no-mcp`, `-v/--verbose`,
`-h/--help`. Lo que sobre en la línea de órdenes es la petición de un solo turno.

Entorno: `RAYCODE_PROFILE`, `RAYCODE_BASE_URL`, `RAYCODE_MODEL`, `RAYCODE_API_KEY`,
`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `RAYCODE_SYSTEM`, `RAYCODE_MAX_TOKENS`,
`RAYCODE_TEMPERATURE`, `RAYCODE_MAX_STEPS`, `RAYCODE_TIMEOUT_MS`, `RAYCODE_STREAM`,
`RAYCODE_MCP_CONFIG`, `RAYCODE_MCP`, `NO_COLOR` (o `RAYCODE_NO_COLOR`).

## Estructura

| Archivo | Qué vive ahí |
|---|---|
| `main.ray` | banner, REPL, órdenes de barra, modo de un solo turno |
| `src/lineedit.ray` | editor de línea: historial, edición y autocompletado con Tab |
| `src/spinner.ray` | el indicador de actividad, dibujado por una fibra mientras la otra espera |
| `src/render.ray` | el AST de `std/markdown` pintado: tema ANSI, tablas, reparto y ritmo |
| `bin/raycode` | el binario nativo instalado (se reconstruye con `ray build --native`) |
| `bin/raycode-dev` | lanzador de desarrollo: el fuente con `ray run` y espacio de trabajo explícito |
| `src/config.ray` | perfiles, entorno, banderas, URL del endpoint |
| `src/message.ray` | modelo canónico de conversación (`Message`, `ToolCall`, `Reply`) |
| `src/openai.ray` | adaptador `/v1/chat/completions` (OpenAI y llama.cpp) |
| `src/anthropic.ray` | adaptador `/v1/messages` |
| `src/client.ray` | transporte HTTP, cronometraje y sondeo del modelo |
| `src/tools.ray` | catálogo de herramientas y su ejecución protegida |
| `src/mcp.ray` | cliente MCP por stdio: configuración, un actor por servidor sobre `stdin_pipe`, `tools/list` y `tools/call` |
| `src/agent.ray` | el bucle: pedir → ejecutar herramientas → repetir |
| `src/usage.ray` | contabilidad de tokens, peticiones y latencia |
| `src/ui.ray` | color ANSI y formateadores de terminal |
| `tests/harness_test.ray` | pruebas de configuración, protocolos, contabilidad y MCP |
| `install.sh` | instalador del binario desde la GitHub Release |
| `.github/workflows/release.yml` | compila y publica los binarios al empujar un tag `v*` |

Dependencia externa única: el paquete `net` de raylang (para `net/http`), declarado
por ruta en `ray.toml`. Todo lo demás sale de la **biblioteca estándar de raylang**, no
de código propio ni de terceros: `std/markdown` parsea la respuesta del modelo (aquí
solo se pinta el AST), `std/term` da el modo crudo, la decodificación de teclas y el
tamaño de la ventana, `std/io` la lectura con plazo, y `std/json`, `std/process`,
`std/fs`, `std/time` y `std/math` completan el resto.

## Publicar una versión

`.github/workflows/release.yml` se dispara al empujar un tag `vX.Y.Z`:

```sh
# ray.toml y el tag tienen que decir lo mismo — el workflow lo comprueba y falla si no
git tag -a v0.1.0 -m "raycode 0.1.0"
git push origin v0.1.0
```

Crea la Release del tag con notas autogeneradas y, en paralelo, compila en cuatro
runners —Linux x86-64/arm64 y macOS Intel/Apple Silicon—, pasa `ray test` y sube
`raycode-<target>.tar.gz` con su `.sha256`. Cada plataforma compila **nativa** en su
propio runner y con `--target` explícito: así se queda el perfil de release
(`opt3 + LTO gordo + codegen-units=1`) sin el `target-cpu=native` que lo ataría a la
CPU del runner. Los assets no llevan la versión en el nombre, de modo que `install.sh`
puede pedir `releases/latest/download/…` sin pasar por la API de GitHub.

Como el toolchain de raylang aún no se publica como binario y el paquete `net` vive en
ese repositorio (privado), el workflow lo clona al lado —`ray-apps/raycode` junto a
`raylang`, la misma disposición que en local— y construye `ray` desde el fuente,
cacheado por revisión. Hace falta un secreto **`RAYLANG_TOKEN`** en el repositorio de
raycode: un PAT con permiso de lectura sobre `ray-language/raylang`.

`workflow_dispatch` ejecuta lo mismo sin tocar ninguna Release: compila, prueba y deja
los binarios como artefactos de la ejecución. Sirve para estrenar el pipeline antes de
cortar el primer tag.
