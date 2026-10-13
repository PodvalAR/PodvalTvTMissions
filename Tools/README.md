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

### Поиск новых префабов в старых миссиях

`remap_table.json` — единственный источник правды о заменах. Он пополняется явным сканированием дерева старых миссий: каждая найденная битая ссылка объявляется заглушкой в группе `_Unresolved_Pending`, а отчёт о применении (`legacy_refs_report.json`) показывает, сколько раз и в каких миссиях она встречается.

```powershell
cd .\Tools
.\Scan-Legacy.ps1                                    # сухой прогон: ничего не пишет
.\Scan-Legacy.ps1 -SourceRoot "D:\PodvalCommunityEvent\Worlds" -Write
```

Сканирование требует `DefaultSourceRoot` и `PrefabsModRoot`. Если корень не задан, сканер **падает с ошибкой**, а не возвращает пустой результат: молчаливый «пустой» отчёт читался бы как «в старых миссиях всё чисто».

То же самое делает кнопка **«⌕ Просканировать старые миссии»** в редакторе базы замен; вкладка **«Использование»** показывает собранный отчёт. Существующие назначения при сканировании не меняются, поэтому повторный запуск безопасен.

`generate_remap_table.py` — одноразовый bootstrap: он подбирает замену по совпадению роли/фракции/имени и предлагает её. По умолчанию тоже ничего не пишет; с `--write` объявляет предложения заглушками, которые затем назначаются в редакторе. Ручные исключения вынесены в `curated_overrides.json`.

## ИИ-подсказки (необязательно)

ИИ отключён, пока не задана переменная окружения с ключом:

```powershell
setx JUSTWOKER_API_KEY "<ключ>"
```

Ключ читается только из переменной окружения и **никогда** не записывается в файл настроек. Адрес сервиса и модель меняются в настройках (`AiBaseUrl`, `AiModel`).

## Валидация миссий на соответствие стандарту (Mission Validation)

Скрипт `Test-MissionStandard.ps1` выполняет комплексную статическую проверку TvT-миссии на соответствие спецификации [`MISSION_MIGRATION_GUIDE.md`](MISSION_MIGRATION_GUIDE.md):

- **Структура и именование:** канонический формат `TvT_<Название>_<Карта>`, синхронизация трёх звеньев (папка, `<Миссия>.ent`, `<Миссия>.ent.meta`, каталог `<Миссия>_Layers`).
- **Изоляция ролей:** чистота слоёв (в `UNITS.layer` строго пехота `SCR_AIGroup`, в `VEHICLES.layer` строго техника `Vehicle`, отсутствие стационарных орудий в пехотных слоях).
- **Сквозная привязка техники:** проверка параметра `m_sAttachmentGroupName` техники к реальным пехотным отделениям в `UNITS.layer`.
- **Позывные отделений:** формат `<Faction>_<Callsign>` (например, `USAF_101`, `RU_010`, `CDF_201`).
- **Маркеры:** запрет значений `m_sQuadName "undefined"`, обязательный контур `m_sImageSetGlow` для флагов отделений, скрытие меток техники в игре (`m_aHideOnGameModeStates { GAME }`), запрет устаревших тегов `#DRG-Sq-`.
- **Мультиплеер:** наличие `PS_GameModeCoop`, `PerceptionManager`, `SCR_AIWorld`, стандартный фризтайм (`m_iFreezeTime 300000` = 5 мин) и разметка описания `DescriptionEditableScrollable.layout`.

### Запуск валидатора

```powershell
cd .\Tools
# Обычный запуск (Warnings информативны, exit code 1 только при критических Errors)
.\Test-MissionStandard.ps1 -MissionPath "..\Worlds\Banan\Everon\TvT_LigthHouse_Everon"

# Строгий режим (любые Warnings приводят к exit code 1) с выгрузкой JSON-отчёта
.\Test-MissionStandard.ps1 `
    -MissionPath "..\Worlds\Banan\Everon\TvT_LigthHouse_Everon" `
    -Strict `
    -ReportJson "validation-report.json"
```

## Автоматическая нормализация слоёв миссий (Mission Normalization)

Скрипт `Normalize-MissionLayers.ps1` автоматизирует шаги 1–8 спецификации [`MISSION_MIGRATION_GUIDE.md`](MISSION_MIGRATION_GUIDE.md):

- **Каноническое именование:** авто-определение карты и переименование миссии в `TvT_<ИмяМиссии>_<Карта>`, синхронизация файлов `.ent`, `.ent.meta`, ResourcePath и папки `<Миссия>_Layers`.
- **Сегрегация сущностей:** автоматическое извлечение техники в `VEHICLES.layer`, пехоты в `UNITS.layer`, стационарных орудий (Корд, АГС, СПГ, турели) в `_2_PROPS.layer`.
- **Расчёт позывных:** чтение `PS_GroupCallsignAssigner`, расчет по формуле $(C \times 100) + (P \times 10) + S$ и автоматическое переименование отделений в `<Faction>_<Callsign>` (например, `RU_210`, `USAF_010`, `CDF_201`).
- **Сквозная привязка техники:** привязка `m_sAttachmentGroupName` техники к отделениям по существующим ссылкам или ближайшим координатам спавна, переименование машин в `<Group>_V`.
- **Маркеры:** авто-добавление контуров флага `m_sImageSetGlow`, исправление значений `m_sQuadName "undefined"` на `"commander"` / `"infantry"`, скрытие меток техники в игре (`m_aHideOnGameModeStates { GAME }`), ремаппинг устаревших тегов `#DRG-Sq-` на `#PDVL_Squad_`.
- **Фризтайм:** пространственное распределение зон фризтайма (`SCR_EditorRestrictionZoneEntity`) по координатам спавна сторон в `<Faction>/FREEZ.layer`.
- **Очистка старых слоёв:** безопасное удаление устаревших разрозненных файлов (`rus.layer`, `us.layer`, `log.layer`, `desc.layer`, `domiki.layer`, `friz.layer`, `default.layer`) после переноса данных.
- **Встроенная валидация:** автоматический прогон `Test-MissionStandard.ps1` по завершении для подтверждения чистоты результата.

### Запуск нормализатора

```powershell
cd .\Tools
# Полная нормализация с переименованием и автоматической валидацией
.\Normalize-MissionLayers.ps1 -MissionPath "..\Worlds\Banan\ChernarusMinus\TVT_Zavod_Chernorus_Minus"

# Сухой прогон (просмотр действий без изменения файлов)
.\Normalize-MissionLayers.ps1 -MissionPath "..\Worlds\Banan\ChernarusMinus\TVT_Zavod_Chernorus_Minus" -DryRun

# Нормализация только внутренних слоёв без переименования папки мира
.\Normalize-MissionLayers.ps1 -MissionPath "..\Worlds\Author\TvT_MyMission_Everon" -SkipRename
```

## Тесты

```powershell
cd .\Tools
powershell -NoProfile -ExecutionPolicy Bypass -File .\Tests\Run-Regression.ps1
```

Тесты используют временные синтетические данные: рабочие `catalog_new_prefabs.json`, `legacy_refs_report.json` и `remap_table.json` не читаются и не изменяются. Тесты на Node.js пропускаются с предупреждением, если `node` не найден в `PATH`.

### Ручная проверка первого запуска

Отдельный скрипт проверяет то, что автотесты не покрывают: инструмент на машине без настроек. Он копирует `Tools` во временный каталог, запускает сервер и прогоняет HTTP-сценарии — от первого запуска без конфига до подбора свободного порта.

```powershell
cd .\Tools
powershell -NoProfile -ExecutionPolicy Bypass -File .\Tests\firstrun-verification.ps1
```

Корень мода префабов ищется рядом (`PodvalTvTPrefabs\PodvalTvTPrefabs`), аддон — по файлу `.gproj`; при неудаче укажите `-PrefabsModRoot` и `-AddonRoot`. Скрипту нужен свободный диапазон портов и около минуты времени, в `Run-Regression.ps1` он **не** входит.

Запускайте его вручную, прежде чем отдать инструмент другому оператору.

## Состав

| Файл | Назначение |
|---|---|
| `Test-MissionStandard.ps1` | Валидатор соответствия миссии каноническому стандарту PodvalTvT |
| `Normalize-MissionLayers.ps1` | Авто-нормализатор структуры слоёв, позывных, техники и маркеров (шаги 1–8) |
| `Restore-Core.ps1` | Вся логика: разбор ссылок, ремаппинг, конфигурация |
| `Restore-Mission.ps1` | CLI-обёртка над ядром: восстановление одной миссии |
| `Scan-Legacy.ps1` | CLI-обёртка над ядром: скан старых миссий и объявление заглушек |
| `generate_remap_table.py` | Bootstrap: подбор замен по совпадению роли/фракции (сухой прогон по умолчанию) |
| `curated_overrides.json` | Ручные исключения для bootstrap (старый ref → новый ref) |
| `UI\Serve-RestoreUI.ps1` | Локальный веб-сервер (только loopback) |
| `UI\index.html`, `UI\editor.html` | Интерфейс и редактор таблицы замен |
| `remap_table.json` | Таблица замен префабов — источник правды |
| `catalog_new_prefabs.json` | Снимок каталога префабов мода (отслеживается в git) |
| `legacy_refs_report.json` | Отчёт о применении префабов в старых миссиях (локальный, в `.gitignore`) |
| `Tests\` | Регрессионные проверки (включая `mission-validation-regression.ps1` и `mission-normalization-regression.ps1`) |