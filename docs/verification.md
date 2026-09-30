# Текущее состояние проверки Notebook

Срез: **30 сентября 2026**. Функциональная проверка, доставка и полная приёмка
учитываются отдельно; результат относится к исходникам своего receipt.

## Первый показ и объединённый admission repair — 226

**0.3.156 (226)** установлена поверх225 на Mac и физическом iPad
30сентября06:36UTC (09:36МСК). Source
`18a5cbf03740f12d40127809f4674ea89404cd317348f09b669eab6a636c4e47`.
Одна Notebook Lab, QA/test apps отсутствуют. Installed helper ready; прежний
доверенный iPad подключён к тому же workspace с новой сессией, page/camera
presence восстановлены. Mac завершён штатно перед заменой бинарника. Обновление
сохранило bundle/app-group identity; iOS заменил путь data container.
Визуальный просмотр Mac после установки недоступен: свежий Computer Use binding
вернул ScreenCaptureKit−3811. [Доставка](audit-evidence/2026-09-30/first-presentation-scheduling/delivery.json),
[точные исходники и результаты](audit-evidence/2026-09-30/first-presentation-scheduling/results.json).

Физический0610: **22native PASS**, один UI24 FAIL при Window-pinch, доставившем
контакты внутрь control6. Изменён только target существующего жеста на
`page-turn-surface`; product/native-test sources сохранены. Финальный0622:
**UI24 PASS** — первые taps после pinch, close/reopen, forward/reverse и точные
состояния. Финальный0625: **4Mac PASS** — writer refusal/checkpoint, native
ink/text export, tile seams и light-ink vision. Skip/runtime warnings=0.
Отрицательный Window-pinch результат и его реальные pointer coordinates
сохранены; публичный XCTest pinch остаётся best effort.

[Продолжение31–33](performance-repair-2026-09-30.md#продолжение31–33--первый-полезный-показ)
установило пять GPU compiler waits на Main и вывело shared GPU producers в worker.
Повторный CPU profile:0 Main compiler samples,6 worker stacks. Constructor
allowance всех WK factories проходит через scene owner и освобождается после
UI completion; navigation/JS не держат его. Очередь фоновой подготовки отделена
от принятых visible/input запросов. Уход программы принимает immutable
checkpoint source/basis и возвращает browser независимо от optional picture.
Pressure regression0601: точный сохранённый момент на возврате PASS.

Финальный0606: **3 scheduling observations PASS**. Cold24 first native418,636мс,
all937,754мс, largest CA commit31,124мс; максимум2 constructors и UI completion
между допусками. Последующие warm dot18,675мс/curl34,600мс в том же процессе.
Эти observations проверяют event coverage и owner handoffs; строгие latency
budgets остаются открытыми. [Системная граница curl](audit-evidence/2026-09-30/first-presentation-scheduling/curl-system-boundary.json)
связывает GPU, CA и display-swap одного процесса: successor публикуется до
predecessor OS, первый discard происходит до следующего present. Его системная
причина и дальнейшее разделение WebKit launch/IPC пока не установлены.
Эксперимент с постоянно раскрытым container полностью удалён после ухудшения
regrab/cancel. Hardware Pencil delivery и полная приёмка здесь не выполнялись.

## Ремонт D01–D16 — 225

[Изменения и удалённые пути](performance-repair-2026-09-30.md) реализованы от
`c140b804`; **0.3.155 (225)** установлена поверх224 на Mac и физическом iPad
30сентября03:11UTC (06:11МСК). Source
`1df1f16cc235857fee8a06b63dad3d4257a36a36e24d42964ff9ddeb279998a6`.
Одна Notebook Lab, QA/test apps отсутствуют. Helper ready, прежний доверенный
iPad подключён к тому же workspace с новой сессией; страница/камера восстановлены.
iOS изменил путь data container при обновлении: буквальная проверка пути остановила
installer после успешной установки. Завершение Mac выполнено отдельно без повторной
установки iPad, удаления данных или восстановления архива. Идентичность и доверенная
связь проверены после запуска. Повторный визуальный просмотр окна Mac после
установки не выполнен: захват возвращает ScreenCaptureKit−3811.
[Доставка](audit-evidence/2026-09-30/performance-repair-225/delivery.json),
[точные области проверки](audit-evidence/2026-09-30/performance-repair-225/results.json).
Core100k/sparse/UTF-16/source digest PASS:1 XCTest и3 Swift Testing метода
(4cases) в2258, digest отдельно в2333.
Physical0035:16native+UI mixed PASS,
UI24 FAIL;0142:10iPad+3Mac PASS;0159:6iPad+4Mac PASS (native PDF до held DOM,
new source при старом held sender, cancellation/local program cut).
Точный scope и source каждого результата сохраняются в receipts.
0240:5iPad+1Mac PASS — held first-paint bridge, never-ready статус, mixed cut,
held DOM и UI24. Эксперимент curl этого прогона затем удалён.
Финальный0251:3iPad+1Mac PASS, source
`1df1f16cc235857fee8a06b63dad3d4257a36a36e24d42964ff9ddeb279998a6`;
первый изгиб, отмена capture, UI24 с сохранением состояний и Mac repeated zoom.

[0146](audit-evidence/2026-09-30/performance-repair-225/metrics-0146.json): строгие
5 сценариев FAIL. Dot24,324мс при цели20; SVGfirst314,918/programsfirst396,156мс
при цели150; Native24 landing497,910/484,675мс при цели450; Warm firstOS25,735–39,449мс
при цели16,667. Reverse24 authored pixels тоже FAIL.
[0213](audit-evidence/2026-09-30/performance-repair-225/native24-0213.json):
24states/pixels PASS, landing452,745/515,296мс FAIL. Это невоспроизведение прежнего
pixel failure, а не снятие его свидетельства.

Удалены установленные CPU-причины CIContext/grid raster MainActor, повторная
plain-paper подготовка и successor OS barrier. Первый transactional present/drop
и часть WebKit launch/IPC задержки остаются открытыми. CPU0220 установил перекрытие
present и worker nextDrawable/IOSurface; lock waiter ещё не установлен. Эксперимент
0243 сократил present, но ухудшил firstOS и gaps; полностью удалён из выпуска.
Финальная граница slot bridge
удерживает сохранённые pixels над новым WebKit до exact first-paint receipt.

## Исходное причинное ревью — 30 сентября

[Глубокое ревью](performance-review-2026-09-30.md) выполнено на чистом
`e4948f8e`; source inventory совпадает с224. Подтверждены оставшиеся полные
проходы, cross-owner ожидания и ошибки readiness/transition identity.
Продукт не изменялся, новых прогонов/измерений нет; результаты ниже сохраняют
свой scope. План продолжен в существующей GUI-306 и профильных задачах.

## Предыдущая установленная пара — 224

**0.3.154 (224)** установлена поверх223 на Mac и физическом iPad
29 сентября в19:28UTC (22:28МСК). Код `28f11aee`, source
`0a4be7f8f9205fe433877a9680d76cb1ed94615f7d0deb36ec06f1d1f808b14d`.
Одна Notebook Lab; QA/native-test/runner удалены. Содержимое, идентичности и
ключи сохранены. Mac helper отвечает ready; прежний iPad подключился с новой
сессией. [Сборка, установка и подключение](audit-evidence/2026-09-29/first-presentation-224/delivery.json).

## Реализованный срез224

Source `0a4be7f8f9205fe433877a9680d76cb1ed94615f7d0deb36ec06f1d1f808b14d`.
Бумага монтируется независимо от board paint. Единственная подготовка страницы
принимается существующим native shell после загрузки тела; native window допускается
до фабрики представления. UUID/controller/address защищают от позднего callback.
Камера ждёт точную бумагу либо установленную обложку и завершает отмену вместе с
ожиданиями. Spatial cohort больше не читает/копирует PageDocument при записи
состояния программы. Page attention и ввод используют установленную бумагу.
Curl сохраняет один учтённый pool, завершает GPU/OS retirement и держит successor
до исхода первого transactional кадра. [Контракт и удалённые пути](interaction-ownership.md).

Последняя правка сохраняет задачу и очередь при смене ввода/фокуса; меняется
приоритет прежнего requestID, а reclamation выполняется после native update.
`1913Z`, текущий source: **5iPad+1MacPASS**, без skip/runtime warnings. Проверены
очередь/приоритет, отключение ввода, отмена, смена состояния/плотности, реальные
24 первых нажатия и pinch/forward/reverse, Mac focus/uncommitted input.
`1919Z`: **2 cold latency FAIL**; SVG first496.130/all636.387мс,
programs first409.023/all700.479мс. Точные источники/поздние пиксели PASS.
Запросов программ теперь24 вместо46; SVG завершают те же2исполнителя
вместо отмены первых двух и создания4. Каждый исходник запускается один раз.

Проверки предшествующего среза `f462f08f…` и его непосредственных исправлений:

- `1822Z`: 15PASS/3FAIL. Найден реальный запуск дублирующих программ после late
  page load; исправлено принятие единого page owner. Два других FAIL — ошибочные
  требования к чужим освобождённым ресурсам и старой позе камеры в тесте.
- `1851Z`: 5PASS/1FAIL. Реальные24 первых нажатия, pinch-exit/reopen, страницы
  вперёд/назад и сохранение состояний PASS; также ранняя бумага/тот же host,
  точная отмена curl, подготовка и перенос attention. Единственный FAIL — новая
  тестовая программа без обязательного notebook.ready; исправлен только fixture.
- `1856Z`: 1iPad+1MacPASS. Late read/borrow/retirement и настоящий Mac click/drag
  без board cohort. От1851 изменён только этот fixture. Runtime warnings/skip=0.
- `1900Z`, тот же source: 3 latency FAIL. Все источники и независимые поздние
  пиксели верны; cold OS first-pixel не измерен. Замер закончился до снимков/DOM.

| Сценарий | Результат1900 | Цель |
|---|---|---|
| Cold SVG13 | first485.106/all600.304мс;13/13 | first≤150/all≤1000мс |
| Cold programs24 | first445.270/all726.313мс;24/24live | first≤150/all≤1000мс |
| Warm10 firstOS | 29.290–37.787мс;1initialdrop каждый | ≤16.667мс |
| Warm10 landing | 322.527–333.840мс | ≤450мс |

Programs: accepted78.51→mounted113.79→cohort233.47мс — зависимости mount от
cohort больше нет. Первый готовый source: navigation88.82→policy291.73→started431.53
→runtime435.05мс. Основной остаток лежит до готовности WebKit; повторныхnavigation нет.
Curl successor GPU готов до первогоOS и предъявляется сразу после receipt;
первый CA→async OS-интервал16.673мс, далее8.337мс. Создание pool и повторный encode
не объясняют этот остаток. Причина initialdrop/CA handoff ещё не доказана.
[Точные результаты и отрицательные прогоны](audit-evidence/2026-09-29/first-presentation-224/results.json).

Срез223 ранее прошёл native8/Mac2/Core3 и системныйUI24 после разрешения XCTest.
Его строгие cold-document1137.137мс, Native24 landing456.562мс и firstcurl24.670–36.800мс
не уложились в1000/450/16.667мс. Это исторические измерения своегоsource.
[Свидетельства223](audit-evidence/2026-09-29/interaction-completion-223/results.json).
Полный прежний текст223 сохранён в
[ревизииa43e8ae0](https://github.com/AmirTlinov/Notebook/blob/a43e8ae04c1bb2e845dc8c1fcc2cbab934554853/docs/verification.md).

## Подтверждённые границы предшествующих срезов

Таблица описывает область доказательства; каждый receipt сохраняет собственный
исходник и отрицательные прогоны. Эти результаты не складываются в текущий full PASS.

| Срез | Подтверждённая граница | Свидетельство |
|---|---|---|
| 215 | Current demand, поздние callbacks, 24 первых нажатия/state/forward/reverse; отдельная schema27 migration | [Causal repair](audit-evidence/2026-09-27/causal-repair.json) |
| 216 | Выход pinch без обратного приближения; повторное открытие notebook/document с канонической геометрией | [Exit camera](audit-evidence/2026-09-28/exit-camera.json) |
| 217 | Контакт/камера/UUID, первый reveal, общий mixed cut, отмена и source replacement; финально 6 iPad + 9 Mac PASS | [Interaction ownership](audit-evidence/2026-09-28/interaction-ownership.json) |
| 218 | Retained passive frame, fresh runtime cut, detach/remount/regrab, system UI24; 13 iPad PASS | [Page turn](audit-evidence/2026-09-28/page-turn-latency.json) |
| 219 | Paper input отдельно от программ; scoped cancellation/physical crop, mixed journey; системный снимок конечной композиции | [Results 219](audit-evidence/2026-09-28/interaction-latency-219/results.json) |
| 220 | Отмена пары, ресурсные хвосты, immutable TeX resources; 8 iPad + 2 Mac + 6 Rust PASS в своих прогонах | [Results 220](audit-evidence/2026-09-28/interaction-latency-220/results.json) |
| 221 | Недопустимая цель камеры не блокирует fitted paper; 3 native + 1 system UI PASS | [Results 221](audit-evidence/2026-09-28/camera-target-221/results.json) |
| 222 | Reentrant/cancelled capture, малое состояние, page-only revalidation, peer spatial negative control, UI24/mixed; 10 iPad PASS | [Results 222](audit-evidence/2026-09-28/interaction-completion-222/results.json) |

Полный прежний текст 215–222 с отдельными отказами и source witnesses сохранён
в [неизменной ревизии 62599fc3](https://github.com/AmirTlinov/Notebook/blob/62599fc3e9f224fa7dac1961327d5b415a1db4e4/docs/verification.md).
Ранние аудиты остаются в [исходной сводке](https://github.com/AmirTlinov/Notebook/blob/dbaf04e94268d8d9e914a2a33b801691a2129d57/docs/verification.md)
и `docs/audit-evidence/`. Текущие контракты — в [interaction ownership](interaction-ownership.md),
а задачи и зависимости — в Linear, GUI-306.

## Что остаётся открытым

- Строгие cold document/SVG/programs, Native24 и first-curl бюджеты.
  Исторический 222 `2036` также дал 3 FAIL: programs first/all 657,071/1042,508 мс,
  Native24 552,242 мс, first curl до41,030 мс. Разный порядок cold-сценариев не
  позволяет приписать всю разницу текущему исправлению.
- Каждый Pencil/eraser sample ≤20 мс не принят. В 220 dot был 20,045 мс до OS
  при GPU completion 4,210 мс; более ранние pen/eraser также превышали бюджет.
  Нужна целая цепочка contact revision → callback/target → submission/GPU →
  actual presentedTime. Подача через native recognizer не измеряет аппаратную
  доставку Pencil. `CADisplayLink` не является FPS-измерением.
- Системный итоговый снимок mixed cut не доказывает каждый промежуточный OS-кадр.
  Исторический inverse-journey2009: accepted GPU cut содержал штрих, OS receipt
  23,023 мс, но `drawHierarchy(false)` его не показал. Independent display oracle
  final drawable/CA composition остаётся открытым; исходный FAIL не удалён.
- App-only Time Profiler `2042` не нашёл тестовый PID и не дал причинного CPU-стека.
  Системные frame/CPU/GPU/memory характеристики текущей пары ещё не приняты.

## Доставка и полная приёмка

Обновление выполняется на месте, сохраняя контейнеры, контент, идентичности и ключи.
Schema27 требует согласованной пары; старый helper schema26 не запускается против
обновлённого workspace. `saved`, `receivedByIPad` и `shownOnIPad` подтверждаются
отдельно; запуск release-приложения не заменяет физическую проверку сценария.

Full acceptance, GUI-190: **не выполнена**. Нужны десять повторений сценариев,
30 минут совместной работы и системные frame/CPU/GPU/memory измерения одной пары.
Этот срез не закрывает GUI-196 (erased-material), GUI-197 (causal continuation),
GUI-183 (WAN/multidevice) и длительную GUI-250. GUI-240 закрыта решением Амира.
