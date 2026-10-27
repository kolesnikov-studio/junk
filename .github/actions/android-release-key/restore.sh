#!/usr/bin/env bash
# Постоянный ключ подписи Android из секретов репозитория (D-264/D-308).
#
# Почему так, а не key.properties в репозитории: .jks и пароли — секрет, их
# место в GitHub Secrets (ANDROID_KEYSTORE_BASE64 и три значения ниже). Секрет
# пишется в $RUNNER_TEMP (стирается вместе с рабочим каталогом прогона) и
# удаляется отдельным шагом джобы.
#
# Без ключа джоба падает здесь, а не выпускает APK, подписанный debug-ключом:
# такой APK не встаёт поверх установленного после смены учётки/машины.
set -euo pipefail

missing=""
for name in KEYSTORE_BASE64 KEYSTORE_PASSWORD KEY_ALIAS KEY_PASSWORD; do
  if [ -z "${!name:-}" ]; then
    missing="${missing} ${name}"
  fi
done
if [ -n "$missing" ]; then
  echo "::error::Не заданы секреты:${missing} — release-APK без постоянной подписи не собирается (D-264)"
  exit 1
fi

temp_dir="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
# На Windows-раннере путь вида C:\... — Gradle принимает и его, но смешанные
# разделители читаются хуже: приводим к виду C:/... через cygpath, если он есть.
case "$temp_dir" in
  [A-Za-z]:*) if command -v cygpath >/dev/null 2>&1; then temp_dir="$(cygpath -m "$temp_dir")"; fi ;;
esac
keystore="$temp_dir/kopilka-release.jks"

printf '%s' "$KEYSTORE_BASE64" | base64 -d > "$keystore"
if [ ! -s "$keystore" ]; then
  echo "::error::Секрет ANDROID_KEYSTORE_BASE64 пуст после декодирования — проверьте, что в нём base64 от .jks"
  exit 1
fi

# Раннее доказательство, что секреты согласованы: файл открывается паролем и
# содержит нужный alias. Иначе сборка упала бы уже внутри Gradle на подписи.
if command -v keytool >/dev/null 2>&1; then
  if ! keytool -list -keystore "$keystore" -storepass "$KEYSTORE_PASSWORD" -alias "$KEY_ALIAS" >/dev/null 2>&1; then
    echo "::error::Ключ не открывается: пароль хранилища или alias не совпадают с файлом (D-264)"
    exit 1
  fi
  echo "Ключ подписи распакован: alias $KEY_ALIAS, файл $keystore"
else
  echo "::warning::keytool не найден — согласованность секретов проверит Gradle"
fi

{
  echo "ANDROID_KEYSTORE_PATH=$keystore"
  echo "ANDROID_KEYSTORE_PASSWORD=$KEYSTORE_PASSWORD"
  echo "ANDROID_KEY_ALIAS=$KEY_ALIAS"
  echo "ANDROID_KEY_PASSWORD=$KEY_PASSWORD"
} >> "$GITHUB_ENV"
