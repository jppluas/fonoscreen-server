# FonoScreen — Kiosk Server

Sistema de cribado fonológico automatizado para niños de 3 a 5 años.
ESPOL · Ingeniería en Ciencias de la Computación · Materia Integradora

---

## Estructura del proyecto

```
fonoscreen-server/
├── app.py                  # Servidor Flask — toda la infraestructura
├── requirements.txt        # Flask==3.1.3
├── fonoscreen.service      # Servicio systemd para autoarranque en el Pi
├── setup_hotspot.sh        # Configura el hotspot Wi-Fi (solo Pi, una vez)
├── templates/
│   ├── base.html           # Layout compartido (header, footer)
│   ├── register.html       # Registro del niño antes de la prueba
│   ├── session.html        # Pantalla en curso — polling al estado global
│   ├── results.html        # Resultados y descarga de informes
│   └── device.html         # Panel de dispositivo (volumen, mic, apagado)
├── static/
│   ├── css/base.css        # Estilos mobile-first
│   └── js/utils.js         # Utilidades JS: toast, confirm, api()
├── exports/                # PDFs generados (ignorado por git)
└── logs/
    └── server.log          # Log del servidor
```

---

## Levantar en laptop de desarrollo (Debian 12)

```bash
cd ~/fonoscreen-server

# Crear el venv DENTRO de la carpeta del proyecto (no fuera)
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
python app.py
```

El servidor queda en `http://0.0.0.0:5000`.
Abrir en el navegador en `http://localhost:5000` o desde el celular en
`http://<IP-de-la-laptop>:5000` si están en la misma red.

En laptop, `IS_PI = False`. Esto significa:
- El volumen, tono, grabación de micrófono y apagado se **simulan** (responden ok sin ejecutar nada real).
- El endpoint `/dev/simulate` está activo para simular el pipeline manualmente.
- El servidor corre en modo debug con recarga automática.

> **Importante:** el venv nunca se mueve ni se copia entre carpetas. Si cambias
> el nombre o la ubicación de la carpeta del proyecto, borra el venv y créalo
> de nuevo con `python3 -m venv venv`. Los venvs tienen rutas absolutas
> hardcodeadas y dejan de funcionar si se mueven.

> **Importante:** verificar siempre que solo hay un proceso corriendo antes de
> probar. Dos servidores activos al mismo tiempo causan comportamiento
> impredecible porque el navegador puede estar hablando con el proceso viejo.
> ```bash
> pkill -f "python app.py"
> # verificar que no queda ninguno:
> ps aux | grep "python app.py"
> # luego arrancar de nuevo
> python app.py
> ```

> **Importante:** para probar la interfaz correctamente, usar una ventana
> incógnito en Chrome (`Ctrl+Shift+N`). Las extensiones del navegador pueden
> interceptar eventos de click y hacer que los botones no respondan aunque
> el código esté correcto.

---

## Levantar en Raspberry Pi 5

### Primera vez (una sola vez)

```bash
# 1. Configurar hotspot Wi-Fi
sudo bash setup_hotspot.sh
sudo reboot

# 2. Crear usuario de servicio
sudo useradd -m -s /bin/bash fonoscreen

# 3. Instalar el proyecto
sudo -u fonoscreen git clone <repo> /home/fonoscreen/fonoscreen-server
cd /home/fonoscreen/fonoscreen-server
python3 -m venv venv
venv/bin/pip install -r requirements.txt

# 4. Instalar dependencias de audio
sudo apt install -y sox alsa-utils

# 5. Habilitar autoarranque
sudo cp fonoscreen.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable fonoscreen
sudo systemctl start fonoscreen
```

El celular del evaluador se conecta a la red Wi-Fi `FonoScreen` (contraseña: `fonoscreen2025`)
y abre `http://192.168.4.1` en el navegador. No necesita instalar nada.

### Ver logs en tiempo real

```bash
journalctl -u fonoscreen -f
# o directamente:
tail -f /home/fonoscreen/fonoscreen-server/logs/server.log
```

En Pi, `IS_PI = True`. El volumen, tono, grabación y apagado son reales.
El endpoint `/dev/simulate` está **deshabilitado** (devuelve 403).

---

## Estado global de sesión — lo que Daniel debe modificar

El pipeline se comunica con la UI a través de un diccionario global en memoria
llamado `_session_state` definido en `app.py`. La UI hace polling a ese estado
cada 1.5 segundos y actualiza la pantalla automáticamente.

**Daniel no hace peticiones HTTP. Solo modifica `_session_state` directamente
desde el hilo del pipeline.**

### Estructura completa del estado

```python
_session_state = {
    # --- Manejado por la infraestructura (no tocar desde el pipeline) ---
    "active":       bool,   # True cuando hay sesión en curso
    "session_id":   str,    # ID de 8 caracteres, ej. "A1B2C3D4"
    "child": {
        "name":   str,
        "dob":    str,      # "YYYY-MM-DD"
        "gender": str,      # "F" | "M" | "O"
        "notes":  str,
    },
    "started_at":   str,    # ISO datetime

    # --- Daniel actualiza estos campos durante el pipeline ---
    "status":           str,    # ver tabla de estados abajo
    "current_item":     int,    # ítem actual, empieza en 0, sube hasta total_items
    "total_items":      int,    # total de palabras a evaluar (defínelo al inicio)
    "current_word":     str,    # palabra objetivo que ve el docente, ej. "pelota"
    "analysis_progress":int,    # cuántos ítems ya analizados (durante "analyzing")
    "no_voice_detected":bool,   # True cuando Silero VAD no detectó voz
    "results":          dict,   # resultado final (ver estructura abajo)
}
```

### Tabla de estados (`status`)

| valor | qué ve el docente | cuándo usarlo |
|---|---|---|
| `idle` | Preparando evaluación | al iniciar, antes del primer ítem |
| `playing` | Escucha con atención | mientras se reproduce el estímulo de audio |
| `recording` | Ahora repite la palabra | mientras `arecord` está grabando |
| `no_voice` | No se escuchó respuesta | cuando Silero VAD devuelve silencio |
| `analyzing` | Analizando grabaciones | fase post-grabación, XLS-R + NW corriendo |
| `generating_report` | Preparando informe | mientras Gemma genera el reporte |
| `paused` | Evaluación pausada | cuando el docente presiona Pausar |
| `done` | ¡Evaluación completada! | al terminar, la UI redirige a resultados |

### Estructura de `results`

```python
_session_state["results"] = {
    "score": int,           # puntuación global 0-100
    "level": str,           # texto descriptivo del nivel, ej. "Desarrollo típico"
    "details": [
        {
            "phoneme": str,     # fonema evaluado, ej. "/r/"
            "score":   int,     # puntuación 0-100
            "flag":    bool,    # True = requiere atención
        },
        # ... un objeto por fonema evaluado
    ],
}
```

---

## Cómo integrar el pipeline — paso a paso

### 1. Importar el estado en tu módulo

```python
# En pipeline.py (o como llames tu módulo)
import app  # importa el módulo completo para acceder al estado global
```

### 2. Lanzar el pipeline desde app.py

En `app.py`, busca este bloque comentado (~línea 125) y reemplázalo:

```python
# Antes (comentado):
# TODO: aquí se lanza el pipeline en un hilo separado
# from pipeline import run_pipeline
# threading.Thread(target=run_pipeline, args=(session_id,), daemon=True).start()

# Después (activo):
import threading
from pipeline import run_pipeline
threading.Thread(
    target=run_pipeline,
    args=(session_id,),
    daemon=True
).start()
```

### 3. Estructura básica de `run_pipeline`

```python
# pipeline.py
import app
import time

def run_pipeline(session_id):
    state = app._session_state

    WORDS = ["pelota", "casa", "árbol", ...]  # tu lista real
    state["total_items"] = len(WORDS)

    for i, word in enumerate(WORDS):

        # Verificar cancelación al inicio de cada ítem
        if not app._session_state["active"]:
            return

        # Esperar si está pausado
        esperar_si_pausado()

        # 1. Reproducir estímulo
        state["status"] = "playing"
        state["current_word"] = word
        state["current_item"] = i
        reproducir_audio(word)

        esperar_si_pausado()

        # 2. Grabar respuesta
        state["status"] = "recording"
        audio = grabar()

        # 3. Verificar que el niño habló (Silero VAD)
        if not voz_detectada(audio):
            state["status"] = "no_voice"
            state["no_voice_detected"] = True
            continue  # reintentar este ítem

        state["no_voice_detected"] = False
        guardar_audio(session_id, i, audio)

    # Fase de análisis (XLS-R + Phonemizer + NW)
    state["status"] = "analyzing"
    state["analysis_progress"] = 0

    resultados = []
    for i, word in enumerate(WORDS):
        if not app._session_state["active"]:
            return
        resultado = analizar(session_id, i, word)
        resultados.append(resultado)
        state["analysis_progress"] = i + 1

    # Generar reporte (Gemma via Ollama)
    state["status"] = "generating_report"
    reporte = generar_reporte(resultados)

    # Terminar — la UI redirige automáticamente a /resultado
    state["results"] = {
        "score": reporte["score"],
        "level": reporte["level"],
        "details": reporte["details"],
    }
    state["status"] = "done"


def esperar_si_pausado():
    """Bloquea el hilo del pipeline mientras el docente tiene pausada la prueba."""
    while app._session_state.get("status") == "paused":
        time.sleep(0.5)
```

### 4. Cómo funciona la pausa y reanudación

Cuando el docente presiona "Pausar":
- La infraestructura pone `state["status"] = "paused"`
- El pipeline llama a `esperar_si_pausado()` que bloquea el hilo hasta que cambie

Cuando el docente presiona "Continuar":
- La infraestructura llama a `/api/session/resume`
- Ese endpoint pone `state["status"] = "playing"` (o `"idle"` si no había palabra activa)
- El pipeline que estaba bloqueado en `esperar_si_pausado()` detecta el cambio y continúa

El pipeline no necesita hacer nada especial para reanudar: solo llamar
`esperar_si_pausado()` en los puntos donde no debe ejecutarse mientras está pausado.

---

## Simular el pipeline manualmente (solo en laptop)

Con el servidor corriendo en modo debug, desde otra terminal:

```bash
BASE="http://localhost:5000/dev/simulate"

# Flujo completo:
curl -s -X POST $BASE -H "Content-Type: application/json" -d '{"action":"playing"}'
curl -s -X POST $BASE -H "Content-Type: application/json" -d '{"action":"recording"}'
curl -s -X POST $BASE -H "Content-Type: application/json" -d '{"action":"no_voice"}'
curl -s -X POST $BASE -H "Content-Type: application/json" -d '{"action":"progress"}'        # repetir 20 veces
curl -s -X POST $BASE -H "Content-Type: application/json" -d '{"action":"analyzing"}'
curl -s -X POST $BASE -H "Content-Type: application/json" -d '{"action":"analysis_progress"}' # repetir 20 veces
curl -s -X POST $BASE -H "Content-Type: application/json" -d '{"action":"generating_report"}'
curl -s -X POST $BASE -H "Content-Type: application/json" -d '{"action":"done"}'
```

Cada comando responde con el estado completo en JSON.
La pantalla de sesión reacciona en máximo 1.5 segundos sin recargar.

Para probar pausa y reanudación con simulate:
```bash
# Mientras la sesión está en curso, pausar:
curl -s -X POST http://localhost:5000/api/session/pause \
  -H "Content-Type: application/json"

# Reanudar desde la UI o directamente:
curl -s -X POST http://localhost:5000/api/session/resume \
  -H "Content-Type: application/json"
```

---

## Endpoints HTTP disponibles

| método | ruta | descripción |
|---|---|---|
| GET | `/` | Redirige según estado: registro, sesión o resultado |
| GET | `/registro` | Formulario de registro del niño |
| GET | `/sesion` | Pantalla de sesión en curso |
| GET | `/resultado` | Pantalla de resultados |
| GET | `/dispositivo` | Panel de administración del dispositivo |
| POST | `/api/session/start` | Inicia sesión. Body: `{name, dob, gender, notes}` |
| GET | `/api/session/status` | Devuelve `_session_state` completo como JSON |
| POST | `/api/session/pause` | Pone `status = "paused"` |
| POST | `/api/session/resume` | Reanuda desde pausa. Pone `status = "playing"` o `"idle"` |
| POST | `/api/session/reset` | Cancela la sesión y limpia el estado |
| GET | `/api/report/tecnico` | Descarga el PDF del informe técnico |
| GET | `/api/report/representantes` | Descarga el PDF del informe para representantes |
| GET | `/api/device/volume` | Devuelve el nivel de volumen actual |
| POST | `/api/device/volume` | Ajusta volumen. Body: `{level: 0-100}` |
| POST | `/api/device/tone` | Reproduce tono de prueba por el parlante |
| POST | `/api/device/mic/start` | Inicia grabación de prueba (indefinida hasta /stop) |
| POST | `/api/device/mic/stop` | Detiene la grabación de prueba |
| POST | `/api/device/mic/play` | Reproduce la grabación de prueba por el parlante |
| POST | `/api/device/shutdown` | Apaga el dispositivo (`sudo shutdown now`) |
| POST | `/api/device/reboot` | Reinicia el dispositivo (`sudo reboot`) |
| GET | `/api/device/status` | Uptime, disco, hora del servidor |
| POST | `/dev/simulate` | Simula estados del pipeline (solo debug, deshabilitado en Pi) |

---

## Variables de entorno

| variable | default | descripción |
|---|---|---|
| `PORT` | `5000` | Puerto del servidor. Usar `80` en Pi para acceso directo |
| `FLASK_ENV` | `development` | Poner `production` en Pi para deshabilitar debug |
| `FONOSCREEN_SECRET` | `dev-secret-fonoscreen` | Clave secreta de Flask. Cambiar en producción |

Ejemplo para Pi en `fonoscreen.service`:
```ini
Environment="FLASK_ENV=production"
Environment="PORT=80"
Environment="FONOSCREEN_SECRET=una-clave-larga-y-segura"
```

---

## Detección automática de entorno

```python
IS_PI = Path("/proc/device-tree/model").exists()
```

Este archivo solo existe en Raspberry Pi. No hay que configurar nada:
el mismo código funciona en laptop y en Pi sin cambios.

---

## Troubleshooting

### El servidor arranca pero la UI no carga los templates

**Síntoma:** `jinja2.exceptions.TemplateNotFound: register.html`

**Causa:** los archivos HTML no están en la carpeta `templates/` sino sueltos
en la raíz del proyecto.

**Solución:**
```bash
mkdir -p templates static/css static/js
mv register.html session.html results.html device.html base.html templates/
mv base.css static/css/
mv utils.js static/js/
```

---

### `bash: /home/jp/fonoscreen/venv/bin/python: No existe el fichero`

**Causa:** el venv fue creado en otra carpeta o la carpeta del proyecto fue
renombrada. Los venvs tienen rutas absolutas hardcodeadas y no son portables.

**Solución:** siempre recrear el venv desde cero en la carpeta actual:
```bash
rm -rf venv
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
```

---

### Hay dos servidores corriendo al mismo tiempo

**Síntoma:** los cambios en el código no se reflejan en el navegador aunque
el servidor se haya reiniciado. O el navegador responde con datos de una
sesión que ya fue cancelada.

**Causa:** un proceso viejo de Flask quedó corriendo en segundo plano.

**Solución:**
```bash
pkill -f "python app.py"
sleep 1
ps aux | grep "python app.py"  # verificar que no queda ninguno
python app.py
```

---

### Un botón no responde al hacer click

**Síntoma:** se presiona un botón y no pasa nada. No aparece nada en Network
ni en Console del navegador.

**Causa más común:** una extensión del navegador está interceptando los
eventos de click.

**Solución:** abrir en ventana incógnito (`Ctrl+Shift+N`) donde las extensiones
están deshabilitadas. Si funciona ahí, el problema es la extensión.

Para identificar cuál extensión es el problema, ejecutar en la consola:
```javascript
document.querySelectorAll('script').forEach((s, i) =>
  console.log(i, s.src || s.textContent.slice(0, 60))
)
```
Si aparecen scripts de `chrome-extension://` antes de los scripts del proyecto,
ahí está el conflicto.

---

### Un endpoint devuelve HTML en vez de JSON (`Unexpected token '<'`)

**Síntoma:** en la consola del navegador aparece
`SyntaxError: Unexpected token '<', "<!doctype "... is not valid JSON`

**Causa:** Flask está devolviendo una página de error HTML (404 o 500) porque
la ruta no existe o hay un error en el servidor.

**Solución:** revisar la terminal donde corre el servidor para ver el error
real. También verificar en Network que el status code no sea 404 o 500.

Si es 404, el endpoint no existe en el `app.py` que está corriendo. Verificar
con:
```bash
grep "nombre_del_endpoint" ~/fonoscreen-server/app.py
```

---

### La pausa funciona pero el botón Continuar no hace nada

**Causa:** el `app.py` no tiene el endpoint `/api/session/resume`. Ocurre
cuando se está usando una versión vieja del archivo.

**Verificar:**
```bash
grep "session/resume" ~/fonoscreen-server/app.py
```

Si no devuelve nada, actualizar `app.py` con la versión más reciente.

---

### `pip install` falla con errores de permisos o rutas

**Causa:** se está corriendo `pip` sin tener el venv activado, instalando en
el Python del sistema.

**Solución:** siempre activar el venv antes de instalar:
```bash
source venv/bin/activate
# verificar que el prompt muestra (venv) al inicio
pip install -r requirements.txt
```

---

## Pendiente — TODOs para el siguiente sprint

- `app.py` ~línea 125: descomentar el lanzamiento del pipeline en hilo
- `api_report()`: reemplazar placeholder de texto por PDF real (weasyprint o reportlab)
- Base de datos SQLite para persistir sesiones y grabaciones entre reinicios
