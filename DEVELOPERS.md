# RelayFastVPN — для разработчиков

Техническая документация. Пользовательское описание: [README.md](README.md).

> Некоторые разделы ниже описывают состояние проекта на момент написания; актуальный список
> изменений — в [CHANGELOG.md](CHANGELOG.md).

Свой клиент вместо VPNSpace, по назначению аналог INCY.

* Ядро — **Xray-core** (через AndroidLibXrayLite, как в v2rayNG). Оно же стоит
  на нодах Remnawave, поэтому понимает **VLESS + XHTTP/Reality** и **Hysteria2**.
  Официальный sing-box XHTTP не поддерживает — потому он не подошёл.
* VPN-туннель — встроенный `tun`-inbound Xray (дескриптор отдаёт `VpnService`).
* UI/логика — Flutter; нативный слой — Kotlin.
* Управление — через Remnawave: подписка, шаблоны, брендинг, обновления, kill-switch.

> ⚠️ **Лицензия Hiddify запрещает коммерческое использование**, поэтому ни их
> форк, ни `libhiddify-core.so` из VPNSpace не используются. Xray-core — MPL-2.0,
> AndroidLibXrayLite и код-образцы v2rayNG — GPLv3: при раздаче APK выложите
> исходники сборки (публичный репозиторий). Это не юридическая консультация.

## Что умеет сейчас (Android)

| Функция | Как работает |
|---|---|
| Формат подписки | JSON Xray (массив конфигов или один) и списки ссылок (base64 или текст): `vless://` (в т.ч. xhttp, reality, ws, grpc), `trojan://`, `ss://`, `hysteria2://`/`hy2://`. Битые строки пропускаются |
| Серверы | Список из подписки, выбор, горячая смена без разрыва туннеля, замер задержки |
| Трафик/срок | Заголовок `subscription-userinfo` |
| Лимит устройств | Отправляется `x-hwid` (Remnawave `require-hwid`) |
| Автообновление | Каждые `profile-update-interval` часов и по кнопке |
| Баннер | Заголовок `announce` (в т.ч. `base64:`) |
| Брендинг, мин. версия, ссылка на APK, kill-switch | Заголовок `x-relayfast-config` (ниже) |
| Маршрутизация | Из JSON-конфигов Remnawave (geoip/geosite из `assets`) |

**Не сделано:** iOS (Network Extension), desktop, QR, раздельное туннелирование,
VMess/TUIC/WireGuard, обфускация Hysteria2 (`obfs`) и multi-port, автообновление
geo-файлов, шифрованное хранилище (сейчас `shared_preferences`), баннеры
`banner-*` и прочие расширенные заголовки INCY.

## Почему не «напрямую в API админки»

Админ-токен Remnawave нельзя класть в APK. Приложение знает только публичную
ссылку подписки пользователя, а «управление через админку» устроено так: вы
меняете настройки в Remnawave (панель или ваш бот через API), приложение
подхватывает их из ответа подписки. Если понадобятся действия из приложения
(оплата, продление) — добавьте тонкий бэкенд между приложением и API панели.

## Настройка Remnawave

1. **User-Agent.** Приложение запрашивает подписку с `User-Agent: RelayFastVPN/<версия>`.
   Для неизвестного UA панель отдаёт base64-список ссылок — это работает сразу,
   но маршрутизация будет простой (только `geoip:private` напрямую). Чтобы отдавать
   JSON-конфиги Xray с вашей маршрутизацией, добавьте в панели правило выбора
   формата для UA `RelayFastVPN` (xray-json).
2. **Удалённый конфиг приложения.** Добавьте в кастомные заголовки подписки
   (название пункта зависит от версии панели) заголовок `x-relayfast-config`:
   JSON либо `base64:<json>`:

```json
{
  "brand":  {"name": "RelayFastVPN", "accent": "#2F7BFF",
             "supportUrl": "https://t.me/your_support", "botUrl": "https://t.me/your_bot"},
  "minBuild": 1,
  "update": {"build": 2, "url": "https://example.com/relayfast.apk", "notes": "Что нового"},
  "kill":   {"enabled": false, "message": "Технические работы"},
  "notice": "Текст баннера на главном экране"
}
```

* `minBuild` — версии ниже блокируются экраном «Обновите приложение».
* `kill.enabled=true` — приложение отключает VPN и показывает сообщение.
* Конфиг кешируется; без доступа к панели действует последнее полученное значение.
* Дублирующийся заголовок `profile-update-interval` лучше оставить один.

## Сборка

GitHub Actions (`.github/workflows/build-android.yml`) делает всё сам:
`tools/bootstrap.sh` (flutter create + наш Android-слой) → `tools/build_xray_core.sh`
(libv2ray.aar) → `tools/fetch_geo.sh` (geoip/geosite) → тесты → APK.
Локально нужны Flutter, Go, JDK 17, Android SDK + NDK r28 — те же скрипты по порядку.

> **Статус проверки.** Сборка ядра и подготовка проекта в Actions уже проходили на
> предыдущей версии; Xray-версия ещё не собиралась и не запускалась на устройстве.
> Kotlin-слой написан по исходникам AndroidLibXrayLite и v2rayNG; первая сборка
> может потребовать мелких правок.

## Структура

```
lib/src/
  models.dart                подписка, удалённый конфиг
  subscription_service.dart  загрузка подписки
  xray_config.dart           разбор подписки (JSON/ссылки) и сборка конфига Xray
  vpn_engine.dart            мост к Kotlin (MethodChannel/EventChannel)
  app_state.dart             состояние приложения
  screens/                   импорт, главный, серверы, блокировка
android_overlay/kotlin/      VpnSvc, XrayCore, MainActivity, VpnBus
tools/                       bootstrap.sh, build_xray_core.sh, fetch_geo.sh
```

## Что есть в приложении

- Несколько подписок, переключение в карточке подписки; обновление по кнопке, свайпом, при возврате в приложение и по `profile-update-interval`.
- Проверка серверов только по нажатию: GET `https://www.gstatic.com/generate_204` через сервер (адрес меняется в настройках). Кнопка «Проверить соединение» работает через уже поднятый туннель.
- Режим «Авто»: проверяются все серверы, пробуются три самых быстрых.
- Раздельное туннелирование: выбранные приложения мимо VPN или через VPN только выбранные.
- Добавление подписки: ссылка, буфер обмена, QR-код, ссылка `relayfast://import?url=…`.
- Тема: тёмная, светлая, как в системе. «Подключаться при запуске».
- Приложение шлёт в Remnawave `x-hwid`, `x-device-os`, `x-ver-os`, `x-device-model`.

## Секреты сборки

В Settings → Secrets and variables → Actions → Secrets: `KEYSTORE_B64`, `KEYSTORE_PASS`, `KEY_ALIAS` (подпись APK)
и `BILLING_URL` (адрес прокси оплаты, подставляется в приложение при сборке; без него вкладка «Оплата» не работает).

## Подпись APK и релизы

В репозитории: Settings → Secrets and variables → Actions → New repository secret, три секрета:
`KEYSTORE_B64`, `KEYSTORE_PASS`, `KEY_ALIAS`. Тогда каждая сборка подписывается одним и тем же ключом
и новую версию можно ставить поверх старой. Файл ключа хранить в надёжном месте: потерянный ключ не восстановить.
Каждая сборка публикуется в Releases как `build-N` с APK для трёх архитектур.

## Настройка из админки Remnawave

Заголовок `x-relayfast-config` (JSON или `base64:<json>`) задаёт название, цвет, баннер, kill-switch, минимальную версию
и ссылку на обновление. Поля: `brand{name,accent,supportUrl,botUrl}`, `minBuild`, `update{build,url,notes}`,
`kill{enabled,message}`, `notice`. Версия сборки (`build`) равна номеру запуска Actions.

## Windows

Та же кодовая база Flutter, VPN-часть своя (`lib/src/windows/`): приложение запускает
ядро Xray (`core\rf-core.exe`) и включает один из двух режимов.

- **Системный прокси** (по умолчанию): права администратора не нужны, трафик браузеров и
  большинства программ идёт через VPN. Прежние настройки прокси возвращаются при отключении.
- **TUN (бета)**: весь трафик через виртуальный адаптер Wintun. Нужен запуск от имени
  администратора (в настройках есть кнопка «Перезапустить от имени администратора»).

Сборка: GitHub Actions → workflow `build-windows` (Run workflow). В Releases появятся
`RelayFastVPN-Setup.exe` (установщик) и `RelayFastVPN-windows-portable.zip`.
Скачиваются последний Xray-core, Wintun и geo-списки (как в Android-версии).

Не поддерживается на Windows: сканирование QR, выбор приложений для раздельного
туннелирования, ссылки `relayfast://` (подписку вставляют из буфера).
