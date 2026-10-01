# Текущее состояние проверки Notebook

Срез: **1 октября 2026**. Функциональная проверка, доставка и полная приёмка
учитываются отдельно; результат относится к исходникам своего receipt.

## Начальный допуск программ и холодный индекс — 239

**0.3.169 (239)** установлена поверх238 на Mac и физическом iPad
1 октября19:41 МСК; signed source `f454748d…`. **7 continuity checks PASS**:
пространство, доверенное устройство, страница, камера, выбор и связь сохранены;
оба IPC канала обслуживает один exact signed239 owner. QA/native-test не создаются
этой доставкой; изолированный native-test после проверки удалён.
[Доставка](audit-evidence/2026-10-01/web-startup-239/delivery.json).

Устранены два самоожидания начального состояния за кредитом будущих commit:
standalone получает initial packet до transfer, документ кодирует все обязательные
пакеты до регистрации/кредита. Фон до навигации завершает ожидание; foreground
начинает принятый исходник заново. Оба ожидания closing защищены token/web.
Первый scene-index worker отправляется в accepted turn; local edits объединяются,
остановка ждёт worker, поздний результат сохраняет новый готовый cut.
[Причины и границы](cold-first-publication-2026-10-01.md).

Final source: **5 physical-iPad +2 Mac PASS**, fail/skip/runtime warnings0.
Отдельные fresh-host cold1/cold24 PASS: request→index worker0,09/0,28мс вместо
66,55/61,27мс; первая native установка программ335,36/368,62мс, все24 —1077,27мс.
Это установка, не OS показ; общая скорость не объявлена статистически улучшенной.
Navigation request→UI policy125,01/184,30мс и worker→Main19,14/34,75мс остаются
наблюдаемыми границами. Plain-parent curl контроль отрицателен4/4, удалён;
первый zero receipt и strict16,667мс открыты. Full acceptance GUI-190 отдельно.
[Scopes и результаты](audit-evidence/2026-10-01/web-startup-239/results.json).

## Открытие и чёткость Codex — GUI-388 / 238

Пользователь сообщил: тетрадь не открывается, обложки и рукопись размыты при
увеличении и после остановки. Pointer capture направлял двойной клик в canvas;
теперь цель определяется под указателем. Проекция сохраняет плотность экрана,
обложки готовятся локальными участками, рукопись — из нативной геометрии в
запрошенном разрешении. Общий painter, хранилище и raster pool сохранены.

Source `77052d05…`: **5 Mac + 2 physical-iPad + MCP 170 PASS** по указанным
в receipt срезам; Core отдельно — **1 определение / 2 случая PASS**. Финальный
Mac-повтор исправил сравнение пикселей в двух новых тестах: нативная физическая
сетка уточняет плотность вверх, поэтому эталон использует точную сетку участка.
Исходники продукта одинаковы во всех этих нативных проверках. Проверены реальные
края штриха, открытие первой страницы, navigation/presence, бюджет и reuse при pan.
[Точные scopes и результаты](audit-evidence/2026-10-01/codex-sharpness/results.json).

**0.3.168 (238) + plugin 0.1.5 установлены 1 октября в 18:53 МСК.**
7 installation continuity checks PASS: сохранены пространство, доверенный iPad,
страница, камера и выбор; соединение активно, Mac owner один. SDK с точным
установленным HTML проверил на настоящих «заметках» двойной клик в Hand,
первую/следующую страницу, Back с прежней камерой и повторное открытие Enter.
Рукопись визуально чёткая при 184% / DPR1 и 220% / DPR2; idle возвращает unchanged.
После жестов 6 continuity checks PASS; native страница/камера/выбор сохранены.

**1 октября 19:49 МСК: обновлённая панель проверена непосредственно в Codex**
на установленной 239. Script SHA `96322386…` совпал с 0.1.5. Настоящие «заметки»
открылись, Next/Previous прошли, три быстрых нажатия zoom110→190% оставили
рукопись чёткой после подготовки изображения. После действий 6 continuity PASS.
Контроллер этой панели поддерживает synthetic clicks; native double-click
проверен ранее в SDK с тем же frontend. Старое подключение из проверки238
и неответивший app-server proxy сохранены в историческом receipt.
Перенос окна между экранами ещё не принят: одна смена DPR через CDP без жеста
не запросила новую плотность.
GUI-388 остаётся In Progress; полная performance acceptance открыта.

### Предыдущие срезы

237 / plugin 0.1.4 установлены 1 октября в 14:07 МСК. Проверены отдельные тела
карточек, камера, native tile reuse и отсутствие durable camera jobs:
3 Mac + 2 physical-iPad + MCP 168 PASS; Core 9 определений / 12 случаев PASS.
После final frontend delta — typecheck + MCP 168 PASS. SDK на реальной доске
проверил pan/zoom/Back/fit; 7 installation и 6 post-gesture continuity checks PASS.
Пользователь затем обнаружил дефекты открытия и чёткости, перечисленные выше.
[Исторический scope и receipts](audit-evidence/2026-10-01/codex-board/results.json).

236 / plugin 0.1.3 устранили конечный фон и возврат камеры при смене raster origin.
2 Mac + 1 physical-iPad PASS; final frontend — typecheck + MCP 168 PASS.
Установка в 10:56 МСК, 7 continuity checks PASS; SDK проверил real-board camera.
Эти проверки не установили готовность всей доски.
[Исторический scope и receipts](audit-evidence/2026-10-01/codex-camera/results.json).

## Владение готовностью и восстановлением — 235

**0.3.165 (235)** установлена поверх234 на Mac и физическом iPad
1 октября09:56 МСК. Main `13a495b6`, pushed; signed source `aac20f2c…`.
Оба IPC endpoints обслуживает PID92197 с in-memory CDHash подписанной235,
проверенным до и после iPad update. **7 continuity checks PASS**: workspace,
trusted device, страница/камера/selected item, typed selection и соединение
сохранены; один Mac owner. На iPad одна Notebook Lab235, QA/native-test отсутствуют.
In-place update сохраняет содержимое, ключи и identities; iOS изменил путь
контейнера. [Доставка](audit-evidence/2026-10-01/cold-owner-235/delivery.json).

Исправлены повторные readiness обходы страницы/состава, лишние Main tasks для
чужого source, пропущенное освобождение raster admission и поздние positive
receipts прежнего consumer. Требования принадлежат принятой странице;
source callback обновляет один slot. Настоящий cut заново проверяет установленное
представление до/после ожидания. Прежние full readiness query, постоянный WebKit
observer и waitingForAdmission удалены. [Причины](cold-first-publication-2026-10-01.md).

Физический первичный scope:13PASS/2FAIL из15, MCP168PASS. Две ошибки относились
к требованиям fixture: пустой global allocator и удалённый automatic zoom capture.
После их исправления **2 physical-iPad +3 Mac PASS**, fail/skip0, final inventory
`aac20f2c…`; код продукта одинаковый в обоих прогонах. Проверены100000 logical
source receipts, fresh cut при потере sibling, replacement/retirement, stationary
recovery, cold24, stored-leaf turn/reverse/eviction/cancel/first ink и Mac compositor.
Не запускались повторно13 уже успешных сценариев и неизменившийся MCP.
Receipts: `/private/tmp/notebook-cold-235-{final,recovery}-verify`.

Source clocks: curl action→actualOS24,140мс; sequence0 time0 приходит до первого
CA commit, Main delivery0,377мс. WebKit request→policy220,328мс; first/all24 native
installation454,150/1153,228мс. Эти наблюдения локализуют ожидания, strict latency
и полную приёмку не закрывают. Logging-only60s: actual start ACK и cold24PASS, затем finalization остановлена
по deadline95s. Local export не имеет finalized document template; usable OS
tables отсутствуют. Capture не повторялся. [Scope/source/results](audit-evidence/2026-10-01/cold-owner-235/results.json).

## Notebook plugin — canonical appearance 234

После отклонения панели0.1.1 заменён generic SVG painter: native compositor
передаёт бумагу, рукопись, authored content и обложки834×1194. Открытие следует
admitted page/board/camera; дальше камера панели независима. Редактируемые тела
отделяются до жеста, текстовая ширина сохраняет authored layout constraint.

Final selected source839a6636…: **MCP168 PASS + typecheck; Mac2 PASS**, runtime
warnings0. Core отдельно: **5 функций/8 случаев PASS**. Physical iPad: **1 PASS**
ordered page compositor; native implementation не менялась после этого прохода
(delta: Mac test assertion и2 frontend files). Chrome SDK fixtures проверили
composition/gestures/retry/navigation/teardown и body225 versus constraint280.
Это разные scopes; полная приёмка остаётся открытой.
[Результаты и точные source deltas](audit-evidence/2026-10-01/codex-plugin/results.json).

Signed0.3.164/234 и localplugin0.1.2 установлены. Continuity6 PASS; cached HTML
614651bytes совпал с frozen source. Live presentation отклонён доPNG: pinned socket
обслуживал in-memory233, повторно запущенный во время iPad install до atomicMac
exchange. CDHashpeer доказал отличия от signed234; validator менять не требуется.
Full-wire regression2 PASS. Ordinary restart дал новыйpeer81818 с exact signed234
in-memoryCDHash;7continuity PASS. До/после первого13layerpresentation: accessory,
visiblewindows0. Real handwritten leaf/native pages/covers через SDKbrowser PASS;
Native PNG humanmove/width/edit → agentsameID → humanundo preservingagent →
reopen PASS. Cleanup14 PASS: testboard отсутствует,7исходныхitems, deletion
receivedByIPad confirmed; полноеtypedselection/presence/workspace/trust сохранены.
Пользователь открыл панель 0.1.2 в Codex: canonical appearance видна, движение камеры
обнаружило белую полосу за границей raster. Ремонт камеры учтён отдельно;
GUI-388 продолжается.

Installer-only repair: merged `mcp get` исключает plugin servers через временный
`--disable plugins`. Actual upgrade0.1.2 и isolated global enabled/disabled PASS.
Это отдельная source delta после immutable signed234, включаемая в общую235.

Предыдущий233 подтвердил cold accessory startup без workspace/chooser, один MCP
provider, human create/move/edit → agent same-ID → human undo → reopen, показ того
же объекта на physical iPad, cleanup и сохранениеworkspace/trust/camera/selection.
Пользовательская Codex-панель0.1.1 была отклонена за generic cards220×144,
missing ink иauto-fit33%; этот результат сохранён в historical233 receipt.

## Адресная публикация и завершение переходов — 233

**0.3.163 (233)** установлена поверх231 на Mac и физическом iPad
1 октября06:52 МСК. Signed pair source `12f31745…`.
Helper/presentation ready; workspace, trusted device, страница и камера сохранены,
сессия новая. Физический native board показывает прежние обложки. Одна Notebook
Lab233; QA/native-test apps отсутствуют. Контейнеры и ключи сохранены.
[Доставка](audit-evidence/2026-10-01/cold-install-233/delivery.json).

Существующий Entry публикует только свой принятый источник и terminal retirement.
Удалены повторные parent readiness/static wakes при запуске программ, линейный
поиск basis для каждой программы, вторичная публикация workspace при чтении
без вытеснения и двойная установка curl output. Исправлен реальный hang:
новый endpoint с тем же OS timestamp теперь принимается по возрастающему sequence.
[Причины и решения](cold-first-publication-2026-10-01.md).

**15 physical-iPad +2 Mac PASS**, fail/skip0, source `548a3750…`:
cold24, source replacement/retirement,100000 spatial objects, runtime cancellation,
first curl, общий OS timestamp и stored-leaf reverse/eviction/cancel/first ink.
**2 Core PASS** на том же source: exact ID/collision/removal и100000 program basis reads.
Затем изменился только `MCP/panel/session.ts`; native inputs неизменны, inventory
comparison сохранён. Final Mac2 PASS относится к release source `12f31745…`.
[Точные scopes и source delta](audit-evidence/2026-10-01/cold-install-233/checks.json).

Strict first response остаётся красным:24,294–43,266мс при16,667мс на предшествующем
`ba505e70…`; порог сохранён. Первый cold discard, ready-time WebKit IPC,
hardware contact-to-display и полная приёмка GUI-190 ещё открыты.
Screenshot/readback не включались в app latency.

## Первый холодный кадр и доставка WebKit — адресный срез

1 октября05:54 МСК: **4 physical-iPad PASS**, fail/skip0, source `0ba84467…`.
Убран повтор root/body factory при установке/замене страницы; существующие
hosts обновляются на каждом принятом update. Проверены cold24, writable paper
до board paint и сохранение host после него, reverse/eviction/cancel/новый лист
с первым письмом, document source после принятого turn.
[Scope/source](audit-evidence/2026-10-01/cold-boundaries/page-install-result.json).

Отдельный source-matched System Trace (`a6b4f458…`,2 scenarios PASS) показывает
Main Running198,939мс из248,432мс return→policy; другие constructors занимают
29,970мс Running. CPU queue2,390мс. Сэмплы содержат SwiftUI/UIKit installation,
layout и metadata. Точное ready-time первого IPC отсутствует. Профиль изменяет
скорость; его цифры не являются обычной задержкой приложения.

Empty initial CA mount и сохранение transactional mode после первого commit
дали отрицательные физические controls; временные paths удалены. Первый surface
достиг server resource path, причина его discard всё ещё неизвестна. После
ремонта owner return→policy191,500мс в отдельном обычном run; ускорение не
установлено. First cold/strict/hardware latency и full acceptance остаются открыты.
[Причины и пределы выводов](cold-first-publication-2026-10-01.md).

Этот прогон использовал изолированный native host и не обновлял production231.
Patch вошёл в общую233; её проверка и доставка записаны выше.

## Локальная работа и установленный output — 230

**0.3.160 (230)** установлена поверх 229 на Mac и физическом iPad
1 октября 04:37 МСК. Source `2e85dc9f…`; source-matched signed pair.
Installed helper/presentation ready; trusted device/workspace, страница и камера
сохранены, сессия новая. На физическом экране прежняя рукописная страница1/5.
Одна Notebook Lab; QA/test apps отсутствуют. In-place install сохранил bundle и
app-group identity, контейнеры/ключи не очищались.
[Доставка](audit-evidence/2026-10-01/remaining-latency-230/delivery.json).

Финальный focused route: **24 physical-iPad + 2 Mac PASS**, skip/failure=0.
Проверены incremental input index100000 узлов, чистые CSSOM setters/native routing,
first-ink lift без идентичной третьей GPU подачи, constructor cost/scene lifetime,
curl CA/OS границы, regrab/cancel, UUID удаления, reverse/eviction, mixed selection,
native document paper до WebKit и перенос host. Real UI: 24 first taps/state после
turns/pinch/Home; выход из документа сведением пальцев и повторное открытие.
[Scope/source clocks](audit-evidence/2026-10-01/remaining-latency-230/final-results.json).

Подтверждён вклад повторного hide/reveal: контроль39–40мс/3discard; completed
output под installed paper даёт пять повторов20,414–23,656мс/**0discard**.
Actual notebook receiver, pool identity, resize и отмена проверены.
Первый cold output27,883мс/3discard остаётся отдельной задержкой. Strict16,667мс,
аппаратный contact-to-display и cold WebKit launch/event delivery пока открыты.
Это actual OS timestamps программного native перехода; screenshot/readback
не входят в измеренную задержку. Full acceptance GUI-190 отдельно.
[Причины и ремонт](performance-repair-2026-10-01.md).

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
