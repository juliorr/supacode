#!/usr/bin/env bash
# Syncs current fork branch with upstream official supacode repository
# and mirrors official Sparkle build numbers to prevent update prompt collisions.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
cd "${repo_root}"

echo "==> Comprobando estado de git..."
if ! git diff-index --quiet HEAD --; then
  echo "Error: Tienes cambios sin commitear en el árbol de trabajo. Guarda o haz stash de tus cambios antes de sincronizar." >&2
  exit 1
fi

current_branch="$(git rev-parse --abbrev-ref HEAD)"
echo "==> Rama actual: ${current_branch}"

if ! git remote get-url upstream >/dev/null 2>&1; then
  echo "==> Configurando remote upstream..."
  git remote add upstream https://github.com/supabitapp/supacode.git
fi

echo "==> Descargando novedades de upstream..."
git fetch upstream main

echo "==> Aplicando rebase de ${current_branch} sobre upstream/main..."
git rebase upstream/main

echo "==> Consultando la versión oficial de Sparkle (appcast.xml)..."
appcast_xml="$(curl -sSL https://supacode.sh/download/latest/appcast.xml 2>/dev/null || true)"
if [ -n "${appcast_xml}" ]; then
  latest_build="$(echo "${appcast_xml}" | grep -oE '<sparkle:version>[0-9]+</sparkle:version>' | head -n 1 | sed -E 's/.*<sparkle:version>([0-9]+)<\/sparkle:version>/\1/' || true)"
  latest_version="$(echo "${appcast_xml}" | grep -oE '<sparkle:shortVersionString>[^<]+</sparkle:shortVersionString>' | head -n 1 | sed -E 's/.*<sparkle:shortVersionString>([^<]+)<\/sparkle:shortVersionString>/\1/' || true)"

  config_path="${repo_root}/Configurations/Project.xcconfig"
  if [ -n "${latest_build}" ] && [ -f "${config_path}" ]; then
    echo "==> Espejando build oficial: ${latest_version} (build ${latest_build}) en Configurations/Project.xcconfig..."
    sed -i '' "s/^CURRENT_PROJECT_VERSION = .*/CURRENT_PROJECT_VERSION = ${latest_build}/g" "${config_path}"
    [ -z "${latest_version}" ] || sed -i '' "s/^MARKETING_VERSION = .*/MARKETING_VERSION = ${latest_version}/g" "${config_path}"
  fi
fi

echo "==> Verificando dependencias con make doctor..."
make doctor

echo "==> Sincronización completada exitosamente."
echo "Para compilar e instalar la app actualizada, ejecuta:"
echo "    make build-app && ./scripts/install-app.sh"
