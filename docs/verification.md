# Текущее состояние проверки Notebook

Срез: **26 сентября 2026**. Это сводка состояния, не журнал запусков.
Последующие изменения нельзя считать проверенными только потому, что ранее прошёл
тест с тем же названием. Точный source witness каждого результата находится в его receipt.

## Что завершено и что ещё нет

- [GUI-305](https://linear.app/main-cluster/issue/GUI-305): [аудит](audit-2026-09-25.md)
  выполнен; его 19 находок и четыре риска — исходный диагноз, не подтверждение ремонта.
- [GUI-306](https://linear.app/main-cluster/issue/GUI-306): **ремонт продолжается**.
  Причинные исправления имеют адресные Core/JS/MCP/native проверки; единой финальной
  приёмки всех A01–A19/R01–R04 и новых замечаний пользователя ещё нет.
- [GUI-295](https://linear.app/main-cluster/issue/GUI-295): **не закрыта**.
  Отдельные пути перелистывания и чернил исправлены, но raw-page Redo, полный
  смешанный выбор/перенос в финальной Release-паре и строгие физические условия ниже остаются открытыми.
- Установка private-сборок и focused PASS не означают обновление/приёмку рабочей пары.
  Текущие документы, контейнеры, идентичности и ключи сохраняются; исторические
  архивы не являются входом проверки. Совместимое чтение старых program receipts
  не добавляется по прямому решению Амира.

## Актуальные доказательства по затронутым путям

Результаты ниже относятся к **своим неизменным исходникам**, а не автоматически
ко всему нынешнему дереву. Числа отдельных запусков не складываются в новый общий PASS.

| Поведение | Последний подтверждённый объём и граница | Receipt |
|---|---|---|
| Полный текст сообщений, повтор первого запроса, observation/lifecycle | **Mac124: 32/32 PASS**; весь выбранный Sidecar suite. Один immutable transfer сохраняется при повторе той же envelope; новые запросы, peer/generation/collision/revoke проверены. | [124](audit-evidence/2026-09-25/user-ux-124.json) |
| Принятый/отменённый холодный жест страницы | **USB iPad124: 2/2 PASS**; оба направления ожидания своей готовности. Вместе с Mac124: 0 skips/warnings, source SHA `e8cfb081…`. Это не повтор всех page-motion сценариев. | [124](audit-evidence/2026-09-25/user-ux-124.json) |
| Защита действительно живых страниц при давлении памяти | Адресные physical119/120/122/123 проверки подтверждают защиту сторон Motion и освобождение спекулятивных backing/отменённого жеста. Широкие прогоны имели fixture FAIL, исправленные отдельными повторами; единого нового полного PASS не заявлено. | [118–123](audit-evidence/2026-09-25/user-ux-118-123.json) |
| Обычная навигация после повторного входа | **Simulator121: 3/3 PASS**: обратная стрелка, 20 чередующихся свайпов, следующий жест после посадки. Это проверка Simulator gesture routing, не физических FPS/Pencil. | [118–123](audit-evidence/2026-09-25/user-ux-118-123.json) |
| Граница readiness/capture и показ endpoint | **USB iPad125: 2/2 guard PASS**: отзыв/восстановление готовности точного host и ожидание live endpoint без повторного capture/idle frames. В том же запуске **2 performance FAIL**, 0 skips/warnings; guard PASS их не отменяет. | [125–126](audit-evidence/2026-09-25/user-ux-125-126.json) |
| Визуальный контекст нового чата и полный фон бумаги | **USB iPad116: 2/2 PASS**, просмотр mounted/durable PNG, девять фоновых проб и пять маркеров. Причиной был неполный Canvas-фон под native transform, не ошибочная геометрия viewport. | [109–117](audit-evidence/2026-09-25/user-ux-109-117.json) |
| Принятые чернила, laser/Retry и большой контур | Physical113: material/laser **17 PASS**; cold 100 000 measurements: готовность 317,802 мс, pixel probes 426,996 мс при 500 мс. Core117 **38/38**, Codex **20/20**, SDK **5/5**, MCP type/generated check PASS. Не подменяет raw-page/whole-elements сценарий. | [109–117](audit-evidence/2026-09-25/user-ux-109-117.json) |
| Раздельный PDF cache проверочных и рабочих приложений | **Mac103 и USB iPad104: по 4/4 PASS**: bundle-scoped каталог, save/load/eviction и неприкосновенность соседей. Старый общий каталог не переносится и не удаляется. | [Изоляция cache](audit-evidence/2026-09-25/print-cache-isolation-103-104.json) |

U10: просмотренные изображения подтверждают целые позы и рамки без смешанных кадров; два переноса и откат — **76,994 / 74,065 / 70,104 мс** при прежнем лимите 100 мс. Copy/Delete прошли пиксельные проверки, но их успешные PNG не сохранялись. Последние Core-проверки порядка копий — **10 функций PASS**; прежние 24 Core/ScriptHost и 6 SDK относятся к своим срезам. Mac133 не получил готовность окна позади других окон; при единственном изменении тестовой установки окна на передний план Mac134 прошёл все пять проверок, production-код совпадает. Отрицательные результаты и ошибки компиляции не удалены; [точные исходники и материалы](audit-evidence/2026-09-25/whole-contact-selection-128-134.json).

Для базовых архитектурных изменений сохранены отдельные интеграционные квитанции:
[Core/JS/MCP](audit-evidence/2026-09-25/architecture-core-js-integration.json),
[Mac](audit-evidence/2026-09-25/architecture-mac-integration.json),
[Simulator](audit-evidence/2026-09-25/architecture-simulator-integration.json).
Они охватывают causal program identity/state FIFO, lifecycle, адресные окна/записи,
backlog/uploads/page order, notifications, export/clipboard, preview и worker cancellation.
Проверки сложности на 100 000 объектов относятся к указанным алгоритмам и source cuts.
Эти прежние результаты не являются новым полным прогоном на текущей базе `fcbc7888`.

## Незакрытые условия

| Условие | Фактическое состояние; что требуется для закрытия |
|---|---|
| **Raw-page Redo: правильный конечный кадр** | На базе `fcbc7888` два разных диагностических Simulator запуска снова дали третий `96 == 96`: каждый **0/1 PASS**, 0 skips/warnings, два journey завершены. Identity-only связывает submitted drawable с actual displayed page; 23 слоя ancestry неизменны, видимы, без mask/rasterization. Видео phase-run тоже показывает целую линию под свежим «Повторено», затем cut: это не только старый XCTest screenshot. В сохранённых кадрах fade не виден, но VFR gap 248,333 мс его не исключает. Диагностика не является чистой финальной приёмкой. [Фазы, owner и видео](audit-evidence/2026-09-25/raw-redo-phase-identity-video.json); [последняя чистая пара](audit-evidence/2026-09-25/release-8abb-redo.json). |
| **Raw-page inverse ≤100 мс** | Физический отказ **120,965 мс** и последующие отдельные PASS остаются без доказанного timing-fix. Ранее same-command-buffer readback подтвердил пустые retained/final drawable при старом окне спустя 185,038–315,377 мс (`framebufferOnly=false`, отдельный diagnostic). Нынешний phase-run имеет post-GPU CA commit/update-complete; failed screenshot начинается ещё через **162,111 мс после commit**. Ни GPU, ни CA callback не доказывают показ: граница до видимого кадра открыта. [Drawable](audit-evidence/2026-09-25/final-drawable-redo-probe.json), [фазы](audit-evidence/2026-09-25/raw-redo-phase-identity-video.json), [physical105](audit-evidence/2026-09-25/user-ux-105-native-failures.json). |
| **U10: финальная Release-пара** | Полный native-маршрут исправлен: физический iPad133 — **12/12 PASS**, Mac134 — **5/5 PASS**. Замкнутое лассо выбирает целый контакт вместе с фигурой; два переноса, отмена, Copy/Duplicate и Delete→Undo/Redo сохраняют весь материал и порядок. Нужен этот же путь в финальной паре. [128–134](audit-evidence/2026-09-25/whole-contact-selection-128-134.json). |
| **Холодный документ ≤1000 мс** | **USB iPad136: 1454,899 мс (тот же board), 1718,948 мс (другой) — оба FAIL**, correct=true, source готовится один раз. Native worker: **954,254/1013,711 мс thread CPU**, 99,76%/99,22% его wall; queue wait 0,018/0,007 мс, init <0,3 мс, output <0,4 мс. Основная стоимость — вычисление, не ожидание worker queue; это не process CPU duty или effective QoS. Request→installed уже 1220,500/1450,698 мс до capture. Неудавшийся exact-PID attach135 (exit21, процесс оставался жив) сохранён, usable trace нет. Временная диагностика удалена; исправление секунды не заявлено. [135–136](audit-evidence/2026-09-25/cold-document-cpu-135-136.json). |
| **Физический ink response ≤20 мс** | Предыдущие pen/eraser replay timing FAIL не закрыты; GPU-ready/логический commit не заменяют показ ОС. [Отрицательный A/B](audit-evidence/2026-09-25/warm-transaction-rejected.json). |
| **Первый кадр curl ≤16,67 мс и cadence 120 Гц** | **USB iPad125: строгий десятикратный curl — FAIL**: нулевые/невалидные OS receipts и интервалы до **29,178 мс при пределе 8,833 мс**. Они не исключаются из oracle. Защитный первый кадр сохраняется: его удаление показывало чужую страницу. [125–126](audit-evidence/2026-09-25/user-ux-125-126.json), [priming](audit-evidence/2026-09-25/physical-curl-priming-93-95.json). |
| **Единый финальный build: 10 journey + 30 минут** | Не пройдены. Чистая пара `8abb746f` и последующая диагностика `fcbc7888` остановлены на Redo; 30-минутная сессия после них не начиналась. Нужны согласованная пара, неизменные источники, обычные жесты, записи экрана и системные frame/CPU/GPU/memory измерения. |

Два последующих контроля raw Redo также дали третий `96 == 96`: продлённое участие UIKit и транзакция неподвижного кадра. Во втором журнал подтверждает `transactionPresentation=true`; оба кандидата удалены. [UIKit](audit-evidence/2026-09-25/idle-ui-demand-rejected.json), [транзакция](audit-evidence/2026-09-25/idle-transaction-rejected.json).

Контроль Metal-clock также отвергнут: 121 реальный пустой callback за две секунды, без повторного GPU frame, не изменил тот же отказ. Временный код удалён; [точное окно](audit-evidence/2026-09-25/metal-keepalive-rejected.json).

Пороговые значения не повышены; правильные пиксели после deadline остаются FAIL.
Новый успешный узкий повтор не отменяет несвязанный предыдущий отказ.

## Текущее изменение типовщика: граница результата

Один private 8 KiB ZIP reader устраняет сотни тысяч мелких File read/seek при
первом чтении 134 980 записей индекса. **ROOT Cargo: 6/6 PASS**; тот же AOT/guest.
Подготовка runtime для **Mac, iPhoneOS и Simulator: PASS**.
В парном Mac C ABI-контроле: **24/24 точных outputs**, fresh Runtime median
**895,1745 → 732,6975 мс** (18,075% median paired reduction); устойчивого warm
ускорения не заявлено. Это не iPad и не request-to-pixels.

Сохранены Read/Seek/EOF/error semantics, cancellation/deadline/recovery, PDF и
SyncTeX. Обычные шесть stat+read lookup читают на 35 601 байт больше из-за read-ahead;
полный искусственный обход local headers тоже имеет явно учтённое усиление чтения.
Кэш формата, сокращение TeX-проходов и ослабление safety/polling не вводились.
[Квитанция и точные границы](audit-evidence/2026-09-25/typesetter-zip-reader.json).
Новый physical125 подтвердил правильное холодное изображение, но **1985,010375 мс
не проходят 1000 мс**. Mac-ускорение не переносится на iPad арифметически.
Адресный same-artifact126 также **FAIL: 1977,670541 мс**, correct=true.
Его фазы: artifact 1243,949 мс / canonicalPrint 1245,030 мс; запрос→установка
1707,355 мс, contentReady→установка 321,021 мс. Shell ready занимает 69,543 мс,
browser render около 2 мс, receipt около 7 мс: основное ожидание здесь — печатный
артефакт и завершение навигации, не обработка browser frame. Интервалы перекрываются;
их нельзя складывать или выдавать время оконного наблюдения за photon timing.

Hash-таблица fontmap теперь растёт у своего владельца, сохраняя адреса записей
и порядок дубликатов. На 100 000 ключах реальные сравнения сокращены с 19 789 634
до 115 985, плюс 257 024 линейных шагов перераспределения. C regression с
ASan/UBSan, точные PDF/SyncTeX/log, отмена/deadline/recovery и подготовка трёх
платформ — PASS. Парный Mac fresh Runtime: 911,077 → 820,912 мс, median paired
reduction 8,778%; физический порог пока не проверен на этом kernel. Глобального
cache нет, TeX-проходы и memory ceiling прежние.
[Квитанция fontmap](audit-evidence/2026-09-25/typesetter-fontmap.json).

Следующий адресный срез читает fontmap частями по 8 KiB: 4 408 062 перехода
через C/Rust bridge заменены на 540 без изменения underlying reads/bytes.
100 000 строк, точные PDF/SyncTeX, отмена и prepare/check трёх платформ — PASS;
Mac fresh median 790,241 → 684,856 мс. Физический127 выше подтверждает
правильный документ, но не закрывает секунду.
[Квитанция чтения](audit-evidence/2026-09-25/typesetter-fontmap-stream.json).

Текущий app-only профиль относит 86,57% Running samples к TeX, 12,68% к PDF; лишний запуск подготовки не найден. [Профиль](audit-evidence/2026-09-25/typesetter-current-profile-policy.json). В последующем тихом контроле `-O3` ухудшил fresh-компиляцию во всех шести парах (median −8,485%); перенос двух TLS-полей дал лишь неустойчивые +3,035% при росте кода на 1,38%. Оба кандидата отклонены, runtime и safety-проверки не изменены; точные outputs и отрицательные пары сохранены. [Контроли](audit-evidence/2026-09-25/typesetter-execution-rejected.json).

Сборка из изолированного source snapshot теперь берёт закреплённый TeX distribution
из выбранного runtime stage, а не повторно загружает 2,88 GB в каждый snapshot.
Проверки pin/inventory сохранены; шесть адресных packaging tests — PASS.

## Среда и допустимые выводы

- **USB iPad:** native UIKit/Metal/WebKit и реальные pixel captures в private test
  app подтверждают свои fixtures. Обычный physical UI automation route ранее
  остановился на включении automation mode; последующий native PASS этого не заменяет.
- **Simulator:** выбран пользователем для автоматической пары и ordinary gestures.
  Он не измеряет реальные FPS iPad, latency Apple Pencil или физический input-to-photon.
- **Mac C ABI / app-only Time Profiler:** подтверждают только названный процесс и
  workload. Samples не являются CPU duty; CADisplayLink не является измерителем FPS.
  Неполный/прерванный trace не выдаётся за завершённую системную сессию.
- Все перечисленные private/native запуски отделены от production. Новые данные
  fixtures допустимы для подготовки/сбоев, но не подменяют обычную навигацию и жесты.

## Где лежат исходные доказательства

Tracked receipts: [`docs/audit-evidence/2026-09-25/`](audit-evidence/2026-09-25/).
Они содержат source SHA, фактические результаты, manifest SHA и точные пути к raw
`.xcresult`, attachments, videos/traces и журналам. Пакеты не переписываются новым PASS.
Основной локальный корень:

```text
/Users/amir/.codex/worktrees/notebook-architecture-repair/Notebook/
  .build/notebook-architecture-repair/evidence-2026-09-25/
```

Актуальные адресные пакеты: `user-ux-124`, `user-ux-122-123`, `user-ux-118-121`,
`user-ux-115-117`; точные остальные пути — в соответствующих receipts выше.
Для ZIP C ABI/reader материалы указаны в receipt как `/tmp`. Связанный receipt
`user-ux-125-126.json` собирает оба завершённых запуска; raw-материалы находятся в
`/tmp/notebook-user-ux-125/` и `/tmp/notebook-user-ux-126/` до указанного в receipt
переноса в sealed bundle. Все performance FAIL сохраняются без переименования в PASS.
Полный прежний журнал остаётся в
[git `4483fefa`](https://github.com/AmirTlinov/Notebook/blob/4483fefa82ab7fbc65d69401b713d60e238cc904/docs/verification.md);
новый исторический файл или резервная копия не создаются.

## Другие независимые условия и следующий шаг

[Карта надёжности](reliability-transition.md) отдельно указывает GUI-196
(физический erased-material), GUI-197 (causal convergence/human continuation),
GUI-183 (WAN/multidevice Codex) и performance/long-session объём GUI-250.
Их текущий Linear-статус и отдельная приёмка **в этом срезе не перепроверены**;
ремонт GUI-306 не закрывает их заочно. GUI-240 закрыта решением Амира, не измерением
всех перечисленных performance-условий.

Далее — причинная регрессия открытого пути и его пользовательский сценарий;
`./verify.sh --plan` помогает выбрать scope. Полная приёмка — отдельный запуск,
не обязательный ритуал после каждой правки. Одновременно работает один Xcode runner.
После нового результата обновляется соответствующее состояние этой сводки и receipt,
а не дописывается очередной хронологический раздел.
