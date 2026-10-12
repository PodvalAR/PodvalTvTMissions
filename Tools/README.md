# Инструмент восстановления миссий (Mission Restore)

Локальный инструмент для переноса старых (legacy DRG-era) миссий Arma Reforger в текущий аддон `PodvalTvTMissions` с автоматической заменой ссылок на удалённые префабы по таблице `remap_table.json`.

Полное описание процесса миграции — в [`MISSION_MIGRATION_GUIDE.md`](MISSION_MIGRATION_GUIDE.md).

---

## Требования

| Компонент | Версия |
|---|---|
| ОС | Windows (используется P/Invoke `kernel32.dll`) |
| PowerShell | 5.1 (встроенный в Windows) |
| Node.js | только для запуска тестов, не для работы инструмента |

Ничего устанавливать не нужно. Все зависимости — встроенные средства Windows.

## Что нужно клонировать рядом

Инструменту требуются два репозитория:

```
<папка>\
├── PodvalTvTMissions\      ← этот репозиторий (инструмент лежит в Tools\)
└── PodvalTvTPrefabs\       ← отдельный репозиторий с префабами
```

Мод префабов нужен для проверки ссылок и восстановления миссий. Без него инструмент всё равно запускается: подсказки и редактор таблицы работают по сохранённому каталогу, а проверка и восстановление — нет.

## Настройка

Пути машинозависимы, поэтому в репозитории их нет. Создайте локальный файл настроек:

```powershell
cd .\Tools
Copy-Item .\tool.config.example.json .\tool.config.json
notepad .\tool.config.json
```

`tool.config.json` находится в `.gitignore` — ваши пути остаются на вашей машине и не попадут в репозиторий.

Минимально нужно заполнить одну настройку:

| Ключ | Что это |
|---|---|
| `PrefabsModRoot` | **обязательно.** Корень аддона `PodvalTvTPrefabs`, например `D:\GitHub\PodvalTvTPrefabs\PodvalTvTPrefabs` |
| `AddonRoot` | Корень аддона с файлом `.gproj`. Обычно определяется автоматически |
| `DefaultSourceRoot` | Папка со старыми миссиями. Необязательно |
| `DefaultDestDir` | Куда сохранять восстановленные миссии. По умолчанию `<AddonRoot>\Worlds` |

Поддерживаются `%ПЕРЕМЕННЫЕ%` и `~`. Ключи, начинающиеся с `_`, считаются комментариями.

Проще всего заполнить настройки прямо в интерфейсе: кнопка **«Настройки»** в шапке или баннер первого запуска.

> Если рядом уже есть старый файл `Tools\UI\ui.config.json`, он используется как запасной вариант.

## Запуск

```powershell
Tools\UI\Start-RestoreUI.bat
```

Откроется браузер на `http://localhost:8787/`. Порт занят — инструмент сам подберёт свободный (сообщит в окне). Чтобы задать порт, укажите `Port` в настройках или запустите `Serve-RestoreUI.ps1 -Port 9000`.

Редактор базы замен — `http://localhost:8787/editor`.

Остановить сервер — кнопка в интерфейсе или `Ctrl+C` в окне консоли.

### Из командной строки

```powershell
cd .\Tools
.\Restore-Mission.ps1 `
    -SourceMission "D:\PodvalCommunityEvent\Worlds\Peroi\Arland\Bastovich_Arland" `
    -DestDir "D:\GitHub\PodvalTvTMissions\PodvalTvTMissions\Worlds\RamboKZ\Peroi" `
    -Force
```

Параметры командной строки (`-AddonRoot`, `-PrefabsModRoot`, `-RemapTable`, `-ConfigPath`) перекрывают значения из файла настроек.

## ИИ-подсказки (необязательно)

ИИ отключён, пока не задана переменная окружения с ключом:

```powershell
setx JUSTWOKER_API_KEY "<ключ>"
```

Ключ читается только из переменной окружения и **никогда** не записывается в файл настроек. Адрес сервиса и модель меняются в настройках (`AiBaseUrl`, `AiModel`).

## Тесты

```powershell
cd .\Tools
powershell -NoProfile -ExecutionPolicy Bypass -File .\Tests\Run-Regression.ps1
```

Тесты используют временные синтетические данные: рабочие `catalog_new_prefabs.json`, `catalog_old_prefabs.json` и `remap_table.json` не читаются и не изменяются. Тесты на Node.js пропускаются с предупреждением, если `node` не найден в `PATH`.

## Состав

| Файл | Назначение |
|---|---|
| `Restore-Core.ps1` | Вся логика: разбор ссылок, ремаппинг, конфигурация |
| `Restore-Mission.ps1` | CLI-обёртка над ядром |
| `UI\Serve-RestoreUI.ps1` | Локальный веб-сервер (только loopback) |
| `UI\index.html`, `UI\editor.html` | Интерфейс и редактор таблицы замен |
| `remap_table.json` | Таблица замен префабов |
| `catalog_*_prefabs.json` | Снимки каталогов префабов |
| `Tests\` | Регрессионные проверки |