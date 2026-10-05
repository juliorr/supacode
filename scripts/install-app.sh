#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
cd "${repo_root}"

DEVELOPER_DIR="$("${script_dir}/select-developer-dir.sh")"
export DEVELOPER_DIR

PROJECT_WORKSPACE="${repo_root}/supacode.xcworkspace"
APP_SCHEME="supacode"
DERIVED_DATA_PATH="${repo_root}/.build/DerivedData"

echo "==> Obteniendo ruta del producto compilado..."
settings="$(xcodebuild -workspace "${PROJECT_WORKSPACE}" -scheme "${APP_SCHEME}" -configuration Debug -derivedDataPath "${DERIVED_DATA_PATH}" -showBuildSettings -json 2>/dev/null)"
build_dir="$(echo "${settings}" | jq -r '.[0].buildSettings.BUILT_PRODUCTS_DIR')"
product="$(echo "${settings}" | jq -r '.[0].buildSettings.FULL_PRODUCT_NAME')"
src="${build_dir}/${product}"

if [ ! -d "${src}" ]; then
  echo "Error: Aplicación compilada no encontrada en: ${src}" >&2
  echo "Asegúrate de ejecutar 'make build-app' primero." >&2
  exit 1
fi

# Install to /Applications if writable, fallback to ~/Applications
if [ -w "/Applications" ] || [ -w "/Applications/${product}" ]; then
  target_dir="/Applications"
  # Clean up legacy copy in ~/Applications to prevent conflicting LaunchServices & TCC signatures
  if [ -d "${HOME}/Applications/${product}" ]; then
    echo "==> Limpiando copia duplicada en ${HOME}/Applications/${product}..."
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "${HOME}/Applications/${product}" || true
    rm -rf "${HOME}/Applications/${product}"
  fi
else
  target_dir="${HOME}/Applications"
  mkdir -p "${target_dir}"
fi

dst="${target_dir}/${product}"

echo "==> Instalando ${product} en ${dst}..."
if [ "${target_dir}" = "/Applications" ]; then
  osascript -e 'tell application "Finder" to duplicate POSIX file "'"${src}"'" to POSIX file "/Applications" with replacing' >/dev/null
else
  rm -rf "${dst}"
  ditto "${src}" "${dst}"
fi

echo "==> Aplicando firma ad-hoc con Designated Requirement persistente para TCC..."
codesign --force --sign - --entitlements "${repo_root}/supacode/supacodeDebug.entitlements" -r='designated => identifier "app.supabit.supacode"' "${dst}"

# Actualizar LaunchServices para que macOS registre la app de inmediato
touch "${dst}"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "${dst}" || true

echo "==> ¡Instalación exitosa en ${dst}!"
