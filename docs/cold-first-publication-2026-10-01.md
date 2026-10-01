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
