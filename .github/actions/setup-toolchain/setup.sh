#!/usr/bin/env bash
# Подготовка тулчейна сборки (D-305).
#
# Почему не subosito/flutter-action и не actions/setup-java: оба экшена
# составные/с вложенными зависимостями, и раннер обязан скачать их вместе
# с actions/cache (~2 МБ) до первого шага джобы. На медленном канале это
# не укладывается в жёсткий таймаут раннера (100 с) — джоба падает на
# «Set up job». Здесь нет ни одного вложенного экшена: инструменты берём
# с машины раннера (FLUTTER_ROOT), а если их нет — официальный архив.
set -euo pipefail

: "${FLUTTER_VERSION:?FLUTTER_VERSION не задан}"

# У раннера-сервиса systemd бывает пустой HOME: без него `git config --global`
# падает («fatal: $HOME not set»). Домашний каталог берём из passwd.
if [ -z "${HOME:-}" ]; then
  HOME="$(cd ~ && pwd)"
  export HOME
  # Следующие шаги джобы получают своё окружение: HOME нужен и им, иначе
  # git снова не видит глобальный конфиг («dubious ownership»).
  echo "HOME=$HOME" >>"$GITHUB_ENV"
fi

# --- JDK 17 (только для Android-джоб: Gradle) ----------------------------
if [ "${REQUIRE_JAVA:-false}" = "true" ]; then
  if [ -n "${JAVA_HOME:-}" ] && [ -x "$JAVA_HOME/bin/java" ]; then
    echo "Java: $("$JAVA_HOME/bin/java" -version 2>&1 | head -n 1)"
  elif command -v java >/dev/null 2>&1; then
    echo "Java: $(java -version 2>&1 | head -n 1)"
  else
    echo "::error::JDK 17 не найден: задайте JAVA_HOME на раннере"
    exit 1
  fi
fi

# --- Flutter --------------------------------------------------------------
# 1. Self-hosted: SDK уже стоит на машине, путь приходит из FLUTTER_ROOT
#    (переменная окружения раннера). Ничего не скачиваем.
if [ -n "${FLUTTER_ROOT:-}" ] && [ -x "$FLUTTER_ROOT/bin/flutter" ]; then
  echo "Flutter (машина раннера): $FLUTTER_ROOT"
  echo "FLUTTER_ROOT=$FLUTTER_ROOT" >>"$GITHUB_ENV"
  echo "$FLUTTER_ROOT/bin" >>"$GITHUB_PATH"
  echo "$FLUTTER_ROOT/bin/cache/dart-sdk/bin" >>"$GITHUB_PATH"
  # SDK на self-hosted ставился другим пользователем: без этой записи
  # flutter --version падает на «dubious ownership» (живой прогон).
  if ! git config --global --get-all safe.directory 2>/dev/null | grep -qxF "$FLUTTER_ROOT"; then
    git config --global --add safe.directory "$FLUTTER_ROOT"
  fi
  # Системный конфиг — страховка: HOME у шагов может отличаться.
  git config --system --add safe.directory "$FLUTTER_ROOT" 2>/dev/null || true
  "$FLUTTER_ROOT/bin/flutter" --version
  exit 0
fi

# 2. Hosted: официальный архив стабильного канала в tool-cache раннера.
case "${RUNNER_OS:-Linux}" in
  Linux)   os=linux;   ext=tar.xz ;;
  Windows) os=windows; ext=zip ;;
  macOS)   os=macos;   ext=zip ;;
  *) echo "::error::неизвестная ОС раннера: ${RUNNER_OS:-}"; exit 1 ;;
esac

# Пути раннера на Windows — вида D:\a\_temp. bsdtar из Git for Windows
# читает их как «host:path» и падает («Cannot connect to D: resolve failed»),
# поэтому файловые операции делаем в POSIX-видах через cygpath, а в ENV и PATH
# кладём форму C:/... — её понимают и bash, и PowerShell шагов джобы.
work_temp="${RUNNER_TEMP:-/tmp}"
dest="${RUNNER_TOOL_CACHE:?}/flutter/${FLUTTER_VERSION}"
root="$dest/flutter"
if command -v cygpath >/dev/null 2>&1; then
  work_temp="$(cygpath -u "$work_temp")"
  dest="$(cygpath -u "$dest")"
  root="$(cygpath -u "$root")"
  root_env="$(cygpath -m "$root")"
else
  root_env="$root"
fi
if [ ! -f "$root/bin/flutter" ]; then
  url="https://storage.googleapis.com/flutter_infra_release/releases/stable/${os}/flutter_${os}_${FLUTTER_VERSION}-stable.${ext}"
  mkdir -p "$dest"
  echo "Flutter: скачиваем $url"
  curl -fsSL --retry 3 -o "$work_temp/flutter-sdk.$ext" "$url"
  # tar из Git for Windows (bsdtar) и GNU tar на Linux понимают свой формат;
  # zip распаковываем тем же tar — так шаг не зависит от наличия unzip.
  tar -xf "$work_temp/flutter-sdk.$ext" -C "$dest"
fi

[ -f "$root/bin/flutter" ] || { echo "::error::Flutter не установился в $root"; exit 1; }
echo "Flutter (скачан): $root_env"
echo "FLUTTER_ROOT=$root_env" >>"$GITHUB_ENV"
echo "$root_env/bin" >>"$GITHUB_PATH"
echo "$root_env/bin/cache/dart-sdk/bin" >>"$GITHUB_PATH"
bash "$root/bin/flutter" --version
