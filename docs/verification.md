# Текущее состояние проверки Notebook

Срез: **27 сентября 2026**. Источник поведения — код и source witness конкретного
прогона. Прошедшие отдельные проверки не складываются в полную приёмку.

## Ремонт причин F01–F18

[Диагноз](causal-audit-2026-09-27.md) и [изменения владельцев](causal-repair-2026-09-27.md).
База `dbaf04e94268d8d9e914a2a33b801691a2129d57`, ремонт `82cb8f98` + `efbb9c2b`.
**0.3.145 (215) установлена и запущена на Mac и физическом iPad.**
Установленная 214 выявила ошибку миграции retained page erasers: публичный
live-page gate возвращал `target_missing` до открытия IPC. Исправление прошло
Core-регрессию в 2218 (3 теста, migration 0,145 с); 215 успешно открыла рабочую
Mac-базу на schema27. Установленный MCP и текущая iPad presentation session
отвечают `ready`. Это подтверждает запуск и связь, не весь UX. GUI-306 In Progress.
UI24 и три stale-callback проверки прошли в 2150. После аналогичного исправления
current demand в обработчике ошибки финальный прогон 2158 дал 3 PASS: поздние
ошибки, snapshots и readiness после invalidation. UI24 повторно не запускался.
Исправлены границы Observation/layout,
capture скрытого листа, live landing, установленного материала и адресного окна
страниц. Полный native-путь листов и mixed UI journey подтверждены в 2044;
после исправления current demand у PreparationOwner все 24 программы сохраняют
state и возвращаются на reverse (2150). Строгие задержки ниже остаются незакрытыми.

- Удалены pair hierarchy capture на жесте, cold ink decode из body, полный ordered
  replay на pen-frame, глобальные read/navigation joins и monolithic cloud walk в writer.
- Введены immutable GPU cut с точной идентичностью источника, независимые GPU/OS
  receipts, адресный read-set/admission и порционная durable cloud preparation.
- Вход, zoom-out и программы сохраняют контракт GUI-314: тетрадь вписана в экран,
  уменьшение возвращает к обложке, документ сохраняет чтение с увеличением.
- Исходники и ответы не выдаются за физический показ. Результаты iPad и Mac
  относятся к указанным сценариям и source witness; общего final PASS нет.

[Машинные результаты, источники и отрицательные запуски](audit-evidence/2026-09-27/causal-repair.json).

## Подтверждённый объём

| Проверка | Результат и действительная граница |
|---|---|
| Core и browser, 1728 | 44 Swift Testing + 2 XCTest; 15 browser PASS. Неизменный относящийся к ним код проверен по inventory. Весь запуск не PASS: последовала ошибка native compilation. |
| Schema 26→27, 1845 | Дополнительный Core migration PASS, 80 мс; реальные измерения штрихов, порядок и page erasers сохранены. Это не измерение миграции рабочего контейнера. |
| Retained-history migration, 2218 / установленная 215 | Core: 3 PASS, включая 4 варианта writer admission; migration 0,145 с. Удалённая тетрадь с сохранённым ластиком индексируется, публичный gate сохраняется. Рабочая Mac-база открылась на schema27; 40 669 записей совпадают с состоянием перед запуском 215, изменились только три runtime-записи. |
| Physical integration, 1811 | 129 PASS / 8 FAIL, без пропусков/runtime warnings. Проверены selected input, mixed selection, ресурсы, ссылки, программы и поздние публикации. Последующие изменения readiness проверены адресно в перечисленных ниже запусках. |
| Continuous board zoom, 1811 | 24 программы, 10 итераций: XCTHitchMetric = 0. Это системный hitch metric, не FPS и не physical Pencil latency. |
| Mac selected checks, 2008 | 9 PASS, без failures/skips/runtime warnings: render session и print read-set invalidation. |
| Dense turns, 1952 | Forward/reverse: 10 повторений, все XCTHitchMetric=0. Весь запуск: 55 PASS / 4 FAIL; это не общая приёмка. |
| Physical capture boundaries, 2028 / 2125 | В 2028 прошли immediate accepted ink/erase→curl, source replacement during borrow и receipt retirement; весь запуск 5 PASS / 3 FAIL. В 2125 новый GPU-source cancellation fixture PASS 0,073 с, immediate accepted erase→curl PASS 0,840 с. Весь 2125: 2 PASS / 1 FAIL с двумя assertions в Native24. |
| Physical journeys, 2044 / addressed read, 2101 | Native full leaf journey PASS 3,654 с: реальные admission/cancellation и проверка начальной страницы; first ink новой страницы 72,526 мс. Mixed system UI journey PASS 46,601 с, включая undo/redo и cold reopen. Весь 2044: 2 PASS / 2 FAIL. Address negative control исправлен с запрещённого page zoom на portrait→landscape fitted projection и прошёл в 2101 за 0,252 с. |
| Accepted-turn cuts, 2118 / 2139 | В 2118: 9 PASS / 2 FAIL; UI24 PASS 75,410 с, document live/static/status, cover и resources прошли. Native24 был медленнее 450 мс, старый UIKit cancellation fixture заменён GPU fixture в 2125. В 2139: 6 PASS / 2 FAIL; прошли AgentWeb invalidation, cover reuse, document live/status и native reopen visibility. После всех 24 first taps и forward на reverse осталось 23/24 controls (99,672 с); этот отказ сохранён. |
| Current program owner, 2150 | **4 PASS / 0 FAIL**, без skips/runtime warnings. System UI24: все first taps, state, forward/reverse — PASS 76,579 с; три AgentWeb stale-callback проверки PASS. Старое passive completion больше не отзывает активный WebKit по прежнему demand. Completed receipt: source `18ed4bd20097805b91770e3156672806dac23d4212dd3b7235af26fcef5a8d58`, 1547 файлов до/после без изменений. Это выбранная функциональная проверка, не повтор строгих latency tests. |

Core-результаты относятся только к своим неизменным зависимостям; изменения
storage в 215 проверены отдельно в 2218. Release-пара собрана из указанного
source inventory; длительный S7 не выполнялся.

## Не закрытые показатели

| Условие | Что установлено |
|---|---|
| Cold document ≤1000 мс | **1227,793 мс, FAIL**, правильный source установлен. Artifact 979,001 мс, native TeX compile 965,158 мс; queue 0,024 мс. Same-bytes disk hit 320,713 мс. Главный расход cache miss — исполнение compiler; устранённые глобальные joins не объясняют этот остаток. |
| Cold SVG13 / programs24 ≤150 мс | Первые probes: 157,996 / 315,962 мс, correct=false; полный правильный результат в 751,614 / 785,233 мс. Нет отдельного phase witness, разделяющего initial scene preparation и WebKit startup. |
| Native24 command→landing ≤450 мс | **1052,976 мс в 2118; 891,617 мс в 2125; 749,149 мс в 2139 — FAIL**. В 2139 pair начат на +36,433 мс, source/target captures — 165,709 / 41,893 мс, pair готов на +246,641 мс; первый наблюдённый curl OS frame — +325,829 мс, endpoint OS — +638,455 мс. Stage callback не было; landing — polling observation, не OS receipt. Reopen visibility FAIL 2125 сменился PASS после paint fix в 2139. Watchdog 9 с не меняет бюджет 450 мс. |
| Каждый Pencil/eraser sample ≤20 мс | CAMetal-кандидат1845: OS p50 25,106 / 20,754 мс, FAIL; handler <1,8 мс. Отклонённый UI phase clock1923 ухудшил p50 до47,377 /44,841 мс и удалён. Строгая цель на итоговом коде не подтверждена. |
| Первый curl ≤16,67 мс, cadence120Гц | Старый pair capture стоил70,84–109,89 мс. В1811 отдельный first curl: GPU готов +2,304 мс, target +17,296083, OS +17,296250. Дальше наблюдались интервалы8,3367 мс. Есть потерянный первый receipt; строгий тест FAIL. Это локализация ожидания, не доказательство неизбежного системного предела. |

Недостающая адресная проверка Pencil: одна цепочка contact revision → CAMetal
callback/target → submission/GPU completion → actual presentedTime. Для cold
SVG/programs нужны времена initial cohort и первого установленного WebKit output.
Правильные поздние пиксели и GPU completion не заменяют прохождение deadline.
Пороги не повышены. Неудачный UI phase clock удалён; проходы TeX и его порог не менялись.

Inverse-journey2009: exact accepted GPU cut содержит новый штрих, OS receipt
23,023 мс, но UIKit `drawHierarchy(false)` его не показывает. Потеря retained
body исключена; final drawable/CA composition ещё не проверены независимым
display oracle. Исходный FAIL сохранён и не повторяется ради зелёного результата.

## Установка и полная приёмка

Обновление согласованной Mac/iPad пары выполняется на месте: контейнеры,
идентичности и ключи сохраняются. Исторические архивы не открываются.
Schema27 вводится только согласованной парой; старый helper schema26 после
миграции не запускается против обновлённого workspace.

215 установлена 27 сентября в 22:24 UTC. Source SHA256:
`e117522d718ff8ca8fb77367d092f56a9b3ea4542cdefc790f6d024f0e4c5f40`.
В рабочей Mac-базе осталось 40 672 записи. Изменились только `runtime/input.json#`,
`runtime/local-selection.json#`, `runtime/selection.json#`: новые сессии и выделение
после подключения. Подстановка их прежних hashes восстановила исходный SHA256
всех address/hash; остальные 40 669 записей, включая контент, неизменны.
Проверка SQLite выполнялась только чтением. iPad сообщил текущую authenticated
presentation session; новые пользовательские записи для проверки не создавались.

Full acceptance остаётся отдельной задачей GUI-190: десять повторов сценариев,
30 минут совместной работы и системные frame/CPU/GPU/memory измерения одной пары.
Отдельно подтверждаются saved, receivedByIPad и shownOnIPad. Этот срез не закрывает
заочно GUI-196 (erased-material), GUI-197 (causal continuation), GUI-183
(WAN/multidevice) и долгую сессию GUI-250. GUI-240 закрыта решением Амира.

Исторические receipts прежних ремонтов и их ограничения сохранены в
[сводке перед этим изменением](https://github.com/AmirTlinov/Notebook/blob/dbaf04e94268d8d9e914a2a33b801691a2129d57/docs/verification.md)
и `docs/audit-evidence/`. Текущие задачи и зависимости — в Linear, GUI-306.
