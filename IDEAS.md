# raycode — Carencias y problemas de raylang

Registro de lo que raycode echa de menos o rompe en raylang. Misma función que
`ray-sublime/IDEAS.md` y que las secciones por app de `raylang/IDEAS.md`: cada
entrada dice **qué se intentó**, **qué pasó**, **repro mínimo** y **cómo lo
esquiva la app**.

Estado: raylang **1.27.5**, macOS arm64, 21 sep 2026. (1.27.5 cerró #1 —M285, la VM
cifra por trozos y conduce el handshake: cae el techo de 64 KiB por conexión TLS—.)

Leyenda: 🐛 bug · 🕳️ hueco de API · 📝 doc · ✅ resuelto en raylang

---

## Etapa 1 — El harness contra proveedores remotos

### 1. 🐛 Una conexión TLS no admite más de 64 KiB escritos sin una lectura entre medias ✅ (1.27.5, M285: la escritura TLS cifra por trozos y conduce el handshake)

**Qué se quería.** Mandarle el turno a un proveedor remoto por HTTPS. Un harness
de agente acumula historial: el prompt de sistema, el catálogo de herramientas y
—sobre todo— lo que devuelven las herramientas. Un `read_resource` de
`raylang://llms.txt` son ~40 KB; media docena de archivos leídos, otro tanto. El
cuerpo de la petición pasa de 64 KB a los pocos pasos, y eso es el uso normal, no
un caso extremo.

**Qué pasó.** A partir de ahí, y siempre en el mismo punto, la petición muere
antes de salir:

```
✗ error sending: failed to write whole buffer (after 3 attempts)
```

El mensaje viene de `net/http.ray`, que envuelve el `Err` de
`net.socket_write_bytes`; el texto en sí es el `write_all` del runtime (WriteZero:
el `write` devolvió 0). No hay nada en él que diga de qué capa viene ni que el
tamaño tenga algo que ver, así que se diagnostica como un problema de red — que
es lo que parece — y no lo es.

**Repro mínimo.** Tres medidas, y la tercera es la que señala la causa.

1. Por `http://`, contra un `webserver.serve` en el mismo proceso, **no falla
   nunca**: 1 KiB, 64, 128, 256, 512 y 1024 KiB contestan 200.

2. Por `https://`, contra un endpoint que **acepta** el cuerpo y contesta 200
   (httpbin), falla en un umbral exacto:

   ```raylang
   import net/http;

   fn try_at(url: string, kb: int) {
       var chunk = "";
       var i = 0;
       while (i < 1024) { chunk = chunk + "x"; i = i + 1; }
       var pad = "";
       i = 0;
       while (i < kb) { pad = pad + chunk; i = i + 1; }
       var h: Map<string, string> = Map.new();
       h.insert("Content-Type", "text/plain");
       match (http.stream_with("POST", url, pad.to_bytes(), h, 30000)) {
           Result.Ok(s) => print("  ${kb} KiB -> status ${s.status}"),
           Result.Err(e) => print("  ${kb} KiB -> FAILED: ${e}"),
       }
   }

   fn main() {
       for kb in [1, 16, 32, 48, 64, 128] {
           try_at("https://httpbin.org/post", kb);
       }
   }
   ```

   ```
   1 KiB -> status 200
   16 KiB -> status 200
   32 KiB -> status 200
   48 KiB -> status 200
   64 KiB -> FAILED: error sending: failed to write whole buffer
   128 KiB -> FAILED: error sending: failed to write whole buffer
   ```

   Importa que el servidor conteste **200**: no está cerrando la conexión ni
   rechazando el cuerpo. (Contra `api.openai.com` sin clave pasa lo mismo, pero
   allí el 401 temprano confunde el diagnóstico; por eso la medida buena es ésta.)

3. Trocear **no sirve**, y ahí se ve que el límite es acumulado por conexión, no
   por llamada. Escribiendo a mano sobre `net.tls_connect` en trozos de 32 KiB o
   de 16 KiB, el fallo cae siempre en el mismo octeto:

   ```
   128 KiB de una vez            -> FALLA: failed to write whole buffer
   128 KiB en trozos de 32768    -> FALLA en 65536: failed to write whole buffer
   512 KiB en trozos de 32768    -> FALLA en 65536: failed to write whole buffer
   ```

**El detalle que dice dónde está.** Tras el fallo, **una lectura desbloquea la
escritura** — incluso una que vence por plazo y no trae ni un octeto:

```raylang
match (net.socket_write_bytes(h, data.sub_bytes(at, end))) {
    Result.Err(e) => {
        // "failed to write whole buffer", con at == 65536
        let _ = net.socket_read_bytes(h);       // vence por plazo: 0 octetos
        // y a partir de aquí la escritura continúa hasta el final
    },
    Result.Ok(_) => { at = end; },
}
```

```
bloqueado tras 65536 octetos: failed to write whole buffer
  lectura intermedia falla: read timeout
  …y tras leer SÍ deja escribir
escritos 131183 de 131183 (1 lecturas de rescate)
```

Es el comportamiento de rustls cuando se escribe en el búfer de texto plano de la
sesión sin vaciarlo hacia el socket: el límite por defecto de ese búfer son 64
KiB, y una vez lleno `writer().write()` devuelve `Ok(0)` para siempre —de ahí el
WriteZero—. Algo en el camino de lectura sí lo vacía, y por eso el rescate
funciona. La escritura del runtime, no.

**Cómo lo esquivó la app** (mientras duró; ver «Resuelto», más abajo). No se podía esquivar
en la capa correcta: el bucle de escritura está en el runtime, y `net/http.ray` (idéntico,
por cierto, en `net` v0.1.0 y v0.2.0) solo lo llama una vez con la petición entera. Lo que
hacía raycode era **no llegar al techo**: antes de cada petición, si el endpoint era TLS,
medía el cuerpo y, si pasaba de 56 KB, iba apartando los resultados de herramienta más
viejos hasta que cabía, y lo decía.

Se **encogían, no se borraban**: un `tool_use` sin su `tool_result` invalida el historial
para el turno siguiente (Anthropic lo rechaza), así que el mensaje se quedaba donde estaba y
lo que se sustituía era su contenido, por una nota que le decía al modelo que ese resultado
existió y que podía volver a pedirlo. Eran `agent.fit_for_tls` y `client.TLS_BODY_LIMIT`, con
la prueba `a_turn_is_kept_under_what_tls_can_write`, que sostenía las dos promesas: que cabe,
y que ningún par llamada/resultado se rompe. **Ya no están en el código**: se borraron al
cerrarse esto, así que no se busquen.

El coste era el que parece: una conversación larga contra un proveedor remoto perdía su
contexto viejo, y lo perdía por una razón que no tenía nada que ver con la ventana del
modelo. Sobre `http://` (llama.cpp en local) no había techo y no se recortaba nada, que es
justamente lo que delataba que el problema no era del protocolo ni del proveedor.

**Resuelto en 1.27.5.** `fix(vm): M285 — la escritura TLS cifra por trozos y conduce el
handshake: cae el techo de 64 KiB`. La misma medida, contra el mismo endpoint, con el mismo
archivo de prueba:

```
48 KiB -> status 200
64 KiB -> status 200      (antes: failed to write whole buffer)
128 KiB -> status 200
512 KiB -> status 200
1024 KiB -> status 200
```

El parachoques de raycode se fue con ello: `agent.fit_for_tls`, `client.TLS_BODY_LIMIT` y su
prueba se borraron enteros, y una conversación larga contra un proveedor remoto vuelve a
llevar su historial completo. Queda el aviso de método: el binario del PATH era el de la
versión anterior cuando se midió por primera vez —la corrección estaba en el fuente y no en
lo que corría—, así que la primera lectura fue un falso negativo. Comparar la fecha del
commit con la del binario lo deshizo en un minuto.

**Petición a raylang (atendida).** Vaciar el búfer TLS dentro del bucle de escritura: tras
cada `writer().write(...)`, empujar al socket lo que la sesión tenga pendiente
(`write_tls` hasta drenar) y seguir, en vez de un `write_all` sobre un búfer
acotado. Alternativa barata: `set_buffer_limit(None)` en la sesión, que quita el
tope aunque deja la memoria sin acotar. La primera es la buena: deja el consumo
acotado **y** permite cuerpos de cualquier tamaño.

De paso, dos cosas menores del mismo sitio, que siguen abiertas:

- El error debería decir de qué capa viene. `failed to write whole buffer` se lee
  como un problema de red y no lo es; algo como `TLS write buffer full after N
  bytes` habría ahorrado el rodeo entero.
- Merecería la pena que el límite fuera observable desde raylang (una constante o
  una pregunta al socket). Hoy la única forma de saber que son 65536 es medirlo.
