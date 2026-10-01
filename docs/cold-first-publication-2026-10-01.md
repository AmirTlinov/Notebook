# Первый холодный кадр и доставка событий WebKit

База `42ce1a01` / ремонт230. Три адресных исследования: запуск программ,
установка страницы на Main и первая публикация curl. Прогоны — на физическом
M1 iPad Pro, один runner. Статистический профиль отделён от обычного timing.

## До первого callback WebKit главный поток занят установкой UI

**Проявление.** Холодная страница с24 программами: `loadHTMLString` уже вернулся,
а `decidePolicy`, `didStart` и runtime-ready приходят позже. Обычный230:
return→policy105,673мс, policy→started36,006мс; сам load0,103мс.

**Цепочка.** `PreparedAgentElementPreparationOwner` принимает source →
`SceneWebConstructionAdmission` → `AgentWebNativeSession` / `makeWebView` → load.
Одновременно `SpatialWorkspaceView` устанавливает `IPadPageTurnController`,
его retained hosts и SwiftUI page bodies. Делегаты WebKit также исполняются на Main.

**Установлено.** В отдельном System Trace return→policy248,432мс содержит
198,939мс Running,46,297мс Blocked и2,390мс Runnable. Шесть других конструкторов
занимают43,499мс wall /29,970мс Running. Остаётся168,969мс активной работы
вне этих constructors. Сэмплы показывают SwiftUI ViewGraph/updateOutputs,
DynamicViewList, UIKit mount/safe-area и metadata. Это подтверждает значимую
работу приложения в интервале ожидания; не измеряет момент готовности IPC.
Цифры профиля нельзя сравнивать с105,673мс как ускорение/регрессию или вычитать
стоимость наблюдения. [Main states и выбранные стеки](audit-evidence/2026-10-01/cold-boundaries/main-cold-state.json).

**Исправление доказанного повтора.** `installDisplayedPage` создавал body,
делал retain→refresh, после чего `update` повторял retain→refresh. Замена owner
и document source тоже имела собственный refresh перед общим tail. Теперь
установка только монтирует canonical host; `viewDidLoad` и принятый `update`
завершают один проход. Новый host уже получил актуальный body и исключён из
refresh; существующие hosts обновляются при каждом принятом update. Если
синхронный first-cut callback пришёл внутри refresh, после него завершается
только допуск соседей. Повторных root assignments этого accepted update нет.

**Границы/риски.** Удалена конкретная лишняя работа; её доля в168,969мс отдельно
не измерена. Кэш по sequenceRevision отвергнут: closure меняется при видимости,
интерактивности, geometry и state без смены source. Завершение turn обновляет
всех retained hosts; UUID remap и source retirement сохраняются. Проверка:
cold24, mounted paper/board publication, reverse/eviction/cancel и принятие
нового document source после окончания старого turn.

## Первый curl проходит CA, но первый drawable может быть discarded

**Проявление/цепочка.** Свежий output → encode → scheduled publication →
transactional present/reveal → CA commit → OS receipt. В source-matched capture
первый present занимает6,686мс; после commit sequence0 получает discard,
sequence1 фактически показан через20,196мс от действия.

**Установлено.** Kernel Metal trace содержит backing Surface169 первого frame
и обращения backboard после discard callback. Значит материал дошёл до server
resource path. Эти обращения не являются свидетельством показа и не объясняют
сам discard. Drawable issuance ID также не равен backing pool slot.
[Точная связь source/CA/Metal](audit-evidence/2026-10-01/cold-boundaries/first-surface-window.json).

**Проверенные альтернативы.** (1) Сначала установить пустой exact output под
непрозрачной бумагой, затем опубликовать bent frame после его CA cut.
(2) Сохранить transactional mode после первого CA commit. Обе реализации
сохранили initial discard; улучшения в повторной паре не дали. GPU completion
до present тоже не гарантировал показ. Все экспериментальные flags, gates и
тестовые методы удалены; timer/flat primer/GPU wait в продукт не добавлены.
[Empty-mount control](audit-evidence/2026-10-01/cold-boundaries/initial-mount-control.json),
[transaction-mode control](audit-evidence/2026-10-01/cold-boundaries/transaction-mode-control.json).

**Остаток.** Нужна точная server display/discard lifecycle запись первого
surface, а не ещё один порядок ожиданий на Main. Strict16,667мс открыт.
Один контроль дал286,962мс с поздним началом encode; причина этой аномалии
не установлена и отдельно от обычной пары24,208/41,295мс.

## Запуск WebKit и готовность IPC пока не разделены

`WKWebView` constructor действительно синхронен и включает блокировки.
Однако новые instances `WKProcessPool` на iOS15+ не меняют выбор процесса.
Отдельный непостоянный store ограничивает reuse привязанного процесса, но
допускает unbound prewarmed WebContent; NetworkProcess может быть общим.
Поэтому constructor/store count не доказывает cold spawn для каждого объекта.
Объединение stores изменило бы изоляцию программ без доказанного выигрыша.

35-секундный capture дал пригодные CPU/kernel/CA/Metal таблицы и точный mach
clock anchor. Экспорт WebKit os-log/signpost пуст, PID↔store и ready-time policy
message отсутствуют. Recorder/import ограничения сохранены в
[capture scope](audit-evidence/2026-10-01/cold-boundaries/capture-scope.json).
Следующая адресная проверка должна дать именно ready-time сообщения и его
Main delivery, либо отдельный контроль одного cold runtime против той же
установки страницы. Из текущего профиля нельзя назначить всю паузу WebKit launch.

Изменение owner: **4 physical-iPad PASS**, fail/skip0, source `0ba84467…`.
После изменения обычный первый runtime дал constructor24,584мс,
return→policy191,500мс, policy→started23,818мс. Это отдельный run, не парный
контроль: численного ускорения удалённого повтора он не устанавливает.
Задержка события сохраняется. [Page-install result](audit-evidence/2026-10-01/cold-boundaries/page-install-result.json).
Это законченный локальный ремонт и причинная диагностика двух оставшихся
границ; полная приёмка и аппаратный contact-to-display сохраняют свой scope.


## Дополнительный ремонт в общей версии 233

Установленные страницы, программы и маски читают принятый исходник через
существующий `NotebookPagePreparationWindow.Entry`. Соседнее обновление больше
не создаёт подписку на весь `NotebookAppModel.pages`. Замена точного исходника
меняет `SourceVersion`; удаление или вытеснение отзывает Entry через `isRetired`.
Начальный loading shell сохраняет чтение модели до допуска своего Entry.
Новый store, runtime или очередь не создаются.

`AgentOverlayReadiness` немедленно принимает отдельные факты установки, а
родителю публикует новую presentation или переход агрегированной готовности.
Новая версия стирания получает отдельный receipt даже при прежнем ready.
`PageTurnMaterialOwner` не будит статическую подготовку для страницы только
с live-программами. Изменения provider/material, доступности и отмена сохранённого
кадра продолжают доходить до владельца перелистывания.

`programStateBasis` использует точный ID в существующей immutable projection.
Один полный проход на каждую программу удалён. Нормализованный lookup остальных
потребителей сохраняется; редкие коллизии имеют дополнительные точные позиции
в том же индексе, без второго полного каталога. Обновление state сохраняет
геометрию и позиции, замена состава создаёт новую projection.

Чтение страницы без вытеснения больше не запускает повторный global projection
pruning и публикацию workspace. Изменение каталога и реальное вытеснение по-прежнему
очищают right spine и membership; stale addresses удаляются при любом исходе.

`preparePages` единожды устанавливает размер output и его UI clock. Второй вызов
`prepareDrawable` из контроллера удалён. Незавершённый старый `nextDrawable`
сохраняет единственное физическое получение; после его завершения владелец
устанавливает размер принятой новой пары. Отмена отзывает pending demand.

Это удаление конкретной повторной работы. Готовность первого WebKit IPC,
системная причина первого drawable discard и численный вклад каждого удаления
в общую холодную задержку остаются отдельными вопросами из предыдущих разделов.
Сфера проверки и доставки общей233 записана в `docs/verification.md`.


### Завершение перелистывания при общей границе показа

В первом прогоне ремонта жест0→1 получил sequence1 с progress0,987948 и
sequence2 с endpoint1,0. Оба OS receipts имели presentedTime136985,94149891668.
Контроллер отвергал `time <= previousTime`, renderer требовал `time > previousTime`.
Endpoint уже был показан, но motion осталась ждать его после остановки clock;
`didTurn` не пришёл за исходную секунду. Это установленная причина зависания.

Строго возрастающий sequence определяет порядок кадров в той же operation,
generation и immutable pair. Время показа теперь отклоняет только откат;
равное время нового sequence принимается обоими владельцами. Не вводятся
таймер, повторный render или искусственный receipt. Детерминированная проверка
ordering отдельно от настоящих OS timing проверяет старое время, равную границу,
единственное завершение и освобождение пары. Полный stored-leaf journey
проверяет реальное перелистывание, reverse, eviction, отмену и первый штрих.

Отдельная проверка strict first response осталась красной: шесть первых bent
receipts24,294–43,266мс при цели16,667мс. Порог сохранён; этот результат не является
PASS приёмки скорости. Он относится к предшествующей версии исходников
`ba505e70…`, до исправления endpoint ordering. Release scope и этот открытый
latency scope записываются раздельно.

## Адресные условия готовности после 233

**Причина оставшейся работы Main.** `AgentOverlayReadiness.publish` проверял весь
состав после каждого локального receipt. `PageTurnActivity` сообщал только номер
страницы; `PageTurnMaterialOwner` повторно обходил её layers и запрашивал каждый
provider. Этот запрос проверял `SceneSourceInstallation.isInstalled`, включая
ancestor visibility и преобразование bounds. Последовательная установка N
программ давала повторные обходы растущего установленного состава. Отсечение
одинаковых parent publications в233 сохраняло эти обходы перед отсечением.
Доля этой работы в исторических168,969мс отдельно не установлена.

**Ремонт.** Overlay хранит отсутствующие условия у своей immutable presentation.
Принятие состава пересчитывает их один раз; source/material callback меняет одну
запись, публикация читает пустоту множества. Material owner хранит требования
своего принятого layer directory. Событие provider несёт elementID; обновляются
его version/availability и необходимый static slot. Новый состав, размер,
readiness binding или перестановка страницы пересоздают эти требования;
retirement освобождает их. Runtime не запускает спекулятивную полную подготовку.
Прежний `isCapturable` и его вызовы на каждом callback удалены. Перед реальным
acquire и после ожидания сохраняется свежая проверка всего заимствуемого cut:
hint готовности не заменяет установленное представление или OS показ.

**Уведомления и восстановление.** `PreparedAgentElementPreparationOwner` фильтрует
новый raster по sourceID до создания Main task. Подписка на освобождение памяти
существует только у конкретного отказавшего capture и заканчивается при restart,
замене или retirement. Прежние `waitingForAdmission` и постоянный WebKit observer
удалены: этот owner запрашивает input/liveProgram/visible, а отказ ограниченной
очереди относится только к background; принятый запрос завершает его continuation.
Точный `AgentWebSourceFailure` сохраняет baseline и state credit. После подписки
проверяется уже доступный целый запрос: отказ и освобождение могли доставиться в
обратном порядке. Active restart учитывает цену состояния, passive restart не
получает начальный credit. Это устраняет пропущенный wake и повторный запуск за
счёт ресурсов собственного завершённого executor.

**Актуальность публикации.** Отложенные positive receipts status/runtime
повторно проверяют принятый source при доставке. Между постановкой callback
и его выполнением может прийти новое содержимое при ещё смонтированном старом
слое. Старый слой подтверждает только свой источник и не завершает graphics
receipt нового consumer. Interaction callback проверяет `AgentProgramSource`:
placement/state echo сохраняет готовность того же исполнения, смена кода
отсекает callback предшественника.

**Проверка.** Существующие сценарии расширены100000 логическими source receipts,
адресными material/availability переходами и потерей sibling без callback перед
настоящим acquire. Отдельно проверяются stationary capture recovery, pending
program turn, cold24, отмена/возврат и первый штрих. Физический прогон235 дал13PASS из15. Две
проверки давления требовали пустого shared allocator и уже удалённого автоматического
снимка на zoom; исправлены их владельцы нагрузки/явного capture, **2 physical-iPad +3 Mac PASS** в адресном
повторе, fail/skip0. Изменился только PreparedAgentElementViewTests; код продукта
между прогонами одинаковый. Source deltas и доставка235 записаны в
[результатах](audit-evidence/2026-10-01/cold-owner-235/results.json).

**Оставшаяся диагностика.** Optional Metal probe разделяет source handler,
`presentedTime` и Main delivery; test сохраняет значения exact layer hierarchy
перед/после present. Форматирование выполняется после окончания сценария, стоимость
снятия значений записывается отдельно и не вычитается. WebKit cold24 не имеет
HTTP/file/package ожидания между return и policy. В upstream `afc5c2a4…`
`WebKit2Logging` передаётся дочерним процессам; release log перед
[policy IPC](https://github.com/WebKit/WebKit/blob/afc5c2a4647ccacf4755d91a618f042609142768/Source/WebKit/WebProcess/WebCoreSupport/WebFrameLoaderClient.cpp#L243)
отсутствует. Loading `WebPage::loadData` и UI policy связываются navigation/page/PID;
Network содержит ответ, Layout — layout. Пересланный через UIProcess лог получает
время получателя. Logging-only capture с обоими процессами может установить порядок
и начало WebContent load, однако sender→Main задержка требует отдельной исходной
отметки. Нулевые строки старой записи и флаги установленного iOS27 не объяснены.


**Новые source clocks235.** Первый curl action→OS24,140мс; sequence0 уже в
Metal handler имеет presentedTime0 в10,529мс, до CA commit10,776мс. Main
получает его через0,377мс. GPU завершён7,672мс; видимость, attachment, transform
и размеры десяти предков корректны в model tree. Первый успешный OS показ
совпадает с UIKit target с отклонением0,0035мс. Server discard первого drawable
и server installation layer этим не установлены. Strict16,667мс остаётся открытым.

Cold24: первая native installation454,150мс, все24 —1153,228мс; первый конструктор
24,933мс. Navigation request→UI policy220,328мс, return→policy219,868мс — основной
неразложенный интервал. Между UI opportunities встречается96,238мс с несколькими
run-loop entries/callbacks; непрерывный Main block этим не доказан. Два поздних
конструктора соседней страницы принадлежат существующим transient visible workers,
не дополнительным persistent runtimes. Их вклад не измерен. Диагностика находится
в `/private/tmp/notebook-cold-235-final-{cold,curl}-receipts/`; её PASS означает
получение наблюдения, не приёмку скорости.


Logging-only capture после ремонта: реальный start ACK, cold24PASS, source и
binary неизменны; native-test удалён. 60s recording затем не завершил finalization
за общий95s deadline. Export сообщает `Document Missing Template Error`;
доступных OS tables нет. Это не подтверждает отсутствие WebKit logs. Повтор
не запускался, обычные source clocks выше остаются отдельным результатом.


## Кредит будущих записей блокировал ещё не начавшийся запуск

Установлены два самоожидания при нехватке памяти. Обычная задержка между
`navigation_requested` и UI policy из предыдущего раздела имеет другую границу.

В `AgentWebCoordinator.beginLoad` transfer резервировал до 1 MiB оставшейся
пассивной ёмкости до кодирования начального состояния. Если свободный остаток
был меньше окна кредита, пакет ждал bytes, удерживаемые его же будущими commit.
Навигация ещё не началась и не могла освободить этот кредит. Transfer теперь
создаётся в `installProgramNavigation`, после допуска точного начального пакета.
Отмена до навигации завершает ожидание; возврат начинает принятый исходник заново.

`DocumentWebCoordinator.registerPrograms` выдавал такой же кредит первой
программе до кодирования второй. Общий `presentPage` ждал все URL; первый iframe
ждал установки общего кадра. Теперь функция сначала кодирует обязательные
начальные пакеты, проверяя документ и tokens после ожиданий, затем регистрирует
URL и выдаёт кредит. Временные пакеты принадлежат этой операции; отмена их
освобождает. Успешная регистрация передаёт их существующему `programInitialStates`.
Новый allocator, runtime или очередь не вводятся.

Нулевой initial credit отклонял бы первый синхронный `notebook.commit`; автор
должен был бы повторять его после `notebookcapacity`. Ремонт сохраняет полезный
первый кредит и убирает его конкуренцию с обязательным запуском. Если сама сумма
начальных пакетов не помещается, остаётся ожидание реального внешнего ресурса.

Проверяются настоящий WK-запуск под давлением, освобождение внешней reservation,
commit до authored ready, фон до навигации и документ с двумя программами и
настоящей durable записью. Численный вклад в обычный холодный кадр определяется
отдельными cold1/cold24 source clocks. Проверки: **5 physical-iPad +2 Mac PASS**, fail/skip/runtime warnings0;
доставка записывается отдельно в `docs/verification.md`.


### Начальный индекс ждал допуска задачи на Main

Source clocks двух свежих test-host процессов показали request→worker66,55/61,27мс
при самом построении0,25/0,26мс. `scheduleScenePreparation` отправлял detached
worker из отложенного Main driver после `Task.yield`. Первый immutable cut теперь
отправляется непосредственно при принятии исходника; driver принимает его
результат. При существующем индексе синхронные workspace/hierarchy изменения
объединяются до снимка. Одновременно работает один builder; остановка ждёт
уже отправленную работу. Новый готовый SQL cut не заменяется старым результатом;
input, coverage, portal и generation ограничения публикации сохранены.

После ремонта request→worker0,09/0,28мс. Worker→Main19,14/34,75мс остаётся отдельной
границей. Первый программный слой установлен335,36/368,62мс, все24 —1077,27мс;
это installation receipts, не OS показ. Navigation request→UI policy125,01/184,30мс
сохраняется. Прогоны отдельно фиксируют механизм отправки; статистического
ускорения всего приложения и strict latency они не устанавливают.

Plain-UIView parent контроль сохраняет первый zero handler во всех четырёх
операциях с проверенной геометрией; гипотеза вложенного Metal parent не подтверждена.
Одноразовая реализация контроля удалена, product curl не меняется.
[Точные scopes и результаты](audit-evidence/2026-10-01/web-startup-239/results.json).

## Актуальный запрос и принятый материал — 240

**Холодная страница ждала ещё одного обновления SwiftUI.** `SpatialWorkspaceView`
строил `WorkspaceSceneFrame` в body и захватывал его в отложенной подготовке.
В fresh-host239 индекс уже опубликован к первому исполнению, но closure несёт
старый nil: cold1 — publication98,187 → accepted99,526 → page136,582мс;
cold24 —90,159 →91,585 →116,049мс. Следующий запрос исправлял устаревший снимок.
`NotebookWorkspaceCompositionRequest.prepare` теперь разрешает текущий индекс
при исполнении принятого пространственного намерения. Точный ID операции
отбрасывает отменённый запрос; pins и portal override принадлежат тому же
намерению. Построение frame в каждом body и старый helper удалены. Проверка:
первая принятая возможность с индексом готовит страницу в том же Main/UI проходе;
отдельно — объединение запросов, смена модели и прерывание новым жестом.

**Повтор перелистывания повторно снимал уже принятую страницу.** Если второй
участник пары терял готовность после начала capture, `IPadPageTurnController`
снова запрашивал первый WebKit snapshot и композицию, хотя `Operation.frames`
уже удерживал его immutable texture. Теперь операция отдаёт свой принятый cut
по точному host/UUID/owner; конец операции освобождает его. Допуск пары учитывает
этот cut независимо от нового живого слоя. Готовность живого landing остаётся
отдельным условием завершения. Проверка: временно недоступная вторая страница,
изменение первой после её принятия, повтор, отмена и свежая следующая операция.
Изменение поздней живой версии намеренно не меняет уже принятый кадр жеста.

**Программа могла сначала запуститься с устаревшим состоянием агента.**
`AgentWebCoordinator` принимал новое состояние во время ожидания initial packet,
но задача продолжала кодировать прежнее. После запуска требовались повторное
кодирование и доставка нового состояния. До навигации тот же владелец теперь
отменяет и дожидается предыдущей подготовки, затем запускает последний cut.
Новый token защищает от позднего результата; snapshot/commit роль сохраняется.
После навигации действует прежнее обновление работающей программы. Проверка:
две замены под реальным resource pressure, единственная навигация, authored boot
и commit последнего значения, освобождение ожиданий и reservations при закрытии.

Уменьшать стартовый кредит unfocused программ без изменения входного контракта
нельзя: первый доверенный DOM event включает commit до доставки native focus.
Нулевой кредит потерял бы синхронную запись этого события. Существующий кредит
сохранён. Причины OS discard первого curl и WebKit sender-ready/IPC остаются
отдельными открытыми границами; эти изменения их не объявляют исправленными.


Final source `bbcbe805…`: 8 physical-iPad + 2 Mac и MCP175 PASS; ошибок,
пропусков и native runtime warnings нет. Две первоначальные ошибки Mac относились
к тестовым допущениям о размере региона и ленивой геометрии; код продукта между
прогонами одинаков. Пиксельные пороги сохранены, повтор региона не накапливает
память, конец cut освобождает все reservations.

В отдельных fresh-host cold1/cold24 принятая подготовка→страница занимает
0,305/0,283мс в том же UI cycle/runloop pass вместо37,056/24,464мс с ещё одним
проходом239. Потерь событий нет. Первые native installations330,515/436,173мс,
все24 —1057,570мс; в239 соответственно335,360/368,622/1077,271мс. Общая скорость
по этой паре прогонов не улучшилась однозначно. Соответствующие одному source
WebKit request→policy126,369/177,730мс остаются открытой границей.
[Scope, исходный FAIL и результаты](audit-evidence/2026-10-01/cold-owner-240/results.json).

0.3.170 (240) установлена поверх239 на Mac и физическом iPad 2 октября00:06 МСК;
7 continuity checks PASS. [Доставка](audit-evidence/2026-10-01/cold-owner-240/delivery.json).
