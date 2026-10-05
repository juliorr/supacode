#!/usr/bin/env bash
# Syncs current fork branch with upstream official supacode repository
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

echo "==> Verificando dependencias con make doctor..."
make doctor

echo "==> Sincronización completada exitosamente."
echo "Para compilar e instalar la app actualizada, ejecuta:"
echo "    make build-app && ./scripts/install-app.sh"
