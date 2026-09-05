# Plan: soporte de servidores MCP

Objetivo: que las herramientas de un servidor [MCP](https://modelcontextprotocol.io)
aparezcan en el catálogo que raycode ofrece al modelo, junto a `read_file`,
`write_file`, `list_dir` y `run_command`, sin que el bucle del agente se entere de
la diferencia. Banco de pruebas: `ray mcp`, el servidor embebido en el binario de
raylang (`ray_check`, `ray_run`, `ray_test`, `ray_fmt`, `ray_doc`).

## Lo que ya se comprobó (no es diseño, es medición)

- **`ray mcp` habla JSON-RPC 2.0 por stdio, delimitado por línea.** Mandándole las
  tres líneas del apretón de manos y la llamada **en un solo lote** por stdin y
  leyendo su stdout hasta EOF, contesta `initialize`, `tools/list` y `tools/call`
  correctamente. Verificado a mano contra el binario instalado.
- **Cuesta ~5 ms por llamada completa** (proceso nuevo incluido): 5 llamadas de
  punta a punta en 24 ms. Un proceso por llamada es viable para este servidor.
- **raylang no tiene stdin escribible sobre un hijo vivo.** `std/process` ofrece
  `.stdin(bytes)`, que *escribe y cierra* en el spawn; `Proc` solo expone
  `out`/`err`. El propio runtime lo dice: *"los handles de proceso no son
  escribibles […] un stdin por canal sería v3"* (`src/builtins.rs:800`). Por tanto
  **una sesión MCP persistente no es implementable hoy**, y el diseño se apoya en
  el lote de una tirada.
- **El `write_all` de stdin es síncrono** (`crates/ray-runtime/src/process.rs:111`):
  si el lote pasa del buffer del pipe (~64 KiB) y el hijo no consume, bloquea el
  hilo de la VM. El lote se tiene que acotar.

## Diseño

### Transporte: un proceso por llamada

Cada operación MCP (`tools/list` al arrancar, `tools/call` en cada uso) lanza el
servidor, le mete por stdin el lote

```
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{…}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{…}}
```

drena stdout y se queda con la línea cuyo `id` es 2. Se usa `.stdin(lote).stream()`
—no `.run()`— por lo mismo que `run_command`: drenar el canal **aparca** la fibra y
deja vivo el indicador de actividad, mientras que `run()` congelaría el planificador.
El plazo se compone a mano igual que allí: fibra guardiana + `p.kill(true)`.

Consecuencias, que van al README y no se ocultan:

- solo sirven **servidores sin estado entre llamadas** (`ray mcp` lo es);
- el coste del arranque se paga por llamada — trivial para `ray mcp` (~5 ms),
  caro para un servidor de `npx` (~1 s), y por eso se muestra en `/mcp`;
- el lote se rechaza con un error legible si pasa de **60 KiB** (antes de que el
  `write_all` síncrono pueda clavarse), diciendo qué argumento se pasó de tamaño.

### `src/mcp.ray` (módulo nuevo)

```rust
pub struct Server { name, command, args, dir, env, enabled, note }   // note = último error
pub fn discover(s: Server, timeout_ms: int) -> Result<[Tool], string>   // initialize + tools/list
pub fn call(s: Server, tool: string, arguments: string, timeout_ms: int) -> Result<string, string>
```

Dentro: construcción del lote, escaneo de líneas, `match` de `id`, y el aplanado del
resultado — `result.content[]` de bloques `{"type":"text","text":…}` a texto plano;
`isError: true` se devuelve como `Result.Err` para que caiga en el mismo camino de
"error al modelo, nunca panic" que ya usa `tools.execute`. Un bloque que no sea texto
se resume (`[image 12 KiB]`), no se vuelca.

### El catálogo, sin closures

`Tool` sigue siendo **datos** (la sesión cruza a otra fibra en cada paso y un valor
con funciones dentro no cruza esa frontera). Se le añade un campo:

```rust
pub struct Tool { name, description, schema, source: string }   // "" = builtin, si no el servidor
```

- Nombre expuesto al modelo: `mcp__<servidor>__<tool>`, la convención de Claude Code,
  así que colisiones imposibles y origen legible en la traza.
- `tools.execute` gana el parámetro `[Server]` y despacha: `source == ""` → `dispatch`
  de siempre; si no, `mcp.call` con el nombre remoto (el que va tras el segundo `__`).
- `Session` gana `mcp: [Server]`. Va en la sesión, no en un global, porque la fibra
  trabajadora recibe una **copia** de la sesión: lo que no esté ahí no llega.

### Configuración

Archivo `.raycode/mcp.json` del espacio de trabajo, y si no `~/.raycode/mcp.json`,
con el sobre estándar — el mismo que Claude Code y Claude Desktop, para poder copiar
y pegar:

```json
{ "mcpServers": { "raylang": { "command": "ray", "args": ["mcp"] } } }
```

Campos por servidor: `command`, `args`, `env`, `dir`, `disabled`. Banderas:
`--mcp-config <ruta>`, `--no-mcp`; entorno: `RAYCODE_MCP_CONFIG`.

**Opt-in por construcción**: sin archivo no hay servidores. Un servidor MCP es un
programa arbitrario que se ejecuta, así que el arranque lo dice en el banner (nombre,
mandato y número de herramientas) — el usuario ve qué se lanzó en su nombre, igual
que ve que `run_command` está apagado.

### Arranque y fallos

El descubrimiento (`tools/list`) ocurre una vez al abrir la sesión, con plazo por
servidor (por defecto 5 s). Un servidor que no arranca, que tarda o que contesta basura
**no tumba nada**: se marca `enabled = false` con su `note`, el banner lo dice en rojo
y la sesión sigue con el resto. `/mcp reload` reintenta sin perder la conversación.

### REPL

| Orden | Qué hace |
|---|---|
| `/mcp` | los servidores, su mandato, sus herramientas y el último error |
| `/mcp reload` | vuelve a descubrir, conservando el hilo |
| `/tools` | ya existe; pasa a mostrar el origen de cada herramienta |

`/mcp` entra en `commands()` para que Tab lo complete.

## Estado

Fases 1, 2 y 4a hechas. El transporte ya NO es un proceso por llamada: raylang 1.1.0
trajo `Cmd.stdin_pipe()` + `Proc.write` / `Proc.close_stdin` (la "v3" que el runtime
anticipaba), y `src/mcp.ray` sostiene una sesión por servidor en un actor —una fibra que
posee el proceso y atiende peticiones por canal—, con relanzamiento tras muerte o plazo
vencido y cierre ordenado al salir. El tope de 60 KiB desapareció con él: `Proc.write`
aparca la fibra con contrapresión en vez de clavar la VM. Las `instructions` del
`initialize` van al prompt de sistema. Queda la fase 3 (recursos) y 4b (HTTP/SSE).

## Fases

1. **Protocolo y despacho.** `src/mcp.ray`, `Tool.source`, `Session.mcp`, config
   `.raycode/mcp.json`, banner. Criterio: con el archivo apuntando a `ray mcp`, el
   modelo escribe raylang y lo verifica con `mcp__raylang__ray_check` en el mismo turno.
2. **UX y robustez.** `/mcp`, `/mcp reload`, origen en `/tools`, tope de 60 KiB,
   plazos por servidor, errores legibles, ESC durante una llamada MCP.
3. **Recursos.** `resources/list` y `resources/read`, y una orden para inyectar uno al
   contexto (`raylang://llms.txt` es exactamente para eso).
4. **Transporte largo** (bloqueado por raylang, no por raycode). Dos salidas, no
   excluyentes: (a) `.stdin_pipe()` / stdin por canal en `std/process` —la "v3" que el
   propio runtime anticipa— y entonces una sesión MCP persistente; (b) transporte
   **HTTP/SSE**, que sí es implementable hoy con `net/http` (ya es la única dependencia
   del proyecto) y abre los servidores remotos.

## Pruebas (`tests/harness_test.ray`)

Puras, sin proceso: construcción del lote, escaneo de líneas y selección por `id`,
aplanado de `content`, `isError`, mangling `mcp__servidor__tool` y su inverso, parseo
del `mcpServers`, y el rechazo por tamaño. De punta a punta: descubrir y llamar contra
`ray mcp` si el binario está en el PATH, y saltar la prueba si no.

## Lo que este plan NO hace

Sampling, prompts, notificaciones y elicitación del protocolo; autorización OAuth;
servidores remotos (llegan con la fase 4b). Nada de eso hace falta para el bucle
escribir → verificar → corregir, que es lo que se busca con `ray mcp`.
