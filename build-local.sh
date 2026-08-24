#!/bin/bash
#
# Textream — compilación local y creación del instalador .dmg
#
#   ./build-local.sh                 compila (Release, arm64) y crea el DMG
#   ./build-local.sh --universal     compila arm64 + Intel (el DMG vale en cualquier Mac)
#   ./build-local.sh --no-dmg        solo la .app, sin instalador ni zip
#   ./build-local.sh --install       copia la .app a /Applications al terminar
#   ./build-local.sh --open          abre la app recién compilada
#   ./build-local.sh --debug         configuración Debug en vez de Release
#   ./build-local.sh --clean         borra build/ antes de empezar
#
# Firma: sin nada configurado usa firma ad-hoc (vale para este Mac). Para firmar con
# Developer ID, exporta la identidad antes de llamar al script:
#   SIGNING_IDENTITY="Developer ID Application: Nombre (TEAMID)" ./build-local.sh
#
set -uo pipefail
cd "$(dirname "$0")" || exit 1

CONFIG="Release"
ARCHS_LIST="arm64"
ARCH_LABEL="arm64"
MAKE_DMG=1
DO_INSTALL=0
DO_OPEN=0
DO_CLEAN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --universal) ARCHS_LIST="arm64 x86_64"; ARCH_LABEL="universal" ;;
    --debug)     CONFIG="Debug" ;;
    --release)   CONFIG="Release" ;;
    --no-dmg)    MAKE_DMG=0 ;;
    --install)   DO_INSTALL=1 ;;
    --open)      DO_OPEN=1 ;;
    --clean)     DO_CLEAN=1 ;;
    -h|--help)   awk 'NR > 1 { if (!/^#/) exit; sub(/^# ?/, ""); print }' "$0"; exit 0 ;;
    *) echo "❌ Opción desconocida: $1  (usa --help)"; exit 2 ;;
  esac
  shift
done

PROJ="Textream/Textream.xcodeproj"
BUILD_DIR="$PWD/build"
LOG="$BUILD_DIR/build.log"
APP="$BUILD_DIR/Products/$CONFIG/Textream.app"
DEVID_ENTITLEMENTS="Textream/Textream/Textream-DeveloperID.entitlements"

# ---------------------------------------------------------------- comprobaciones
if [ ! -d "$PROJ" ]; then
  echo "❌ No encuentro $PROJ. Ejecuta el script desde la raíz del repo de Textream."
  exit 1
fi

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "❌ No encuentro xcodebuild. Instala Xcode (App Store) y luego:"
  echo "   sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
  exit 1
fi

if [ "$DO_CLEAN" = "1" ]; then
  echo "🧹 Borrando $BUILD_DIR…"
  rm -rf "$BUILD_DIR"
fi
mkdir -p "$BUILD_DIR"
: > "$LOG"

if ! xcodebuild -version >>"$LOG" 2>&1; then
  echo "❌ xcodebuild falla — seguramente solo tienes las Command Line Tools, no Xcode."
  echo "   sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
  echo "   (detalles en $LOG)"
  exit 1
fi
XCODE_VERSION="$(head -1 "$LOG")"

# ---------------------------------------------------------------- compilación
echo "🔨 $XCODE_VERSION · $CONFIG · $ARCH_LABEL"
echo "   compilando…  (log: ${LOG#"$PWD"/})"
xcodebuild build \
  -project "$PROJ" \
  -target Textream \
  -configuration "$CONFIG" \
  ARCHS="$ARCHS_LIST" \
  ONLY_ACTIVE_ARCH=NO \
  SYMROOT="$BUILD_DIR/Products" \
  OBJROOT="$BUILD_DIR/Intermediates" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  >>"$LOG" 2>&1
status=$?

if [ $status -ne 0 ] || [ ! -d "$APP" ]; then
  echo ""
  echo "❌ Compilación fallida (código $status). Errores:"
  grep -E "error:" "$LOG" | sort -u | head -20
  echo ""
  echo "   Log completo: $LOG"
  exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null)"
[ -n "$VERSION" ] || VERSION="dev"

# ---------------------------------------------------------------- firma
if [ -n "${SIGNING_IDENTITY:-}" ]; then
  echo "🖋️  Firmando con Developer ID: $SIGNING_IDENTITY"
  codesign --force --sign "$SIGNING_IDENTITY" \
    --options runtime --timestamp --generate-entitlement-der \
    --entitlements "$DEVID_ENTITLEMENTS" "$APP" >>"$LOG" 2>&1
  sign_status=$?
else
  # Sin entitlements a propósito: sin App Sandbox la app puede sustituir su propio bundle
  # al actualizarse desde el menú. Estas builds no van a la App Store.
  echo "🖋️  Firma ad-hoc sin sandbox (necesario para que se autoactualice)"
  codesign --force --sign - "$APP" >>"$LOG" 2>&1
  sign_status=$?
fi

if [ $sign_status -ne 0 ]; then
  echo "❌ La firma ha fallado. Últimas líneas del log:"
  tail -5 "$LOG"
  exit 1
fi
codesign --verify --strict "$APP" >>"$LOG" 2>&1 \
  || echo "⚠️  codesign --verify no ha pasado; mira el final de $LOG"

ARCHS_BUILT="$(lipo -archs "$APP/Contents/MacOS/Textream" 2>/dev/null)"

# ---------------------------------------------------------------- instalador dmg
DMG=""
ZIP=""
if [ "$MAKE_DMG" = "1" ]; then
  DMG="$BUILD_DIR/Textream-$VERSION-$ARCH_LABEL.dmg"
  ZIP="$BUILD_DIR/Textream-$VERSION-$ARCH_LABEL.zip"
  STAGING="$BUILD_DIR/dmg-staging"
  echo "📦 Creando instalador $(basename "$DMG")…"

  # El mismo zip que publica GitHub Actions y que descarga el updater de la app.
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP" >>"$LOG" 2>&1 || ZIP=""

  rm -rf "$STAGING" "$DMG"
  if ! (mkdir -p "$STAGING" && cp -R "$APP" "$STAGING/" && ln -s /Applications "$STAGING/Applications"); then
    echo "❌ No he podido preparar el contenido del DMG en $STAGING"
    exit 1
  fi

  hdiutil create \
    -volname "Textream $VERSION" \
    -srcfolder "$STAGING" \
    -ov -format UDZO \
    "$DMG" >>"$LOG" 2>&1
  dmg_status=$?
  rm -rf "$STAGING"

  if [ $dmg_status -ne 0 ]; then
    echo "❌ hdiutil ha fallado. Últimas líneas del log:"
    tail -10 "$LOG"
    exit 1
  fi

  if [ -n "${SIGNING_IDENTITY:-}" ]; then
    codesign --force --sign "$SIGNING_IDENTITY" --timestamp \
      --identifier dev.fka.textream.dmg "$DMG" >>"$LOG" 2>&1 \
      || echo "⚠️  No se ha podido firmar el DMG; mira $LOG"
  fi
fi

# ---------------------------------------------------------------- extras
if [ "$DO_INSTALL" = "1" ]; then
  if pgrep -x Textream >/dev/null 2>&1; then
    echo "⚠️  Textream está abierto: ciérralo y vuelve a lanzar con --install (o instala desde el DMG)."
  else
    echo "📥 Instalando en /Applications…"
    rm -rf "/Applications/Textream.app"
    if cp -R "$APP" /Applications/; then
      echo "   /Applications/Textream.app"
    else
      echo "⚠️  No he podido copiar a /Applications (¿permisos?). Arrastra la app desde el DMG."
    fi
  fi
fi

if [ "$DO_OPEN" = "1" ]; then
  open "$APP"
fi

# ---------------------------------------------------------------- resumen
echo ""
echo "✅ Textream $VERSION ($CONFIG, ${ARCHS_BUILT:-$ARCH_LABEL})"
echo "   App:  $APP"
[ -n "$DMG" ] && echo "   DMG:  $DMG  ($(du -h "$DMG" | cut -f1 | tr -d ' '))"
[ -n "$ZIP" ] && echo "   ZIP:  $ZIP"
if [ -z "${SIGNING_IDENTITY:-}" ] && [ -n "$DMG" ]; then
  echo ""
  echo "   ℹ️  Firma ad-hoc: en OTRO Mac, Gatekeeper bloqueará la app. Para abrirla allí,"
  echo "      clic derecho → Abrir, o:  xattr -dr com.apple.quarantine /Applications/Textream.app"
  echo "      Para repartirla sin fricción hace falta Developer ID + notarización."
fi
