# Spec: iOS App Transfer (iTransfer)

**Version:** 1.0
**Date:** 2026-04-06
**Status:** Draft
**Feature slug:** `ios-app-transfer`

---

## 1. Цель

Позволить пользователю переносить iOS-приложения с одного iPhone на другой прямо через Spacie на Mac. Основной кейс — сохранение и переустановка приложений, удалённых из App Store (банковские, региональные и прочие).

---

## 2. Контекст в кодовой базе

### Текущая архитектура Spacie
- **Platform**: macOS 15+ (Sequoia), Swift 6, SwiftUI + @Observable MVVM
- **Build targets**: Direct (DMG) + MAS (App Store)
- **Entry**: `Spacie/App/SpacieApp.swift`, главный экран — `ContentView.swift`
- **Features**: `Features/` — Scan, Visualization, FileList, Duplicates, SmartCategories, DropZone, StorageBrowser, StorageOverview
- **Существующий activePanel**: Используется для переключения между Visualization / FileList / Duplicates / SmartCategories внутри сессии сканирования

### Точки интеграции
- `ContentView.swift` — нужна реструктуризация: добавить уровень HomeView поверх
- `SpacieApp.swift` — добавить новый WindowGroup или NavigationSplitView для новых разделов
- `Spacie/App/SettingsView.swift` — добавить настройку пути к архиву .ipa
- **Только Direct target** — MAS sandbox запрещает USB-коммуникацию с устройствами; фича скрыта в MAS-сборке

---

## 3. Архитектурные изменения

### 3.1. Spacie 2.0: Главный экран (HomeView)

Текущий `ContentView.swift` становится `DiskAnalyzerView.swift` (переименование).
Новый `HomeView.swift` — стартовый экран с плитками:

```
┌─────────────────────────────────────────────────────┐
│                    Spacie 2.0                        │
│                                                     │
│  ┌─────────────────┐    ┌─────────────────┐         │
│  │  💿 Disk        │    │  📱 iOS         │         │
│  │  Analyzer       │    │  Transfer       │         │
│  │                 │    │                 │         │
│  │ Анализ диска,   │    │ Перенос приложений│        │
│  │ дубликаты,      │    │ между iPhone     │        │
│  │ очистка         │    │                 │         │
│  └─────────────────┘    └─────────────────┘         │
│                                                     │
└─────────────────────────────────────────────────────┘
```

**Навигация:** HomeView → кнопка «Назад» возвращает на HomeView из любого режима.

### 3.2. Новые файлы

```
Spacie/
├── App/
│   ├── HomeView.swift              # Новый стартовый экран (плитки)
│   └── ContentView.swift           # Переименовать → DiskAnalyzerView.swift
├── Core/
│   └── iMobileDevice/
│       ├── iMobileDeviceService.swift     # Swift-обёртка вокруг CLI
│       ├── iMobileDeviceModels.swift      # DeviceInfo, AppInfo, TransferProgress
│       └── iMobileDeviceDependency.swift  # Проверка/установка libimobiledevice
├── Features/
│   └── iTransfer/
│       ├── iTransferView.swift           # Главный экран iOS Transfer
│       ├── iTransferViewModel.swift      # @Observable ViewModel
│       ├── Steps/
│       │   ├── DependencyCheckView.swift # Шаг 0: libimobiledevice
│       │   ├── ConnectSourceView.swift   # Шаг 1: подключить iPhone-источник
│       │   ├── AppListView.swift         # Шаг 2: список приложений + выбор
│       │   ├── ConnectDestView.swift     # Шаг 3: подключить iPhone-назначение
│       │   └── TransferProgressView.swift # Шаг 4: перенос + результат
│       └── Archive/
│           ├── AppArchiveView.swift      # UI: список сохранённых .ipa
│           └── AppArchiveViewModel.swift  # @Observable
```

---

## 4. Зависимости: libimobiledevice

### Инструменты
- `idevice_id` — список подключённых устройств
- `ideviceinstaller` — список приложений, установка .ipa
- `ideviceinfo` — информация об устройстве (UDID, имя, версия iOS)
- `idevicescreenshot` — скриншот для иллюстрации Trust

Все через Homebrew:
```
brew install libimobiledevice ideviceinstaller
```

### Проверка зависимостей (iMobileDeviceDependency.swift)
```swift
func checkDependencies() -> DependencyStatus {
    // which ideviceinstaller → path or nil
    // which idevice_id → path or nil
}

func installDependencies() {
    // Открыть Terminal.app через NSWorkspace/AppleScript
    // Запустить: brew install libimobiledevice ideviceinstaller
    // Ждать завершения (периодически перепроверять which)
}
```

**UX при отсутствии зависимостей:**
1. Sheet с текстом: "Для работы iOS Transfer требуется установить зависимости"
2. Кнопка "Установить автоматически" → Spacie открывает Terminal и запускает brew install
3. Кнопка "Установить вручную" → показывает команду + Copy
4. После установки — автопроверка каждые 2 секунды (polling)
5. Если Homebrew не установлен → ссылка на brew.sh

### Только Direct Build
- В MAS-таргете `iTransferView` не включается в билд (`#if !APPSTORE`)
- На HomeView плитка iOS Transfer не отображается в MAS-сборке

---

## 5. Технический стек: iMobileDeviceService

Весь доступ к устройствам — через CLI tools (не C API напрямую).
Swift вызывает через `Foundation.Process`.

```swift
@Observable
final class iMobileDeviceService: Sendable {
    func listDevices() async throws -> [DeviceInfo]       // idevice_id -l
    func getDeviceInfo(udid: String) async throws -> DeviceInfo   // ideviceinfo -u <udid>
    func listApps(udid: String) async throws -> [AppInfo] // ideviceinstaller -u <udid> -l
    func extractIPA(udid: String, bundleID: String, dest: URL) async throws -> URL  // AFC
    func installIPA(udid: String, ipaPath: URL) async throws  // ideviceinstaller -u <udid> -i <ipa>
    func waitForDevice() -> AsyncStream<DeviceEvent>      // polling idevice_id каждые 2с
}
```

### AppInfo модель
```swift
struct AppInfo: Identifiable, Sendable {
    let bundleID: String                // com.sberbank.online
    let displayName: String             // СберБанк
    let version: String                 // 15.3.1
    let ipaSize: UInt64?                // размер на устройстве
    let iconData: Data?                 // иконка 60x60 из IPA
    var id: String { bundleID }
}
```

### DeviceInfo модель
```swift
struct DeviceInfo: Identifiable, Sendable {
    let udid: String
    let deviceName: String              // "Мой iPhone"
    let productType: String             // iPhone16,1
    let productVersion: String          // 18.3.1
    var id: String { udid }
}
```

---

## 6. UX-флоу: 5 шагов (Wizard)

### Шаг 0: Проверка зависимостей (автоматически при открытии раздела)
- Если `ideviceinstaller` доступен → сразу Шаг 1
- Если нет → `DependencyCheckView` с инструкцией

### Шаг 1: Подключи iPhone-источник
- Ожидание подключения (анимированный индикатор)
- Polling `idevice_id -l` каждые 2 секунды
- При обнаружении → `ideviceinfo` за деталями
- Если устройство не trusted:
  - Sheet "Разрешить доступ на iPhone":
    ```
    Шаги:
    1. На iPhone появится диалог
    2. Нажмите «Доверять» / «Trust»
    3. Введите пасскод iPhone
    [Иллюстрация: схематичный iPhone с диалогом Trust]
    ```
- После trust → загрузить список приложений (`ideviceinstaller -l`)

### Шаг 2: Список приложений + выбор
```
┌─────────────────────────────────────────────────────┐
│ iPhone Артёма  (iOS 18.3.1)         [Поиск...]      │
├─────────────────────────────────────────────────────┤
│ ☑ [🏦] СберБанк            15.3.1   48 MB           │
│ ☑ [💳] Тинькофф            6.12.0   52 MB           │
│ ☐ [📺] YouTube             19.2.1   85 MB           │
│ ☐ [🎵] Spotify             8.9.46   156 MB          │
│ ...                                                 │
├─────────────────────────────────────────────────────┤
│ Выбрано: 2  |  Размер: ~100 MB                      │
│ [Выбрать все]  [Только удалённые из App Store]      │
│                              [Далее →]              │
└─────────────────────────────────────────────────────┘
```

**Иконки:** Извлекаются из .ipa-бандла (Assets.car → CFBundleIconFiles).
**Размер:** Из `ideviceinstaller -l` вывода или из .ipa.
**"Только удалённые":** Фильтрация невозможна без App Store API → не реализовывать.

### Шаг 3: Отключи источник, подключи iPhone-назначение
- Инструкция: "Отключи iPhone-источник и подключи новый iPhone"
- Polling для нового устройства (проверяем что UDID другой)
- Аналогичный Trust-флоу для нового устройства

### Шаг 4: Перенос
```
┌─────────────────────────────────────────────────────┐
│ Перенос приложений...                               │
│                                                     │
│ [📱] iPhone → Mac → [📱] iPhone нового              │
│                                                     │
│ СберБанк:      ██████████████░░░░ 75% (извлечение)  │
│ Тинькофф:      ░░░░░░░░░░░░░░░░░░  0% (ожидание)   │
│                                                     │
│ Архивировать .ipa: [✓] Сохранить в ~/Documents/... │
└─────────────────────────────────────────────────────┘
```

**Процесс на каждое приложение:**
1. Извлечь .ipa с iPhone-источника (AFC или `ideviceinstaller --extract`) → temp dir
2. Если "Архивировать" включено → скопировать в `<archiveDir>/<bundleID>/<version>/<name>.ipa` + `metadata.json`
3. Установить .ipa на iPhone-назначение: `ideviceinstaller -u <dest-udid> -i <ipa>`
4. Удалить temp файл

**FairPlay warning:** "Установка пройдёт успешно только если оба iPhone используют один Apple ID (DRM-ограничение)"

### Шаг 5: Результат
- Список перенесённых приложений (Success ✅ / Failed ❌)
- Кнопка "Перенести ещё"
- Кнопка "Открыть архив"

---

## 7. App Archive (Библиотека .ipa)

### UI
```
┌─────────────────────────────────────────────────────┐
│ 📦 App Archive              [Добавить .ipa] [⚙]     │
│ ~/Documents/Spacie App Archive (2.1 GB)             │
├─────────────────────────────────────────────────────┤
│ [🏦] СберБанк                                       │
│      15.3.1  •  48 MB  •  Сохранено: 06.04.2026    │
│      com.sberbank.online          [Установить] [🗑] │
│                                                     │
│ [💳] Тинькофф                                       │
│      6.12.0  •  52 MB  •  Сохранено: 06.04.2026    │
│      com.tinkoff.bank             [Установить] [🗑] │
└─────────────────────────────────────────────────────┘
```

### Структура архива на диске
```
<archiveDir>/
└── com.sberbank.online/
    └── 15.3.1/
        ├── SberBank.ipa
        └── metadata.json
```

### metadata.json
```json
{
  "bundleID": "com.sberbank.online",
  "displayName": "СберБанк",
  "version": "15.3.1",
  "ipaSize": 50331648,
  "archivedAt": "2026-04-06T12:00:00Z",
  "sourceDevice": "iPhone 15 Pro (iOS 18.3.1)",
  "iconData": "<base64>"
}
```

### Настройка пути
- По умолчанию: `~/Documents/Spacie App Archive/`
- Изменить: Settings → iOS Transfer → "App Archive Location" → NSOpenPanel
- Хранится в UserDefaults

---

## 8. Извлечение .ipa: технические детали

### Метод: ideviceinstaller
```bash
# Список приложений
ideviceinstaller -u <UDID> -l -o xml

# Извлечение (если поддерживается версией)
ideviceinstaller -u <UDID> --extract <bundleID> --output /tmp/spacie/
```

> ⚠️ **Важно:** `ideviceinstaller --extract` может не поддерживаться в некоторых версиях.
> Fallback: использовать `ifuse` для монтирования `/var/mobile/Containers/Bundle/Application/`
> и копирования `.app` бандла, затем упаковать в .ipa вручную (zip + Payload/ структура).

### IPA структура (для ручной упаковки)
```
<app-name>.ipa  (zip)
└── Payload/
    └── <app-name>.app/
```

### Иконки
- Из бандла: `<app>.app/AppIcon60x60@2x.png` или через `CFBundleIconFiles`
- Fallback: SF Symbol `app.fill`

---

## 9. Разрешения и безопасность

### Entitlements (Direct build)
- `com.apple.security.automation.apple-events` — для открытия Terminal
- Нет sandbox → нет ограничений на USB-коммуникацию

### MAS Build
- Фича полностью скрыта через `#if !APPSTORE` compile flag
- `iTransferView` не компилируется в MAS-таргет

### Хранилище pairing records
- libimobiledevice хранит pairing в `/var/db/lockdown/` или `~/Library/Lockdown/`
- Доступно без sudo в Direct build

### FairPlay DRM
- .ipa зашифрован FairPlay, привязан к Apple ID
- Установка сработает только на устройства с тем же Apple ID
- UI показывает предупреждение на Шаге 4

---

## 10. Ошибки и edge cases

| Ситуация | Поведение |
|---|---|
| iPhone отключился во время извлечения | Показать ошибку, предложить повторить |
| Trust не дан (timeout 30с) | "Не получен ответ. Разблокируй iPhone и повтори" |
| ideviceinstaller не поддерживает --extract | Fallback на ifuse mount |
| .ipa уже в архиве (та же версия) | "Уже архивировано. Перезаписать?" |
| Destination iPhone — тот же что Source | Предупреждение "Это то же устройство" |
| Установка провалилась (DRM) | "Убедись что оба iPhone используют один Apple ID" |
| Нет места в архивной папке | Показать сколько нужно / сколько есть |
| Homebrew не установлен | Ссылка на brew.sh + инструкция |

---

## 11. Локализация

- Все строки в `Localizable.xcstrings`
- Ключи в namespace `iTransfer.*`
- Языки: EN + RU (как во всём Spacie)

---

## 12. Затронутые файлы (существующие)

| Файл | Изменение |
|---|---|
| `Spacie/App/SpacieApp.swift` | Изменить WindowGroup root view на HomeView |
| `Spacie/App/ContentView.swift` | Переименовать в DiskAnalyzerView.swift |
| `Spacie/App/SettingsView.swift` | Добавить секцию "iOS Transfer" с настройкой пути архива |
| `Spacie.xcodeproj/project.yml` | Добавить новые файлы, APPSTORE compile flag |
| `Resources/Localizable.xcstrings` | Добавить iTransfer.* строки |

---

## 13. Не входит в скоуп (v1)

- Перенос данных приложений (Documents, Library) — сложно, требует iTunes encrypted backup
- WiFi-подключение устройств (только USB)
- Поддержка нескольких версий одного .ipa одновременно (только последняя)
- Автоматическое определение "удалённых из App Store" приложений
- Работа с несколькими Apple ID
- MAS-вариант функции

---

## 14. Решения

| # | Вопрос | Решение |
|---|---|---|
| 1 | Протокол подключения | USB через libimobiledevice CLI (Homebrew) |
| 2 | Интеграция библиотеки | Homebrew + Spacie auto-install через Terminal |
| 3 | Что переносить | Только .ipa (без данных приложений) |
| 4 | FairPlay | Одинаковый Apple ID на обоих устройствах |
| 5 | Архив | Да, хранить локально: `<bundle>/<version>/<name>.ipa` |
| 6 | Место хранения | NSOpenPanel, по умолчанию ~/Documents/Spacie App Archive/ |
| 7 | Главный экран | HomeView с плитками, новый уровень навигации |
| 8 | MAS | Фича скрыта (`#if !APPSTORE`) |
| 9 | Trust flow | Инструкция + иллюстрация в Sheet |
| 10 | Homebrew | Spacie открывает Terminal, запускает brew install |
