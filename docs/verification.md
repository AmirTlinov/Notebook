# Текущее состояние проверки Notebook

Срез: **29 сентября 2026**. Результат относится к исходникам своего receipt.
Функциональная проверка, доставка и полная приёмка учитываются отдельно.

## Установленная пара — 223

**0.3.153 (223)** установлена 29 сентября в 13:36 UTC поверх 222 на Mac и
физическом iPad. Код выпуска `f81b17c2`; source SHA256:
`23fa7416e9b6eff5a9704b29e2a376463c3d353a2deac5b6672b42461960a175`.
Mac-помощник и новая authenticated session прежнего iPad отвечают `ready`.
На iPad одна Notebook Lab, QA/native-test/runner удалены после проверки.
Контейнеры, идентичности и ключи сохранены; исторические архивы не открывались.
[Сборка, установка и подключение](audit-evidence/2026-09-29/interaction-completion-223/delivery.json).
Системная проверка жестов `1606Z` прошла после разрешения XCTest на iPad.
Проверены 24 первых нажатия, pinch-выход и повторное открытие, переходы
вперёд/назад с сохранением состояния всех программ. Строгие бюджеты остаются открытыми.

## Реализованный срез 223

Изменения: существующий WebKit session начинает принятую загрузку до mount;
GPU completion напрямую возобновляет владельца кадра с сохранением priority donation;
локальный program state сохраняет геометрическую проекцию;
публикация одинакового scene source сохраняет принятое поколение.
[Точные владельцы, отмена и удалённые пути](interaction-ownership.md#передача-подготовленного-исполнения-и-публикации--223).

### Завершённые проверки

- Физический iPad `1229Z`: **8 PASS / 6 FAIL**, 0 skipped/runtime warnings.
  Пять FAIL — строгие latency assertions; шестой — XCTest не включил automation
  mode, поэтому системный UI-сценарий в этом запуске не исполнился.
- Восемь PASS: accepted-source navigation; освобождение session без mount;
  retirement с незавершённым physical borrow; отмена обеих сторон capture;
  ориентация shader/flat endpoints; regrab той же пары; checkpoint уходящей
  программы; late-equivalent scene index без нового plan/native ink, с обязательной
  заменой при реальном перемещении предмета.
- Core `1240Z`: **3 PASS**. Адресное program state сохраняет чужой контент и
  причинные версии; крупное состояние удерживает admission через FIFO/checkpoint;
  state projection сохраняет неизменную геометрию и заменяет изменённые claims.

Source inventory физического `1229Z`:
`3154dd099b359a2af66b5319fa08709a92539b5be98fa8d88d851fc872d61b08`.
Локальное свидетельство: `/private/tmp/notebook-223-physical-20260929T1229Z/`
(`source-before.json`, `ipad-summary.json`, `ipad-tests.json`, `ipad.xcresult`);
attachments: `/private/tmp/notebook-223-attachments1229/manifest.json`.
Core log: `/private/tmp/notebook-223-core-20260929T1240Z.log`.

Итоговый код `f81b17c2`: `1241Z` — **8 native iPad PASS / 1 infrastructure FAIL**.
XCTest снова не включил automation mode; сами системные жесты не исполнились.
После обычного и принудительного перезапуска служб отказ сохранился.
После полной перезагрузки iPad первое разблокирование выполнено: в 13:27 UTC
`lockstate=false`, `unlockedSinceBoot=true`.
Mac `1246Z`: **2 PASS**, 0 FAIL/skip/runtime warnings — один владелец до первого
нажатия, сохранение WKWebView, несохранённого ввода и растров при повторном zoom.
Source-before `1241Z` совпадает с before/after `1246Z` и установленной парой.
Отказавший `1241Z` не создал отдельного source-after.

UI `1327Z` и `1337Z` остановились до первого жеста: отдельный системный запрос
«Введите код-пароль iPad для приложения XCTest — Enable UI Automation» не был
подтверждён за 60 секунд. Обычное разблокирование iPad его не заменяет.
После подтверждения UI `1606Z`: **1 PASS**, 0 FAIL/skip/runtime warnings.
Before/after совпадают с установленным source `23fa7416…`. Сценарий выполнил
настоящие жесты и нажатия; проверены первый tap каждой из 24 программ,
выход pinch до обложки, повторное открытие с прежним состоянием и геометрией,
переход вперёд/назад с сохранением всех 24 состояний. Длительность теста включает
AX и снимки; это функциональное свидетельство, а не измерение задержки приложения.
После проверки тестовые приложения удалены, установленная Notebook Lab запущена.
[Результаты, source witnesses и отрицательные прогоны](audit-evidence/2026-09-29/interaction-completion-223/results.json).

### Строгие бюджеты: отрицательный результат сохранён

| Сценарий | `1229Z`, физический iPad | Граница измерения |
|---|---|---|
| Cold document ≤1000 мс | **1137,137 мс — FAIL**; native TeX 856,814 мс | Запрос → canonical native paper/input; не OS presentation |
| Cold SVG13, первый ≤150 мс | **283,036 мс — FAIL**; все 449,817 мс | Первая точная native installation; 13/13 источников и поздние пиксели верны |
| Cold programs24, первый ≤150 мс | **429,636 мс — FAIL**; все 758,518 мс | 24/24 точных live runtime; поздние пиксели верны |
| Native24 command→owner landing ≤450 мс | **456,562 мс — FAIL** | Callback завершения владельца; верные состояния не снимают превышение |
| Первый warm curl ≤16,667 мс | **24,670–36,800 мс — FAIL**, 10 поворотов | Первый OS receipt каждого поворота |

Полная cohort SVG/programs уложилась в 1000 мс; цель первого кадра не выполнена.
Начало navigation, native installation, GPU completion и OS presentation — разные
события. Capture/decode и DOM-проверки выполняются после cold-замера.
Точный первый OS-пиксель cold SVG/programs пока не измерен.
Пределы, анимации, число программ и проходы TeX не сокращены.

Фазовый `1214Z` показал второй cohort во время запуска программ. Исправлена
гонка independently prepared index → новый UUID того же принятого source;
регрессия `1229Z` подтверждает сохранение paint/native ink. Фазы cold programs в `1229Z` содержат один полный cohort (публикация 123,204 мс).
Первый native owner начинается на 155,535 мс, navigation — 161,225 мс.
Оставшаяся задержка до 429,636 мс ещё не атрибутирована внутри WebKit.

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

- Строгие cold document/SVG/programs, Native24 и first-curl бюджеты из таблицы.
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
