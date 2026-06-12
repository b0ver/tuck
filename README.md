# Tuck

**One icon to tuck them all.** Tuck collapses your cluttered macOS menu bar icons into a single chevron and reveals them on demand — either right in the menu bar or in a beautiful Apple-style drop-down panel.

[Русская версия ниже ↓](#tuck-по-русски)

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue) ![Swift](https://img.shields.io/badge/Swift-5.9-orange) ![License](https://img.shields.io/badge/license-MIT-green)

## Features

- **Collapse menu bar icons** into a single Tuck icon that sits to the right of all your visible icons, next to the system area.
- **Keep favorites visible** — anything you drag to the right of the Tuck divider never gets hidden.
- **Two reveal styles**, switchable in Settings (⌥-click uses the alternate one):
  - **Drop-down panel** — hidden icons appear in a blurred, rounded, Control-Center-style panel below the Tuck icon, with live previews. Click a preview to activate the real icon.
  - **Inline** — classic expand/collapse in the menu bar itself.
- **Auto-hide** — icons tuck themselves away again after a configurable delay.
- **Launch at login** via the native `SMAppService` API.
- **Localized** in English and Russian.

## Install

1. Download `Tuck-x.y.z.dmg` from [Releases](https://github.com/b0ver/tuck/releases).
2. Open it and drag **Tuck** into **Applications**.
3. First launch: the app is ad-hoc signed, so right-click → **Open** → **Open** (one time only).

## Usage

- Hold **⌘** and **drag** menu bar icons to the **left** of the Tuck divider `|` to hide them.
- Icons to the **right** of the divider always stay visible.
- **Click** the Tuck chevron to reveal hidden icons (panel or inline — your choice in Settings).
- **Right-click** the chevron for the menu: Settings, Launch at Login, Quit.

### Permissions (optional but recommended)

| Permission | What it unlocks |
|---|---|
| Screen Recording | Live previews of hidden icons in the panel |
| Accessibility | Clicking hidden icons directly from the panel |

Without them Tuck still works: the panel shows app icons instead of live previews, and clicks expand the menu bar.

## Build from source

```bash
git clone https://github.com/b0ver/tuck.git && cd tuck
./Scripts/build-app.sh   # → dist/Tuck.app
./Scripts/make-dmg.sh    # → dist/Tuck-<version>.dmg
```

Requires macOS 14+ and Xcode Command Line Tools (Swift 5.9+). No Xcode project needed — plain SwiftPM.

## How it works

Tuck places two status items in the menu bar: a chevron and a divider. When collapsing, the divider's length is expanded to push everything left of it off-screen — the same battle-tested trick used by Hidden Bar and Ice. The drop-down panel briefly expands the bar, snapshots each hidden item's window via ScreenCaptureKit, collapses back, and forwards your clicks with synthesized mouse events.

## Roadmap

- [ ] Universal binary (arm64 + x86_64) release builds
- [ ] "Always hidden" section (second divider)
- [ ] Reveal on hover / scroll
- [ ] Per-screen support for multi-display setups
- [ ] Sparkle auto-updates, notarized builds

---

# Tuck (по-русски)

**Одна иконка, чтобы спрятать все.** Tuck сворачивает иконки приложений в строке меню macOS (верхняя панель, справа у часов) в один значок-шеврон и показывает их по запросу — прямо в строке меню или в красивой выпадающей панели в стиле Apple.

## Возможности

- **Сворачивание иконок** строки меню в один значок Tuck, который располагается правее всех видимых иконок, рядом с системной областью.
- **Избранные иконки остаются на виду** — всё, что вы перетащите правее разделителя Tuck, никогда не скрывается.
- **Два способа раскрытия** (переключаются в настройках, ⌥-клик — альтернативный):
  - **Выпадающая панель** — скрытые иконки показываются в полупрозрачной скруглённой панели под значком Tuck (как модуль Пункта управления) с живыми миниатюрами. Клик по миниатюре активирует настоящую иконку.
  - **В строке меню** — классическое разворачивание на месте.
- **Автосворачивание** через настраиваемый интервал.
- **Запуск при входе в систему** (нативный `SMAppService`).
- **Локализация**: русский и английский.

## Установка

1. Скачайте `Tuck-x.y.z.dmg` из [Releases](https://github.com/b0ver/tuck/releases).
2. Откройте DMG и перетащите **Tuck** в **Программы** (Applications).
3. Первый запуск: приложение подписано ad-hoc, поэтому один раз откройте через правый клик → **Открыть** → **Открыть**.

## Использование

- Удерживая **⌘**, **перетащите** иконки строки меню **левее** разделителя Tuck `|` — они будут скрываться.
- Иконки **правее** разделителя всегда остаются видимыми.
- **Клик** по шеврону Tuck показывает скрытые иконки (панель или разворачивание — на ваш выбор).
- **Правый клик** — меню: Настройки, Запуск при входе, Выход.

### Разрешения (необязательно, но рекомендуется)

| Разрешение | Что даёт |
|---|---|
| Запись экрана | Живые миниатюры скрытых иконок в панели |
| Универсальный доступ | Клик по скрытым иконкам прямо из панели |

Без них Tuck тоже работает: панель покажет значки приложений вместо миниатюр, а клик развернёт строку меню.

## Лицензия

MIT © 2026 Evgeny Popov ([b0ver](https://github.com/b0ver))
