# Текущее состояние проверки Notebook

Срез: **5 октября 2026**. Каждый результат относится к своим исходникам и scope.
Функциональная проверка, установка и полная приёмка учитываются отдельно.

## Архитектурная переработка — 241

Чтение, запросы страниц и публикация сцены получили отдельных владельцев.
Состояние каждого программного runtime собрано в одной записи; позднее завершение
прежнего источника не меняет его замену. Immutable layout владеет индексом размеров
программ. Заменённые поля, partial-layout/isComplete, массовый loadAvailableDocuments
и неиспользуемая диагностика reservations удалены. Исправлена потеря interaction
failure после независимой подготовки native PDF; повтор сохраняет видимую бумагу.

**73 уникальные native проверки физического iPad + 24 Mac PASS** в отдельных
адресных прогонах; runtime warnings 0. Код продукта неизменен после run-2;
позднейшие исправления затрагивают setup тестов. На iPad прошли запуск программ
на доске и в документе, фон/холодное открытие, pinch-close/double-tap-open,
ссылки/возврат, LaTeX и перелистывание. Composition journey с перемещением,
удалением, undo/redo и cold reopen прошёл отдельным неизменённым повтором;
причина signal kill в первом UI-прогоне не установлена.
Board24 прошёл обе реальные фазы масштаба и первые нажатия всех 24 программ.
Траектория теста исправлена по физической записи; product input routing сохранён.
Итого 7 UI сценариев PASS. Подписанная пара 241 собрана и установлена.
[Результаты и исходные неудачные попытки](audit-evidence/2026-10-05/architecture-documents/results.json).

В нагрузке из 100 000 fragments / 1000 программ / 1024 тёплых запросов размеры
находятся за **0,046 мс вместо 3951 мс** (медиана трёх пакетов).
Это lookup в layout, без стоимости первого построения индекса и показа UI.
В изолированном native IPC на доске из 16 текстовых тел правка одного тела
передаёт **1 PNG вместо 16**, base64 **11 616 вместо 122 224 байт (−90,5%)**;
перемещение использует прежние материалы без новых PNG. Одиночные IPC timings
не устанавливают общий прирост FPS/отклика.
[Сравнение материалов](audit-evidence/2026-10-05/architecture-materials/comparison.json).

## Установленная пара и история

Текущая установленная пара: **0.3.171 (241)** от 5 октября, 12:45 МСК.
Исходники `87f43a9b…` совпали с проверенным snapshot. Оба IPC endpoint
обслуживает один процесс Mac, чья динамическая подпись совпала с verified build.
Сразу после обновления header и presence сохранились; пустой выбор сохранил
смысл, а временные session/nonce обновились при запуске процесса.
После подключения iPad observed context представляет его текущую работу;
локальная страница Mac осталась 23/24, масштаб 61%, состояние программы сохранено.
iPad показывает рабочую рукописную страницу; данные и pairing не сбрасывались.
ОС переместила data container при обновлении, поэтому равенство его пути не заявляется.
[Доставка и точный scope](audit-evidence/2026-10-05/architecture-documents/delivery.json).

На установленном owner повторная проекция доски сохранила восемь asset ID
и передала 0 новых PNG вместо 8. Оба чтения оставили header/presence/selection
неизменными. В этой проекции нет отдельных element layers; их инвалидизация
проверена адресными Mac-тестами и сравнением выше.
[Installed IPC smoke](audit-evidence/2026-10-05/architecture-materials/installed.json).

История срезов 215–240, их исходные FAIL, scope и доставка сохранены
[в предыдущей ревизии](https://github.com/AmirTlinov/Notebook/blob/1ee54dc9e4444fee3aa9fec4a4a435636d11aa03/docs/verification.md).
Текущие задачи и зависимости — Linear, GUI-306; контракт ввода —
[interaction ownership](interaction-ownership.md).

## Открытые измерения

- **GUI-388:** на 240 / SDK frontend 0.1.6 чёткий материал после 50→95%
  появился за 228 мс (239: 374 мс); резкий 100→350% — за 1672 мс.
  Эти DOM/rAF и native manifest clocks не измеряют OS display time.
  Native crash при нулевой ширине региона исправлен в 240.
  Активная панель Codex тогда загружала старый frontend 0.1.5; принятие 0.1.6,
  перенос между экранами/DPR и лишние idle manifests остаются открытыми.
  [Замеры и active consumer](audit-evidence/2026-10-01/codex-zoom-latency/results.json).
- **Cold document/SVG/programs, Native24, first curl:** строгие бюджеты,
  причина первого cold discard и ready-time WebKit IPC не приняты.
  В 240 accepted→preparation cold1/cold24 — 0,305/0,283 мс;
  первый native installation — 330,515/436,173 мс, все 24 — 1057,570 мс.
  Порядок холодных сцен и instrumentation влияют на сравнимость.
  [Source clocks](audit-evidence/2026-10-01/cold-owner-240/cold-metrics.json).
- **Pencil/eraser:** каждый sample ≤20 мс и аппаратный contact-to-display
  требуют цепочки contact revision → callback → submission/GPU → presentedTime.
  Подача через native recognizer и CADisplayLink не измеряют аппаратный отклик/FPS.
- **Промежуточный mixed cut:** итоговый снимок не доказывает все OS-кадры.
  В inverse-journey2009 GPU cut содержал штрих и OS receipt 23,023 мс,
  но drawHierarchy(false) его не показал. Independent display oracle открыт.
- **Системные frame/CPU/GPU/memory:** текущая пара ещё не принята;
  прежние Time Profiler2042 и logging-only60s не дали пригодных измерений.

## Доставка и полная приёмка

Обновление на месте сохраняет контейнеры, контент, идентичности и ключи.
Schema27 требует согласованной пары; helper schema26 не запускается против
обновлённого workspace. saved, receivedByIPad и shownOnIPad проверяются отдельно.

**GUI-190, full acceptance — не выполнена.** Нужны десять повторений сценариев,
30 минут совместной работы и системные frame/CPU/GPU/memory измерения одной пары.
Этот срез не закрывает GUI-196 (erased-material), GUI-197 (causal continuation),
GUI-183 (WAN/multidevice) и длительную GUI-250. GUI-240 закрыта решением Амира.
