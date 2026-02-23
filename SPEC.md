# Spacie — Specification

**Version:** 1.0
**Date:** 2026-02-23
**Status:** Approved

---

## 1. Overview

**Spacie** — нативное macOS-приложение для анализа дискового пространства, оптимизированное под Apple Silicon. Позволяет визуализировать занятое место, находить большие файлы, дубликаты, кэши и безопасно удалять ненужное.

**Лицензия:** Non-Commercial (бесплатное использование, коммерция запрещена)
**Референс:** DaisyDisk (основной)

---

## 2. Platform & Distribution

| Параметр | Значение |
|---|---|
| Минимальная macOS | 15.0 (Sequoia) |
| Архитектура | Apple Silicon (arm64), Universal Binary |
| Язык | Swift 6+ |
| UI Framework | SwiftUI + Canvas (Metal-backed) |
| Архитектура приложения | MVVM + @Observable |
| Build system | Xcode project (два targets: MAS + Direct) |
| Локализация | EN + RU (String Catalogs .xcstrings) |
| Тесты | Unit tests (XCTest) |

### 2.1. Дистрибуция

Два канала параллельно:

**Mac App Store:**
- App Sandbox enabled
- Ограниченный доступ к FS (через user-selected files + bookmarks)
- Full Disk Access через entitlement `com.apple.security.temporary-exception.files.absolute-path.read-only` (если одобрят)
- StoreKit для отзывов/рейтинга

**Direct (DMG):**
- Без sandbox
- Full Disk Access через TCC prompt
- Нотаризация через Apple notarytool
- Подпись Developer ID
- Sparkle framework для автообновлений

### 2.2. Entitlements

**Общие:**
- `com.apple.security.files.user-selected.read-write`

**MAS-only:**
- `com.apple.security.app-sandbox` = true
- `com.apple.security.files.bookmarks.app-scope`

**Direct-only:**
- Без sandbox
- `com.apple.security.automation.apple-events` (для Reveal in Finder)

---

## 3. Architecture

### 3.1. Module Structure

```
Spacie/
├── App/                        # App entry point, WindowGroup, tabs
├── Core/
│   ├── Scanner/                # POSIX scanner (fts), async pipeline
│   ├── FileTree/               # In-memory tree (arena-based, flat arrays)
│   ├── Cache/                  # Persistent cache + FSEvents invalidation
│   ├── Duplicates/             # Progressive duplicate finder
│   └── SystemInfo/             # APFS volumes, purgeable, snapshots
├── Features/
│   ├── Scan/                   # Scan initiation, volume picker
│   ├── Visualization/
│   │   ├── Sunburst/           # Radial treemap (Canvas)
│   │   └── Treemap/            # Rectangular treemap (Canvas)
│   ├── FileList/               # Large files, filtered lists, search
│   ├── Duplicates/             # Duplicate groups UI
│   ├── SmartCategories/        # Caches, logs, dev tools
│   ├── DropZone/               # Delete staging area
│   └── StorageOverview/        # System categories, recommendations
├── Plugins/
│   ├── Protocol/               # CleanupCategory protocol
│   └── BuiltIn/               # Xcode, Docker, brew, npm, etc.
├── Shared/
│   ├── Models/                 # FileNode, VolumeInfo, ScanResult
│   ├── Extensions/             # Foundation, SwiftUI extensions
│   └── Theme/                  # Colors, fonts, native styling
├── Resources/
│   ├── Localizable.xcstrings   # EN + RU
│   └── Assets.xcassets
└── Tests/
    ├── ScannerTests/
    ├── FileTreeTests/
    ├── DuplicateTests/
    └── CacheTests/
```

### 3.2. MVVM + @Observable

```swift
// Каждый Feature содержит:
// - View (SwiftUI)
// - ViewModel (@Observable class)
// - Зависимости через init injection

@Observable
final class ScanViewModel {
    var state: ScanState = .idle
    var progress: ScanProgress?
    var tree: FileTree?

    private let scanner: DiskScanner
    private let cache: ScanCache

    func startScan(volume: VolumeInfo) async { ... }
    func cancelScan() { ... }
}
```

### 3.3. Сервисы

Основные сервисы — синглтоны через Environment:

| Сервис | Ответственность |
|---|---|
| `DiskScanner` | POSIX-сканирование, async stream результатов |
| `ScanCache` | Персистентный кэш + FSEvents инвалидация |
| `DuplicateFinder` | Прогрессивное хеширование дубликатов |
| `TrashManager` | Перемещение в Trash, blocklist проверка |
| `VolumeManager` | Список томов, APFS info, purgeable |
| `PluginManager` | Загрузка и выполнение cleanup-плагинов |
| `PermissionManager` | FDA check, TCC status, graceful degradation |

---

## 4. Scan Engine

### 4.1. POSIX Scanner (fts/opendir)

Основа — `fts_open` / `fts_read` для максимальной скорости на миллионах файлов.

**Pipeline:**
1. `fts_open` с `FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV`
2. Обход дерева в `Task` на фоновом потоке
3. Результаты стримятся через `AsyncStream<ScanEvent>`
4. UI обновляется по батчам (throttle ~16ms / 60fps)

**ScanEvent:**
```swift
enum ScanEvent {
    case directoryEntered(path: String, depth: Int)
    case fileFound(node: RawFileNode)
    case directoryCompleted(path: String, totalSize: UInt64)
    case progress(ScanProgress)
    case error(path: String, error: POSIXError)
    case completed(stats: ScanStats)
}
```

**Права доступа:**
- Недоступные директории (EACCES) — помечаются как "Restricted"
- UI показывает баннер "Grant Full Disk Access for complete scan"
- Ссылка на System Settings > Privacy > Full Disk Access

### 4.2. Размеры файлов

- `stat.st_size` — logical size (отображается по умолчанию)
- `stat.st_blocks * 512` — physical size (disk usage)
- Toggle в toolbar переключает режим
- APFS clones: physical = 0 для клонированных блоков
- Hard links: считать размер только один раз (по inode)

### 4.3. Производительность

**Целевые метрики:**
- 1M файлов: < 10 секунд на SSD
- 5M файлов: < 60 секунд на SSD
- RAM: < 500MB при 5M файлов

**Memory-efficient tree:**
- Arena allocator для FileNode (contiguous memory)
- Flat array + parent index вместо pointer-based tree
- Строки (paths) — interned или relative к parent
- Размер одного узла: target ~64 байт

```swift
struct FileNode {
    let nameOffset: UInt32      // offset в string pool
    let nameLength: UInt16      // длина имени
    let parentIndex: UInt32     // индекс родителя в массиве
    let firstChildIndex: UInt32 // первый ребёнок (0 = нет)
    let nextSiblingIndex: UInt32 // следующий sibling (0 = нет)
    let logicalSize: UInt64     // logical size
    let physicalSize: UInt64    // physical (blocks * 512)
    let flags: FileNodeFlags    // тип, permissions, etc.
    let modTime: UInt32         // modification time (unix)
    let childCount: UInt16      // кол-во прямых детей
}
// ~48 байт на узел → 5M узлов = ~240MB
```

---

## 5. Cache System

### 5.1. Persistent Cache

- Формат: Binary (custom, не JSON — скорость важнее)
- Расположение: `~/Library/Caches/com.spacie.app/`
- Один файл на volume: `<volume-uuid>.cache`
- Содержит: полное дерево + metadata (scan date, file count)

### 5.2. Incremental Update

- FSEvents мониторинг запускается после успешного скана
- При изменениях — помечает dirty поддеревья
- При повторном скане — пересканирует только dirty
- `FSEventStreamCreate` с `kFSEventStreamCreateFlagFileEvents`

### 5.3. Инвалидация

- При запуске: проверить `lastScanDate` vs текущее время
- Если > 24ч — показать "Data may be outdated, rescan?"
- При внешнем изменении (FSEvents) — баннер "Files changed, refresh?"
- Полная инвалидация при смене volume UUID (переформатирование)

---

## 6. Visualization

### 6.1. Sunburst (Radial Treemap)

- Центр = текущий корень (drill-down)
- Кольца = уровни вложенности
- Угол сегмента = пропорционален размеру
- Максимум 4-5 колец видимых одновременно
- Мелкие сегменты (< 1% от кольца) группируются в "Other"

**Рендеринг:**
- SwiftUI Canvas (GPU-accelerated)
- Кастомные Path для каждого сегмента (arc)
- Анимация при drill-down (zoom transition)

### 6.2. Treemap (Rectangular)

- Squarified Treemap алгоритм
- Прямоугольники с текстом (имя + размер если влезает)
- Вложенные директории — nested rectangles с border
- Максимум 3 уровня видимых одновременно

**Рендеринг:**
- SwiftUI Canvas
- Layout на CPU → рисование на GPU
- Кэширование layout при resize (debounce)

### 6.3. Общее

**Переключение:**
- Toolbar segmented control: Sunburst / Treemap
- Анимированный переход между режимами

**Цветовая схема — по типу файлов:**

| Тип | Цвет |
|---|---|
| Video | Синий (#4A90D9) |
| Audio | Фиолетовый (#9B59B6) |
| Images | Зелёный (#27AE60) |
| Documents | Оранжевый (#E67E22) |
| Archives | Красный (#E74C3C) |
| Code/Dev | Жёлтый (#F1C40F) |
| Applications | Бирюзовый (#1ABC9C) |
| System | Серый (#95A5A6) |
| Other | Light Gray (#BDC3C7) |

- Вложенные файлы: тот же hue, но lighter/darker оттенок
- Dark mode: те же hue, скорректированная яркость
- Используются system-compatible цвета (адаптируются к Increase Contrast)

**Интерактивность:**
- Hover: подсветка сегмента + tooltip (имя, размер, тип)
- Click: drill-down (директория → новый корень)
- Right-click: контекстное меню (Reveal in Finder, Delete, Copy Path, Info)
- Breadcrumb bar сверху для навигации назад

### 6.4. Live-визуализация при сканировании

- Диаграмма строится инкрементально по мере поступления данных
- Throttle UI-обновлений: batch каждые ~100ms
- Анимированное появление новых сегментов (fade-in + grow)
- Progress bar внизу: % отсканированных файлов + ETA
- Текст: "Scanning /Users/... (234,567 files, 128 GB)"

---

## 7. Navigation & Window Model

### 7.1. Window

- Одно главное окно
- macOS native tab support (`NSWindow.tabbingMode = .preferred`)
- Каждый tab = один скан / один том
- Toolbar: volume picker, scan button, viz toggle, size mode toggle, search

### 7.2. Drill-down

- Click на директорию → она становится корнем диаграммы
- Breadcrumb bar: `Macintosh HD > Users > username > Documents`
- Click на breadcrumb → jump к тому уровню
- Back button / swipe gesture / Cmd+[ для навигации назад
- History stack для forward/back

### 7.3. Layout

```
┌──────────────────────────────────────────────┐
│ Toolbar: [Volume ▼] [Scan] [◉ ▦] [Logical ▼] │
│          [Search...] [▶ Reveal] [🗑 Drop Zone]│
├──────────────────────────────────────────────┤
│ Breadcrumb: Macintosh HD > Users > dev       │
├──────────────────────────────────────────────┤
│                                              │
│            Visualization Area                │
│          (Sunburst or Treemap)               │
│                                              │
│                                              │
├──────────────────────────────────────────────┤
│ Info bar: 1,234,567 files | 456 GB used |    │
│           128 GB free | Scan: 5s ago         │
└──────────────────────────────────────────────┘
```

---

## 8. Features

### 8.1. Large Files Finder

Два режима (переключаемые):

**Top-N:**
- Top 50 / 100 / 500 самых больших файлов
- Отсортированы по размеру (desc)

**Threshold:**
- По умолчанию: > 100MB
- Настраиваемый: 10MB, 50MB, 100MB, 500MB, 1GB (picker)

**UI:**
- Отдельная вкладка / panel
- Таблица: Name, Size, Path, Modified Date, Type
- Sortable по любой колонке
- Quick Look (Space) для preview
- Multi-select + batch delete (в Drop Zone)

### 8.2. Duplicate Finder

**Прогрессивный алгоритм:**
1. **Size grouping** — файлы одинакового размера (мгновенно, из scan data)
2. **Partial hash** — первые 4KB + последние 4KB (SHA-256). Отсеивает ~95% не-дубликатов
3. **Full hash** — полный SHA-256 по запросу (когда пользователь открывает группу)

**UI:**
- Список групп дубликатов, сортировка по "потенциальной экономии"
- Каждая группа: превью файлов, пути, даты
- Auto-select: оставить newest / oldest / shortest path
- Одной кнопкой "Clean" → все выбранные → Drop Zone

**Производительность:**
- Partial hash выполняется в фоне после основного скана
- Progress bar для каждого этапа
- Отмена в любой момент

### 8.3. Smart Categories (Caches/Logs/Temp)

**Встроенные категории (Swift plugins):**

| Категория | Пути | Примерный размер |
|---|---|---|
| Xcode DerivedData | `~/Library/Developer/Xcode/DerivedData/` | 10-100 GB |
| Xcode Archives | `~/Library/Developer/Xcode/Archives/` | 5-50 GB |
| Xcode Device Support | `~/Library/Developer/Xcode/iOS DeviceSupport/` | 5-30 GB |
| CocoaPods cache | `~/Library/Caches/CocoaPods/` | 1-10 GB |
| Homebrew cache | `~/Library/Caches/Homebrew/` | 1-20 GB |
| npm cache | `~/.npm/_cacache/` | 1-10 GB |
| node_modules (all) | `**/node_modules/` | 5-50 GB |
| Docker images | `~/Library/Containers/com.docker.docker/Data/vms/` | 10-100 GB |
| Gradle cache | `~/.gradle/caches/` | 5-30 GB |
| pip cache | `~/Library/Caches/pip/` | 1-5 GB |
| System Logs | `/var/log/`, `~/Library/Logs/` | 0.5-5 GB |
| Crash Reports | `~/Library/Logs/DiagnosticReports/` | 0.1-2 GB |
| Mail Attachments | `~/Library/Mail/` (attachments) | 1-20 GB |
| iOS Backups | `~/Library/Application Support/MobileSync/Backup/` | 10-200 GB |
| Downloads (old) | `~/Downloads/` (> 30 days) | varies |
| Trash | `~/.Trash/` | varies |

**UI:**
- Grid/List категорий с иконками и размером
- Click → список файлов/папок внутри
- "Clean All Safe" → все кэши в Drop Zone
- Отдельный badge если категория > 10GB

### 8.4. Old Files Filter

- Фильтр по дате последнего доступа (`kMDItemLastUsedDate` / `stat.st_atime`)
- Пресеты: > 6 месяцев, > 1 год, > 2 года
- Показывать в отдельном списке с сортировкой по дате

### 8.5. System Overview

Верхняя панель при старте (до drill-down):

```
┌─────────────────────────────────────────┐
│ Macintosh HD (APFS)                     │
│ ████████████████░░░░░ 456 GB / 1 TB     │
│                                         │
│ [Applications: 45GB] [Documents: 120GB] │
│ [System: 15GB] [macOS: 12GB]            │
│ [Other: 80GB] [Purgeable: 25GB]         │
│ [Free: 544GB]                           │
└─────────────────────────────────────────┘
```

**Категории:**
- Applications (`/Applications/`)
- User Data (`~/Documents`, `~/Desktop`, `~/Downloads`, etc.)
- System (`/System/`, `/usr/`, `/bin/`, etc.)
- macOS (system volume, read-only)
- Library (`~/Library/`)
- Other (всё остальное)
- Purgeable (APFS purgeable space via `URLResourceKey.volumeAvailableCapacityForImportantUsageKey`)
- APFS Snapshots (через `diskutil apfs listSnapshots`)
- Free space

**Storage Management Recommendations:**
- Баннер если Trash > 1GB: "Empty Trash to free X GB"
- Если есть purgeable: "X GB can be freed automatically by macOS"
- Ссылка "Open Storage Settings" → `x-apple.systempreferences:com.apple.settings.Storage`

---

## 9. Drop Zone (Deletion)

### 9.1. UX Flow

1. Пользователь перетаскивает файлы/папки на Drop Zone (нижняя панель)
2. Drop Zone показывает список "to delete" с суммарным размером
3. Файлы можно убрать из Zone (undo)
4. Кнопка "Move to Trash" → всё перемещается в Корзину macOS
5. Визуализация обновляется (удалённые сегменты fade out)

### 9.2. Drop Zone UI

```
┌──────────────────────────────────────────┐
│ 🗑 Drop Zone: 3 items, 12.4 GB          │
│ ┌──────┐ ┌──────┐ ┌──────┐              │
│ │ file1│ │ dir2 │ │ arc3 │   [Move to   │
│ │ 5 GB │ │ 4 GB │ │ 3 GB │    Trash]    │
│ └──────┘ └──────┘ └──────┘              │
└──────────────────────────────────────────┘
```

- Drag from visualization / file list / smart categories
- Drag out of Zone = remove from deletion list
- Keyboard: Delete key adds selected to Zone
- Cmd+Z = undo last add to Zone

### 9.3. Safety: Blocklist

**Hardcoded (cannot be deleted):**
- `/System/`
- `/usr/`
- `/bin/`, `/sbin/`
- `/Library/` (system)
- `~/.ssh/`
- `~/Library/Keychains/`
- Любой путь защищённый SIP

**Warning (можно удалить после подтверждения):**
- Dotfiles: `.zshrc`, `.bashrc`, `.gitconfig`, etc.
- `~/Library/Preferences/` (app settings)
- Активные .app bundles

**User-extensible blocklist:**
- Файл `~/.spacie/blocklist.txt` (glob-patterns)
- UI: Settings → Protected Paths → Add/Remove
- Формат: один glob-pattern на строку

```
# User blocklist
~/Projects/**
~/Documents/Important/**
~/.config/karabiner/**
```

---

## 10. Plugin System (Smart Categories)

### 10.1. Protocol

```swift
public protocol CleanupCategory: Identifiable, Sendable {
    var id: String { get }
    var name: LocalizedStringKey { get }
    var description: LocalizedStringKey { get }
    var icon: String { get } // SF Symbol name
    var searchPaths: [CleanupSearchPath] { get }

    /// Опционально: кастомная логика для определения "можно ли удалить"
    func canSafelyDelete(item: URL) async -> Bool

    /// Опционально: какие под-элементы показать пользователю
    func detailedItems(at path: URL) async -> [CleanupItem]
}

public struct CleanupSearchPath: Sendable {
    let path: String          // Абсолютный путь или ~ для home
    let glob: String?         // Опциональный glob-паттерн
    let recursive: Bool       // Искать рекурсивно
    let minAge: TimeInterval? // Минимальный возраст файла
}
```

### 10.2. Пример встроенного плагина

```swift
struct XcodeDerivedDataCategory: CleanupCategory {
    let id = "xcode-derived-data"
    let name: LocalizedStringKey = "Xcode DerivedData"
    let description: LocalizedStringKey = "Build artifacts and index data"
    let icon = "hammer.fill"

    var searchPaths: [CleanupSearchPath] {
        [CleanupSearchPath(
            path: "~/Library/Developer/Xcode/DerivedData",
            glob: nil,
            recursive: false,
            minAge: nil
        )]
    }

    func detailedItems(at path: URL) async -> [CleanupItem] {
        // Показать по-проектные папки с размерами
    }
}
```

### 10.3. Регистрация плагинов

- Встроенные: регистрируются в `PluginManager.registerBuiltIn()`
- Внешние: Swift Packages, подключаемые в Xcode project
- Порядок отображения: по размеру (desc)

---

## 11. Volume Management

### 11.1. Volume Discovery

- `FileManager.mountedVolumeURLs(includingResourceValuesForKeys:options:)`
- Мониторинг mount/unmount через `NSWorkspace.didMountNotification`
- Отображаемая информация:
  - Name, mount point
  - Total / Used / Free / Purgeable
  - File system type (APFS, HFS+, ExFAT, etc.)
  - Internal / External / Network

### 11.2. Multi-Volume UI

- Volume picker в toolbar (dropdown)
- Каждый том = отдельный tab (auto-create при выборе)
- Start screen: grid всех доступных томов с usage bars

### 11.3. Network Volumes

- Поддерживаются, но с warning "Network scan may be slow"
- Таймаут на файловые операции (5s per directory)
- Нет кэширования для сетевых томов (данные слишком volatile)

---

## 12. Keyboard Shortcuts & Integrations

### 12.1. Keyboard Shortcuts

| Shortcut | Action |
|---|---|
| Cmd+R | Rescan current volume |
| Cmd+F | Focus search field |
| Cmd+Delete | Move selected to Drop Zone |
| Cmd+Shift+Delete | Move Drop Zone to Trash |
| Space | Quick Look selected file |
| Cmd+I | Get Info (file details panel) |
| Cmd+[ / Cmd+] | Navigate back / forward |
| Cmd+Up | Go to parent directory |
| Enter | Drill-down into selected |
| Cmd+Shift+G | Go to folder (path input) |
| Cmd+1 | Sunburst view |
| Cmd+2 | Treemap view |
| Cmd+T | New tab |
| Cmd+W | Close tab |

### 12.2. Context Menu

Right-click на файл/директорию:
- Reveal in Finder
- Open in Terminal
- Copy Path
- Copy Name
- Get Info
- Move to Drop Zone
- --- (separator)
- Delete Immediately (Cmd+Delete, с подтверждением)

### 12.3. Integrations

- **Reveal in Finder:** `NSWorkspace.shared.activateFileViewerSelecting([url])`
- **Open Terminal:** AppleScript → Terminal.app `cd <path>`
- **Copy Path:** `NSPasteboard.general`
- **Finder Toolbar:** нет (требует Finder extension, слишком сложно для v1)
- **Services menu:** "Scan with Spacie" для выбранных папок

---

## 13. Permissions & Graceful Degradation

### 13.1. Permission Flow

```
App Launch
    │
    ├── Check FDA status (TCC)
    │   ├── Granted → Full scan
    │   └── Not Granted
    │       ├── Direct version → Show FDA prompt + deep link
    │       └── MAS version → Scan with user-selected scope
    │
    ├── Scan begins
    │   ├── EACCES on directory
    │   │   └── Mark as "Restricted" (gray, lock icon)
    │   │       Show banner: "X directories restricted. Grant FDA for full scan"
    │   └── Success → continue
    │
    └── Results displayed
        └── Restricted areas shown with total "Unknown" size
```

### 13.2. FDA Deep Link

```swift
NSWorkspace.shared.open(URL(string:
    "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
)!)
```

### 13.3. MAS Sandbox Workaround

- Начальный экран: "Select folder to scan" (NSOpenPanel)
- Security-scoped bookmarks для запоминания
- Функционал ограничен выбранной папкой

---

## 14. Performance Targets

| Метрика | Цель |
|---|---|
| Scan 1M files (SSD) | < 10 сек |
| Scan 5M files (SSD) | < 60 сек |
| RAM at 5M files | < 500 MB |
| UI frame rate during scan | 60 fps |
| Visualization render | < 16ms per frame |
| App launch to interactive | < 1 сек |
| Cached rescan (no changes) | < 2 сек |
| Incremental rescan (FSEvents) | < 5 сек |

### 14.1. Оптимизации

- **Scanner:** POSIX fts (без Foundation overhead), прямые syscalls
- **Tree:** Arena allocator, flat array, string interning
- **Viz:** Canvas с кэшированием Path, Metal-backed
- **UI updates:** AsyncStream + throttle (100ms batches)
- **Duplicates:** IO concurrency limited (4 parallel reads)
- **Cache:** Memory-mapped file для быстрого чтения

---

## 15. Security Considerations

### 15.1. Privilege Escalation

- Приложение НИКОГДА не запрашивает root/sudo
- Все операции через стандартные macOS API
- Удаление — только через `FileManager.trashItem(at:resultingItemURL:)`

### 15.2. Data Privacy

- Никакие данные не отправляются наружу
- Нет аналитики, телеметрии, crash reporting (open source)
- Кэш хранится локально, доступен только текущему пользователю

### 15.3. Sandbox (MAS version)

- Strict sandbox compliance
- No temporary exceptions для file system access (только user-selected)
- Нет network access (не нужен)

---

## 16. Error Handling

| Ситуация | Поведение |
|---|---|
| EACCES при сканировании | Пометить как Restricted, продолжить |
| Диск отключён во время скана | Остановить, показать ошибку, сохранить partial |
| Файл удалён до перемещения в Trash | Warning "File not found", убрать из списка |
| Нехватка памяти (500MB limit) | Прервать глубокий скан, показать partial результат |
| FSEvents overflow | Полный rescan вместо incremental |
| Corrupted cache | Удалить, полный rescan |
| Trash permission denied | Warning + "Check permissions" |

---

## 17. Testing Strategy

### 17.1. Unit Tests

| Модуль | Что тестировать |
|---|---|
| Scanner | Обход mock FS, подсчёт размеров, обработка ошибок |
| FileTree | Вставка, поиск, агрегация размеров, memory usage |
| Duplicates | Size grouping, partial hash, full hash comparison |
| Cache | Serialization/deserialization, invalidation logic |
| Blocklist | Pattern matching, SIP detection |
| Treemap Layout | Squarified algorithm correctness |
| Plugin Protocol | Registration, discovery, execution |

### 17.2. Test Infrastructure

- XCTest для unit tests
- Mock FileSystem protocol для изоляции от реального диска
- Fixtures: prepared directory trees в test resources
- CI: GitHub Actions с macOS runner

---

## 18. Open Source

### 18.1. Repository

- **GitHub:** `github.com/<username>/spacie`
- **License:** MIT
- **README:** EN (primary) + RU

### 18.2. Contributing

- `CONTRIBUTING.md` с guidelines
- Issue templates: Bug Report, Feature Request, Plugin Request
- PR template с checklist
- Code of Conduct

### 18.3. Plugin Contributions

- Отдельная папка `Plugins/Community/` для community плагинов
- PR с новым плагином = добавить Swift файл с protocol conformance
- Автоматическая регистрация через `@_exported` или manual registry

---

## 19. Milestones (All-at-once, but ordered priorities)

**P0 — Core (must ship):**
- [ ] POSIX scanner + async pipeline
- [ ] Memory-efficient file tree (arena)
- [ ] Sunburst visualization (Canvas)
- [ ] Treemap visualization (Canvas)
- [ ] Viz switching + drill-down + breadcrumb
- [ ] Drop Zone + Trash deletion
- [ ] Volume picker + multi-tab
- [ ] Large files (Top-N + threshold)
- [ ] Basic keyboard shortcuts
- [ ] EN + RU localization

**P1 — Essential features:**
- [ ] Smart categories (built-in plugins)
- [ ] Duplicate finder (progressive)
- [ ] Old files filter
- [ ] Persistent cache + FSEvents
- [ ] Graceful degradation (no FDA)
- [ ] System overview (purgeable, snapshots)
- [ ] APFS size toggle (logical/physical)
- [ ] Blocklist (SIP + user-extensible)
- [ ] Storage management recommendations
- [ ] Context menu (Reveal, Terminal, Copy Path)

**P2 — Polish:**
- [ ] Live visualization during scan
- [ ] Plugin system (Swift protocol)
- [ ] Services menu integration
- [ ] Sparkle auto-updates (Direct)
- [ ] MAS sandbox variant
- [ ] Unit tests
- [ ] Dark mode fine-tuning
- [ ] Network volume support

---

## 20. Decisions Log

| # | Вопрос | Решение | Обоснование |
|---|---|---|---|
| 1 | Дистрибуция | MAS + Direct | Максимальный охват, два targets |
| 2 | UI Framework | SwiftUI + Canvas | Современный стек, macOS 15 позволяет |
| 3 | Min macOS | 15 (Sequoia) | @Observable macro, новые API |
| 4 | Визуализация | Sunburst + Treemap | Гибкость для разных задач |
| 5 | Сканер | POSIX fts | Максимальная скорость |
| 6 | Live preview | Да | Wow-эффект, DaisyDisk-level polish |
| 7 | Удаление | Drop Zone + Trash | Безопасный двухшаговый процесс |
| 8 | Фильтры | Все (тип, дубли, старые, кэши) | Полный набор для пользователя |
| 9 | System categories | Полный разбор | Включая purgeable, APFS snapshots |
| 10 | Монетизация | Open Source (MIT) | Портфолио, коммьюнити |
| 11 | Permissions | Graceful degradation | Работает без FDA, но лучше с ним |
| 12 | Кэш | Incremental (FSEvents) | Быстрый повторный запуск |
| 13 | Smart categories | Swift plugins | Расширяемость для коммьюнити |
| 14 | Визуальный стиль | Native macOS | System colors, accent, sidebar |
| 15 | Multi-disk | Все тома | Internal, USB, Thunderbolt, NAS |
| 16 | APFS sizes | Logical default, toggle | Привычно пользователю |
| 17 | Память | < 500MB | Arena allocator, flat tree |
| 18 | i18n | EN + RU | Два языка с первого дня |
| 19 | Навигация | Drill-down + breadcrumb | Как DaisyDisk |
| 20 | Дубликаты | Progressive hash | Size → partial → full |
| 21 | Название | Spacie | — |
| 22 | Accessibility | Позже | v2+ |
| 23 | FS watch | Snapshot + hint | FSEvents детектирует, banner предлагает |
| 24 | Интеграции | Расширенные | Reveal, Terminal, Copy Path, Services |
| 25 | MVP | Всё сразу | Полный скоуп |
| 26 | Build | Xcode project | Два targets (MAS + Direct) |
| 27 | Окна | Single + tabs | Native NSWindow tabs |
| 28 | Большие файлы | Top-N + threshold | Оба режима |
| 29 | Тесты | Unit only | XCTest для критичной логики |
| 30 | Защита файлов | SIP + blocklist | Расширяемый пользователем |
| 31 | Storage mgmt | Показывать рекомендации | + ссылка на System Settings |
| 32 | Плагины | Swift protocol | Мощно для сложной логики |
| 33 | Архитектура | MVVM + @Observable | Стандарт SwiftUI |
| 34 | Цвета | По типу файлов | Информативно |
| 35 | Опыт | Experienced | Высокоуровневая спека |
