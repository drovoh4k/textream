# Este fork

Fork de [`f/textream`](https://github.com/f/textream) con cambios propios en el teleprompter,
compilación local en un comando y builds automáticas en GitHub Actions.

## Qué añade respecto al upstream

**Controles de layout del prompter** (fullscreen y pantalla externa / Sidecar), en Ajustes →
pestañas *Teleprompter* (modo Fullscreen) y *External*:

| Ajuste | Rango | Por defecto |
|---|---|---|
| **Side Margins** | 0–35% del ancho por lado | 8% (lo que estaba fijo en el código) |
| **Reading Line Height** | 10–95% de la altura | 50% (centrado) |
| **Text Size** | 50–200% del tamaño automático | 100% |

Dos cambios de comportamiento que vienen con esto:

- En estos dos prompters, *Reading Line Height* sustituye al ajuste *Centered / Near Top* de la
  pestaña Reading, que sigue mandando en el overlay del notch y en la ventana flotante. Si venías
  de *Near Top*, el slider arranca en 15% la primera vez.
- En modo clásico y voz-activada la línea activa ya no está clavada al borde inferior: sigue al
  slider. Al 95% se comporta como antes.

**Actualizaciones desde este repo.** `UpdateChecker` mira las releases de este fork, no las del
upstream. Cuando hay una versión nueva ofrece **Install and Relaunch**: descarga el `.zip` de la
release, sustituye el propio bundle y reabre la app. Si la app está en una carpeta donde no puede
escribir, o corre en sandbox (por ejemplo lanzada desde Xcode), ofrece descargar el DMG.

**Sin App Sandbox en estas builds.** `build-local.sh` y el workflow firman ad-hoc y sin
entitlements: es lo que le permite reescribir su propio bundle al actualizarse. Los builds desde
Xcode (⌘R) siguen usando `Textream.entitlements`, con sandbox, como el upstream.

## Compilar en local

```bash
./build-local.sh              # Release arm64 → .app + .dmg + .zip en build/
./build-local.sh --universal  # arm64 + Intel
./build-local.sh --install    # además lo copia a /Applications
./build-local.sh --help       # el resto de opciones
```

Necesita Xcode 16 o superior (el target es macOS 15). Para firmar con Developer ID en vez de
ad-hoc: `SIGNING_IDENTITY="Developer ID Application: … (TEAMID)" ./build-local.sh`.

## Automatización

| Workflow | Cuándo | Qué hace |
|---|---|---|
| `.github/workflows/drovo-sync-upstream.yml` | cada día a las 05:00 UTC, o a mano | Mergea `f/textream@master` en `master`. Si entra limpio, hace push y encadena la build. Si hay conflicto, deja `master` intacto y abre (o comenta) una issue con la etiqueta `upstream-conflict`. |
| `.github/workflows/drovo-build.yml` | push a `master`, llamada desde el sync, o a mano | Compila universal, firma ad-hoc, empaqueta `.dmg` + `.zip` y publica la release. |

La versión es `MARKETING_VERSION` del proyecto + el número de run: `1.7.0.42`. El tag es
`drovo-1.7.0.42` — **no** `v*`, porque el `release.yml` del upstream escucha en `v*` y aquí
fallaría por falta de secrets.

### Qué hay que habilitar una vez en GitHub

1. Pestaña **Actions** → botón verde para habilitar los workflows del fork (GitHub los deja
   desactivados en cualquier fork recién creado, incluidos los `schedule`).
2. **Settings → Actions → General → Workflow permissions** → *Read and write permissions*, o el
   push a `master` y la creación de releases fallarán con 403.

GitHub desactiva los workflows programados en repos sin actividad durante 60 días; si el sync deja
de correr, un `workflow_dispatch` a mano lo reactiva.

## Gatekeeper

Las releases van firmadas ad-hoc y sin notarizar. Un DMG descargado con el navegador llega en
cuarentena: clic derecho → Abrir la primera vez, o
`xattr -dr com.apple.quarantine /Applications/Textream.app`. Las actualizaciones que hace la propia
app no pasan por ahí, porque el zip lo descarga ella misma.
