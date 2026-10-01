# Текущее состояние проверки Notebook

Срез: **2 октября 2026**. Результат относится к исходникам своего receipt.
Функциональная проверка, установка и полная приёмка учитываются отдельно.

## Общая версия 240 — установлена

Source `bbcbe80500ee6ad9ecfbeb48e7a1f771d27c9aef395b285f07d86bf4bd7089b0`:
**8 physical-iPad + 2 Mac + 175 MCP PASS**, failure/skip/runtime warnings 0.
**0.3.170 (240)** установлена поверх 239 на Mac и физическом iPad
**2 октября в 00:06 МСК**; 7 installation continuity checks PASS. Пространство,
доверенное устройство, страница, камера и выбор сохранены; оба IPC endpoint
обслуживает один подписанный owner 240. [Доставка](audit-evidence/2026-10-01/cold-owner-240/delivery.json).

Mac проверяет открытие первой страницы, независимость native presence,
плотность бумаги и рукописи, точную проекцию прежнего падения на 350%,
порядок чернил/ластика/baseline и освобождение региональных ресурсов.
На iPad проверены совместные owners подготовки программ, scene index,
перелистывания и ordered export. [Scope и итоговый receipt](audit-evidence/2026-10-01/cold-owner-240/results.json).

Первичный Mac-прогон дал два FAIL в новых тестовых ожиданиях: фиксированный
квадрат 1024×1024 и неизменный объём геометрии между регионами. Исправлены
только тесты: эталон использует фактическую сетку пикселей; временные растры
освобождаются после каждого региона, повтор региона не увеличивает память,
завершённый cut освобождает всё. Порог сравнения пикселей сохранён.
Код продукта между первым и финальным прогонами одинаковый.

### Чёткость зума Codex — GUI-388

Пользователь уточнил: изображение становится чётким через 2–3 секунды после
остановки зума. На установленной 239 / plugin 0.1.5 жесты 100→191% и 50→95%
воспроизвели растяжение прежних пикселей. Материал достаточной плотности
рукописи появился через **606/374 мс**, финальная проекция — через
2077/1200 мс. Это DOM/rAF и плотность native manifest, не OS display timestamp.
Финальный MCP запрос занимал 1258/690 мс, HTTP добавлял около 8 мс.
Бумага имела меньшую плотность и была исключена из проверки качества покрытия.
[Baseline](audit-evidence/2026-10-01/codex-zoom-latency/baseline.json).

Быстрый зум 100→350% за 182 мс завершил 239 с SIGTRAP. Точный readonly запрос
под LLDB показал нулевую ширину лишнего региона из-за округления
`ceil(width / side)`, затем precondition в `PageRect`. Оба системных
crash-report workers истекли по watchdog; сохранён стек LLDB. Owner 239
восстановлен, пространство и доверенный iPad сохранены.
[Сбой и запрос](audit-evidence/2026-10-01/codex-zoom-latency/large-zoom-failure.json).

240 пропускает неположительные регионы, готовит source/mesh/ordered clips
однократно при первом cache miss принятой области и использует одинаковую
плотность бумаги и рукописи. Очередь камеры запрашивает повтор только при
недостаточной плотности или покрытии; полезный промежуточный материал,
принудительное обновление, fit и контекст сохраняются.
Установленная 240 / plugin 0.1.6 проверена через SDK с точным HTML на настоящих
«заметках»: 50→95% — бумага и рукопись достаточной плотности через **228 мс**
после остановки (239: 374 мс), финальный camera-cut уже не нужен. При 100→190%
прежний материал заранее имел достаточную плотность; сравнение задержки здесь
неприменимо. Быстрый 100→350% больше не завершает helper, но чёткий материал
появился только через **1672 мс**. DOM/rAF не измеряет OS display time.

В Codex на native 240 прошли открытие, Next/Previous и три zoom-button clicks
110→190%; итоговая рукопись и бумага визуально чёткие. Однако даже после
`codex plugin add notebook@notebook-local` новая панель загрузила старый
script 0.1.5 (`96322386…`) вместо 0.1.6 (`e2099d8b…`). Штатный app-server proxy
не ответил на initialize за 10 с; reload не отправлялся. Для приёмки нового
frontend в Codex требуется новое подключение. После обоих сценариев **6 native
continuity checks PASS**, owner 240 тот же. GUI-388 остаётся In Progress.
[Сравнение, active consumer и continuity](audit-evidence/2026-10-01/codex-zoom-latency/results.json).

### Начальная подготовка и перелистывание

Принятая подготовка разрешает свежий scene index в своём native callback.
До первой навигации программа получает последний принятый initial state.
Операция перелистывания сохраняет уже принятую половину пары при повторном
запросе второй; готовность замороженного cut отделена от показа живого листа.
[Причины и владельцы](cold-first-publication-2026-10-01.md).

Fresh-host cold1/cold24 на том же source: accepted→page preparation
**0,305/0,283 мс** в том же UI-проходе вместо 37,056/24,464 мс в 239.
Первый native installation: cold1 330,515 мс (было 335,360), cold24 436,173 мс
(было 368,622); все 24 — 1057,570 мс (было 1077,271). WebKit request→policy
126,369/177,730 мс. Лишний внутренний этап устранён; широкое ускорение
и момент фактического показа этим замером не установлены.
[Source clocks](audit-evidence/2026-10-01/cold-owner-240/cold-metrics.json).

## Проверенные предшествующие срезы

Каждая строка относится к собственному source и scope. Они не складываются
в текущий full PASS. Подробные исходники, отрицательные результаты и доставка
сохранены в [неизменной ревизии 07a8ce61](https://github.com/AmirTlinov/Notebook/blob/07a8ce6110b46465dca4a9c1cb21949bc5b84855/docs/verification.md)
и адресных receipts.

| Срез | Область и результат | Свидетельство |
|---|---|---|
| 239 | Initial state до future commit credit; ранний scene index. 5 iPad + 2 Mac PASS, signed pair установлен с 7 continuity PASS. Codex 0.1.5: настоящие заметки, Next/Previous и zoom buttons проверены; задержка чёткости тогда не измерялась. | [Results](audit-evidence/2026-10-01/web-startup-239/results.json), [delivery](audit-evidence/2026-10-01/web-startup-239/delivery.json) |
| 238 / plugin 0.1.5 | Card hit target после pointer capture, экранная плотность, native ink geometry. 5 Mac + 2 iPad + MCP 170 PASS; Core отдельно 1 определение / 2 случая. SDK: double-click в Hand, страницы, Back/Enter, чёткая рукопись 184%/DPR1 и 220%/DPR2. Установлена с 7 continuity PASS. | [Results](audit-evidence/2026-10-01/codex-sharpness/results.json) |
| 237 / plugin 0.1.4 | Отдельные тела карточек, camera/Back/fit, tile reuse. 3 Mac + 2 iPad + MCP 168 PASS; Core 9 определений / 12 случаев. Последующие пользовательские дефекты открытия и чёткости сохранены в GUI-388. | [Results](audit-evidence/2026-10-01/codex-board/results.json) |
| 236 / plugin 0.1.3 | Устранены конечный фон и возврат камеры при смене raster origin. 2 Mac + 1 iPad + MCP 168 PASS; SDK real-board camera, 7 continuity PASS. | [Results](audit-evidence/2026-10-01/codex-camera/results.json) |
| 235 | Владение readiness/cancellation, source replacement и release ресурсов. Первично 13 iPad PASS / 2 fixture FAIL; после исправления ожиданий 2 iPad + 3 Mac PASS при неизменном product source, MCP 168 PASS. Установлена с 7 continuity PASS. | [Results](audit-evidence/2026-10-01/cold-owner-235/results.json), [delivery](audit-evidence/2026-10-01/cold-owner-235/delivery.json) |
| 234 / plugin 0.1.2 | Native compositor вместо generic SVG. MCP 168 + 2 Mac + 1 iPad PASS; Core 5 функций / 8 случаев. Первая live-проверка выявила старый in-memory owner 233 после обмена приложения; static/fixture PASS не доказывал новую установленную панель. | [Results](audit-evidence/2026-10-01/codex-plugin/results.json) |
| 233 | Адресная публикация source/retirement и возрастающий sequence при одном OS timestamp. 15 iPad + 2 Mac PASS, Core 2 PASS в своих scopes; final Mac 2 PASS после frontend delta. Панель 0.1.1 отклонена пользователем за generic cards, missing ink и auto-fit. | [Checks](audit-evidence/2026-10-01/cold-install-233/checks.json), [delivery](audit-evidence/2026-10-01/cold-install-233/delivery.json) |
| 230 | Локальные reads/input, повторное использование host, installed output и UI24. 24 iPad + 2 Mac PASS. Пять обычных curl observations: 20,414–23,656 мс / 0 discard; первый cold output оставался 27,883 мс / 3 discard. | [Results](audit-evidence/2026-10-01/remaining-latency-230/final-results.json), [delivery](audit-evidence/2026-10-01/remaining-latency-230/delivery.json) |
| 229 | Native paper до WebKit, один source producer, regrab/cancel/landing и UI24. 16 iPad + 2 Mac PASS. Первые OS budgets оставались открытыми. | [Results](audit-evidence/2026-09-30/presentation-229/results.json), [delivery](audit-evidence/2026-09-30/presentation-229/delivery.json) |
| 228 | Владение физическим запросом snapshot, отмена reader, backlog ≤4. Первично 14 iPad PASS / 3 FAIL; адресный повтор 3 PASS, Mac 2 PASS в своих scopes. Единичный terminal timeout не повторился, его причина не установлена. | [Results](audit-evidence/2026-09-30/owned-demand-228/results.json), [delivery](audit-evidence/2026-09-30/owned-demand-228/delivery.json) |
| 224–227 | Source/scene admission, локальные owners, constructor budget и lifetime. | [Неизменный отчёт](https://github.com/AmirTlinov/Notebook/blob/c5d4c664597a8e7efd65f4f06f6bcb3e5da4cc3e/docs/verification.md) |
| 215–222 | Interaction ownership, page-turn lifetime, UI24, mixed cut и native cancellation. | [Неизменный отчёт](https://github.com/AmirTlinov/Notebook/blob/62599fc3e9f224fa7dac1961327d5b415a1db4e4/docs/verification.md) |

Причинное ревью и ремонт: [30 сентября](performance-review-2026-09-30.md),
[владельцы после ремонта](performance-repair-2026-09-30.md),
[1 октября](performance-repair-2026-10-01.md). Текущие задачи и зависимости —
в Linear, GUI-306; контракты — в [interaction ownership](interaction-ownership.md).

## Что остаётся открытым

- GUI-388: актуальный frontend 0.1.6 в активном Codex и задержка 1672 мс при
  резком 100→350%. SDK также наблюдал полные idle manifests без новых PNG;
  причина этого отдельного обновления не установлена. Перенос панели между
  экранами с изменением DPR ещё не принят; предыдущая смена DPR через CDP
  без жеста не запросила новую плотность.
- Строгие cold document/SVG/programs, Native24 и first-curl бюджеты; причина
  первого cold discard и ready-time WebKit IPC. Отрицательные физические
  controls и исходные FAIL сохранены в receipts. Прогоны с разным порядком
  холодных сцен и profiler instrumentation не дают сравнимую обычную задержку.
- Каждый Pencil/eraser sample ≤20 мс и аппаратный contact-to-display не приняты.
  Нужна цепочка contact revision → callback/target → submission/GPU → actual
  presentedTime. Подача через native recognizer не измеряет аппаратный Pencil;
  CADisplayLink не измеряет FPS.
- Системный итоговый снимок mixed cut не доказывает промежуточные OS-кадры.
  В inverse-journey2009 accepted GPU cut содержал штрих и OS receipt 23,023 мс,
  но drawHierarchy(false) его не показал. Independent display oracle открыт.
- App-only Time Profiler2042 не нашёл тестовый PID. Logging-only60s в 235
  не завершил usable OS export. Системные frame/CPU/GPU/memory характеристики
  текущей пары ещё не приняты.

## Доставка и полная приёмка

Обновление на месте сохраняет контейнеры, контент, идентичности и ключи.
Schema27 требует согласованной пары; helper schema26 не запускается против
обновлённого workspace. `saved`, `receivedByIPad` и `shownOnIPad` подтверждаются
отдельно. Физическая проверка сценария относится к установленной версии.

Full acceptance, GUI-190: **не выполнена**. Нужны десять повторений сценариев,
30 минут совместной работы и системные frame/CPU/GPU/memory измерения одной пары.
Этот срез не закрывает GUI-196 (erased-material), GUI-197 (causal continuation),
GUI-183 (WAN/multidevice) и длительную GUI-250. GUI-240 закрыта решением Амира.
