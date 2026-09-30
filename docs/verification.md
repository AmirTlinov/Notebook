# Текущее состояние проверки Notebook

Срез: **30 сентября 2026**. Функциональная проверка, доставка и полная приёмка
учитываются отдельно; результат относится к исходникам своего receipt.

## Независимая бумага и публикация движения — 229

**0.3.159 (229)** установлена поверх 228 на Mac и физическом iPad
30 сентября 20:26 МСК. Source `f228f92a…`. Installed helper/presentation ready;
прежние trusted device/workspace, новая сессия. Presence страницы и камеры
совпадает с 228. На реальном экране видна сохранённая рукописная страница 1/5.
Одна Notebook Lab; QA/test apps отсутствуют. Mac перед обменом был завершён;
in-place update сохранил bundle/app-group identity и данные.
[Доставка](audit-evidence/2026-09-30/presentation-229/delivery.json).

Физический1710: **16PASS**, Mac: **2PASS**, skip/failure=0 на одном source.
Native PDF устанавливается до WK admission; перенос host, ранний отказ браузера,
закрытие очереди и канонический ввод/ссылка после admission проверены. Один source
producer. Ошибка TeX сохраняет last-good print и прежний здоровый WebKit.
Curl: regrab, отмена публикации, live landing, смена UUID цели, eviction/reverse,
быстрые чередующиеся swipes и первый bent frame. Real UI: все24 first taps и
состояния после turns/pinch/Home→activate; document pinch закрывает и открывает
тот же лист с тем же значением программы.

Ordinary held publication опережает CA на **0,016 мс** в лёгкой сцене и имеет
actual OS receipt. Исправление устраняет ненужную фазовую зависимость; этот замер
не объясняет крупные прежние задержки. First-curl observation: GPU4,531мс,
OS42,725мс,3discard, landing336,571мс. Это программный native show в тестовом окне,
не hardware contact-to-display. Strict first-OS budgets, системная причина
первых discard и inline cold24 launch/IPC остаются открытыми. Единичный native
terminal timeout228 не повторился; его причина пока не установлена.
Полная приёмка отдельно. [Scope и raw timing](audit-evidence/2026-09-30/presentation-229/results.json).

## Владение запросом кадра и завершением работы — 228

**0.3.158 (228)** установлена поверх 227 на Mac и физическом iPad
30 сентября 15:00 UTC (18:00 МСК). Source `957d4b62…`. Helper/presentation ready;
прежние trusted device/workspace, новая сессия. На реальном экране видна сохранённая
рукописная страница. Одна Notebook Lab; QA/test apps отсутствуют. Mac завершён
штатно, bundle/app-group identity сохранена при новом iOS container path.
[Доставка и видимый экран](audit-evidence/2026-09-30/owned-demand-228/delivery.json).

Физический1440: **14PASS/3FAIL**, source `507c4e0a…`. Пройдены неподвижный
контакт без повторных GPU-проходов и следующий sample, пять snapshot lifetime
regressions, два bootstrap regressions и scheduling observations. Snapshot
cancel/deadline завершает reader; физический запрос и его ресурсы живут до
native callback, outstanding backlog ограничен4.

Физический1450: **3PASS**, source `957d4b62…`: native forward/reverse/eviction/
cancellation, diagnostic control и UI24. Явная точка активации бумаги устранила
pinch, который XCTest доставлял внутрь program6; все24 first taps и состояния
после close/reopen/turns/Home→activate проверены с прежними assertions.
Единичный1440 native terminal timeout1с на повторе не возник; причина не установлена.
Mac1313: **2functional PASS** на `507c4e0a…`, затронутые Mac owners сохранены.

View/scene UIUpdateLink getters возвращаютfalse даже после повторного задания
immediate policy во включённом link; все12 UI opportunities также сообщаютfalse.
Scheduling observation: dot OS22,275мс, curl OS39,493мс с двумя discard; strict
curl gate16,667мс остаётся FAIL (20,223мс в motion test). Это разные measurements.
First OS budgets и полная приёмка остаются открытыми.
[Точные исходники, scopes и diagnostic getters](audit-evidence/2026-09-30/owned-demand-228/results.json).

## Причинное ревью и предшествующие срезы

[Ревью](performance-review-2026-09-30.md) на `e4948f8e`/source224 установило
полные локальные проходы, cross-owner ожидания и ошибки readiness/identity.
[Ремонт](performance-repair-2026-09-30.md) описывает текущих владельцев и удалённые
пути. Plan/dependencies и фактический статус остаются в Linear, GUI-306.

| Срез | Проверенная область | Свидетельство |
|---|---|---|
| 224 | Pair/source admission, ранний native source, shared constructor budget; installed pair сохраняет доверенную связь | [Доставка224](audit-evidence/2026-09-29/first-presentation-224/delivery.json) |
| 225 | D01–D16: локальные reads/ink/selection/state, addressed peer writes, native PDF, cancellation/resource lifetime; corrected UI24 | [Точные scopes225](https://github.com/AmirTlinov/Notebook/blob/c5d4c664597a8e7efd65f4f06f6bcb3e5da4cc3e/docs/verification.md) |
| 226 | GPU compiler вне Main, constructor allowance, source/basis checkpoint; 22native PASS и исправленный UI24, 4Mac PASS в своих receipts | [Results226](audit-evidence/2026-09-30/first-presentation-scheduling/results.json) |
| 227 | Finished-only scene reservations и optional shell; 3native + scheduling + real UI24, 2Mac PASS | [Results227](audit-evidence/2026-09-30/first-presentation-scheduling/scene-lifetime-227-results.json) |

История224–228, исходники каждого прогона, отрицательные результаты и доставка
сохранены в [неизменной ревизии c5d4c664](https://github.com/AmirTlinov/Notebook/blob/c5d4c664597a8e7efd65f4f06f6bcb3e5da4cc3e/docs/verification.md)
и адресных audit-evidence. Эти scopes не образуют текущую полную приёмку.

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
