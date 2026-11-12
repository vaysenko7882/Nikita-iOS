# Autismex for iPhone

Нативные SwiftUI-экраны статуса и истории, циферблат суток, экспорт CSV,
вкладка с полным сайтом. Подключение к https://autismex.best по HTTPS.
Минимальная версия — iOS 17. Liquid Glass включается на iOS 26 и новее;
на старых версиях используется системный material.

Приложение не содержит Telegram-сессии и API_HASH. Статистику продолжает
собирать VPS круглосуточно. Приложение запрашивает готовую статистику
раз в секунду, пока находится на экране; iOS не запускает этот опрос
непрерывно в фоне. Скрытые/устаревшие статусы отмечаются как «Нет данных».

GitHub Actions собирает настоящий iphoneos arm64 Release и упаковывает
`Autismex-unsigned.ipa`. Файл намеренно не подписан: перед установкой его
нужно подписать своим сертификатом и подходящим provisioning profile.
Bundle identifier: `best.autismex.presence`.

Локальная сборка на Mac с Xcode 26+:

```sh
bash scripts/build-ipa.sh
```

В GitHub открой Actions → Build Autismex IPA → нужный успешный запуск →
artifact `Autismex-unsigned-ipa`. Распакуй ZIP, возьми IPA и подпиши его.
Для этой сборки не требуются Apple ID, сертификат или пароль в GitHub.
