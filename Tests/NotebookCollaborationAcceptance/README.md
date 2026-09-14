# Настоящая совместная работа в Simulator

`NotebookCollaborationAcceptanceUITests` запускает только подписанный private bundle
`com.amirtlinov.notebook.acceptance` с `NOTEBOOK_ACCEPTANCE_MANIFEST`. До запуска
пара должна быть сопряжена обычным интерфейсом, Mac должен обслуживать настоящий
Codex с двумя публичными инструментами, а созданный через `nb.transaction` виджет
`acceptance-controls` должен быть доставлен и виден на текущей доске. Тест не
создаёт доверие, не читает SQLite/модель, не подставляет ответы чата или квитанции.

Публичный контрольный материал: web element `acceptance-controls`, полный state
`{count, slider, text}`. Его реальные AX controls — `Acceptance increment`,
`Acceptance slider`, `Acceptance text`; видимый output — `Acceptance count: N`.
Кнопка и поле сохраняют полный state через `notebook.commit`, удалённые изменения
отрисовываются на `notebookstate`. Board UUID определяется агентом через контекст,
не зашит в тесте. Нужен видимый свободный край доски рядом с виджетом для long hold.

Два независимых selector, до 600 секунд каждый; `notebook_acceptance.py`
назначает этим точным сценариям 660 секунд внешнего ожидания и сохраняет
выбранный `timeoutSeconds` в квитанции:

- `NotebookAcceptanceUITests/NotebookCollaborationAcceptanceUITests/testSentRegionRemainsImmutableWhileRealAgentCreatesAnInteractiveDocument`
- `NotebookAcceptanceUITests/NotebookCollaborationAcceptanceUITests/testConcurrentHumanStateRejectsStaleAgentWriteAndSurvivesItsUndo`

Первый тест выбирает область настоящим hold/drag от пустой доски, проверяет
счётчик контекста и отправляет естественную просьбу Codex. После Send человек
нажимает исходный counter. Агент должен открыть отправленные пиксели, прочитать
старое значение, дождаться нового живого state и повторно получить тот же SHA
внимания; затем создать документ с интерактивным блоком. UI ищет этот документ,
открывает его и проверяет изменение 0 → 1 первым настоящим нажатием.

Во втором тесте агент сначала принимает изменение text того же виджета и
сохраняет post-commit `saved.receipt.revisions` и `saved.receipt.id` из ответа той
же транзакции. Повторное чтение после появления маркера запрещено как источник
expected: оно уже могло бы прочитать человеческую правку. Синхронизация — фактически видимый `Agent ready …`
в настоящем поле вместе с кнопкой Stop текущего Codex turn. Commentary внутри
скрытого disclosure и эхо исходного запроса не считаются готовностью. Затем UI
меняет count и заменяет text через настоящие tap → клавиатуру → Cmd+A → ввод;
агент делает запись с прежней expected version, получает
`revision_conflict` и отменяет только свой первоначальный action. UI проверяет,
что оба человеческих значения сохранились. Самотест не исправляет неожиданно
принятую устаревшую запись и не отменяет пользовательские действия.
`nb.undo` изменяет квитанцию исходного действия: `undoReceiptID == effectActionID`.
Отдельный actionID отмены не придумывается; сохраняются реальные
`publication.saved`, `receipt.undo.completedAt` (исходное число Apple reference date),
`restored` и `preservedCount`.

Каждый прогон создаёт новый чат и nonce. Тест сначала читает ID текущего
разговора и задач в настоящем каталоге, затем однократно нажимает «Новый чат».
Квитанция создания должна открыть разговор с новым UUID; тест проверяет его
реальную AX-идентичность и пустой transcript. Пустой чат может ещё не входить
в историю Codex, поэтому возвращение в каталог не является шагом создания.
Наличие прежнего transcript не подтверждает создание.
Перед Send тест заменяет через клавиатуру только узнаваемый оставшийся черновик
приёмки и проверяет точное равенство введённого запроса. Неизвестный черновик
останавливает сценарий до его замены. Найденное по названию создание документа
открывается обычным двойным нажатием на адресованную обложку.
Плоский JSON в реальном ответе содержит
полученные context/reference/action/document/program IDs, SHA, версии, error code,
результат undo и настоящие `notebook_execute` run IDs изображения/создания/эффекта/
непринятой CAS записи/undo. Агент выводит через `emit` неизменяемую post-commit
квитанцию до ожидания пользователя, фактическую CAS ошибку и результат undo.
Наличие JSON **не доказывает сохранение или показ**. Он сохраняется
как `agent-reported-…-public-addresses-unverified`; отдельные attachments содержат
фактические UI значения и скриншоты до/после переходов. При отсутствии ответа,
attention pixels или control тест остаётся FAIL, готовый ответ не подставляется.

После UI прогона независимая проверка через те же публичные инструменты обязана:

1. Повторно прочитать `nb.attention({contextID,referenceID})`, открыть его artifact
   через `emitImage`, сверить `expectedSHA256` и старые пиксели с кадром до Send.
2. Через `notebook_execute` с `op: "resume"` прочитать реальные output/effects всех
   названных run IDs, сверить сохранённую до ожидания post-commit `expectedA` с
   expected отказанной CAS записи; исходный запрос не запускать повторно.
   Прочитать реальные действия и все необходимые страницы `nb.action`, убедиться
   в принятых операциях, исходной CAS ошибке из run output и результате undo.
   Совпадение слов агента с ожидаемыми строками недостаточно.
3. Прочитать созданный документ и состояние его `programID`: на первом нажатии
   сохранено 1. Прочитать исходный `acceptance-controls` и сверить пользовательские
   count/text с UI attachments после undo.
4. Отдельно сверить сохранение, доставку и actual shown версии через публичные
   publication/presentation receipts. Прочитанный cache image не заменяет показ.
5. Сохранить commit/source SHA, build manifest, xcresult, видео и реальные tool
   run IDs с этими адресами; ошибки и непроверенные этапы не превращать в PASS.

Необязательная системная трасса использует существующий
`NotebookSystemTraceHandshake`: отдельная identity/segment для настоящего launch,
READY → Recording started → жесты → END. Это не измерение FPS посредством видео
или CADisplayLink. Исполнение этих двух новых UI сценариев пока не подтверждено;
их компиляция также не считается сквозной приёмкой.

Семантику Swift 6 проверяет `python3 Tests/NotebookCollaborationAcceptance/typecheck.py`.
Скрипт не занимает Simulator runner и сохраняет точную команду, compiler version,
SHA обоих Swift sources до/после и отдельную квитанцию `uiExecuted:false`.

Ожидание человеческого жеста ограничено в prompt: один JavaScript run не дольше
30 секунд. Продолжение следующего run переносит уже выведенные post-commit
expected/state; оно не повторяет первый эффект и не подменяет expected свежим
чтением. Отклонение по времени или реальная ошибка инструмента остаются частью
наблюдаемого результата. Тест не отключает ограничения QuickJS.
