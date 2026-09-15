# Приёмка документа через настоящие приложения

`create-control.js` выполняется как исходник `notebook_execute start` только на
частном MCP endpoint сопряжённого acceptance Mac. Он создаёт материал через
публичные `nb.board`, `nb.id`, `nb.transaction` и проверяет адресные чтения
`nb.document`. Исходник содержит 140 блоков, 35 SVG, 1680 формул и больше 6 МиБ
текста. Возвращённые documentID, boardID и actionIDs входят в доказательства.
Сам факт выполнения генератора не доказывает доставку или показ на iPad.

`NotebookDocumentAcceptanceUITests` запускает отдельное установленное приложение
`com.amirtlinov.notebook.acceptance`. Его окружение:

- `NOTEBOOK_ACCEPTANCE_MANIFEST` — manifest уже сопряжённой изолированной пары;
- `NOTEBOOK_ACCEPTANCE_DOCUMENT_ID` — UUID из результата реального генератора;
- `NOTEBOOK_ACCEPTANCE_DOCUMENT_TITLE` — необязательное название, по умолчанию
  `Notebook canonical control`.

Тест не заполняет базу, не подменяет ответы агента и не управляет DOM. Поиск,
открытие, ссылки, страницы, ввод и сохранение выполняются обычными UI-жестами.
Метод с десятью холодными открытиями следует выполнять до метода редактирования,
чтобы исходный контрольный документ сохранял точный состав при измерении.

Время запрашивается у `DocumentPresentationRecorder`, включённого только для
acceptance или явного профилирования. Он наблюдает существующий native owner:
запрос пользователя, получение канонического содержимого и фактическую установку
готовой текущей поверхности. Целевой период наблюдения — 5 мс; занятый
MainActor может задержать наблюдение дольше. Эта задержка не вычитается:
измеряется консервативное время от запроса до наблюдения установки, без
гарантии погрешности не более 5 мс. Код измерения не вызывает layout, snapshot, фокус или
загрузку. Отсутствие доступного native record завершает тест ошибкой, а не
подменяется наличием WebKit или снимка в кэше.

В каждом запуске приложения принятые записи имеют уникальные ID и строго
возрастающее время запроса. Повторное посещение страницы не принимает её старую
успешную запись: проверяются также доступность host для настоящего касания,
пересечение с окном и номер текущей страницы из обычного accessibility value
`page-turn-surface`. История сбрасывается только после нового `app.launch()`.
Чистый контракт `testInstallationHistoryRejectsReplayedOrOutOfOrderPageReceipts`
проверяет повтор ID, старый запрос с новым ID, равные времена и новый запуск.

Короткий диагностический метод `testColdOpeningAndDistantLinkPublishFreshNativeInstallations`
проходит первое открытие, дальнюю ссылку и возврат теми же жестами и строгими
проверками свежей установки. Он сохраняет отдельные записи и PNG; его успех
не означает прохождения p95 полного workload.

Холодные открытия повторяются в десяти новых процессах приложения/WebKit,
каждый начинается с доски. Для тёплых ссылок сначала реально открываются оба
конца, затем выполняются десять переходов туда и обратно. Порог p95:
3000 мс для холодного открытия, 300 мс для тёплого перехода. Это измерение
Simulator от принятого запроса до установки; оно не измеряет touch-to-photon,
частоту кадров, CPU/GPU или системные пропуски кадров.

`export-control.js` после UI-редактирования проверяет его маркер отдельным
публичным чтением на Mac и запускает долговечное задание экспорта. Следующий
запуск с jobID читает `nb.exportStatus`. Публикацию PDF и его визуальную
проверку фиксируют отдельно; ответ `queued` не считается завершённым экспортом.
У текущего интерфейса документа нет отдельной кнопки экспорта, поэтому этот
шаг принадлежит публичному API агента.

Сохраняются неизменный source SHA, Release build, manifest, журнал start/resume,
XCTest attachments и xcresult. Наличие этих файлов и CPU-проверки генератора
не означают, что приёмка уже выполнена.

## Системная трасса каждого процесса

При явном выборе Time Profiler driver создаёт `system_trace.TraceHandshake` до
запуска Xcode UI runner. Конструктор принимает `session_id`,
`control_directory`, `evidence_directory`, `simulator_udid`,
`expected_bundle_id`, `expected_executable_uuid` и
`segment_time_limit_seconds`. Каталоги control/evidence должны быть новыми;
родитель может существовать. `start()` получает полный документ параметров
установленного xctrace, сохраняет его и меняет Hangs threshold на100 мс.
`environment` передаётся UI runner; `finish()` требует завершённые сегменты,
`cancel()` прекращает только принадлежащую этому координатору запись.

Окружение:

- `NOTEBOOK_TRACE_SESSION_ID`: UUID сессии, UI runner и приложение;
- `NOTEBOOK_TRACE_CONTROL_DIRECTORY`: абсолютный приватный каталог обмена,
  UI runner и host coordinator. Приложение не читает этот каталог.

`NotebookSystemTraceIdentitySurface` публикует только диагностическую identity
через свой UIKit accessibility value, только для private acceptance bundle
с явным session UUID и manifest. PID берётся у текущего процесса, UUID — из
LC_UUID фактически загруженного главного Mach-O, launchID сохраняется на весь
срок жизни процесса. Surface не объявляет UI готовым и не принимает касания.

После настоящего `app.launch()` XCTest helper читает эту identity и посылает
READY для нового segment UUID. Host сверяет Simulator container, bundle,
установленный Mach-O UUID, PID executable и время создания процесса. Затем
выполняется `xctrace record --device UDID --attach PID`. До запуска регистрируется уникальное Darwin notification через публичный libnotify.
Только событие `--notify-tracing-started` от ещё живого собственного xctrace
разрешает STARTED; текст лога не является подтверждением начала записи.
XCTest повторно проверяет identity и продолжает обычные UI-жесты. Перед
`app.terminate()` helper отправляет END и ждёт CLOSED; каждый новый launch
получает собственный сегмент. Максимум16 последовательных сегментов.

Во время записи polling делает только дешёвую проверку liveness `kill(pid,0)`.
Полная identity проверяется на границах before/start/end/after. Обрыв xctrace,
тайм-аут старта, смена identity, неправильный UUID или отсутствие END дают
явный FAIL. Очередная trace не переносится на будущий процесс по старому PID.
Первичная ошибка сохраняется и при последующей ошибке остановки xctrace.
`session.json` записывает `primaryError` и отдельные `cleanupErrors`; отказ
остановки, записи подтверждения или квитанции не превращает сегмент в успешный.
FAILED не выдаёт CLOSED и не добавляет сегмент в список завершённых измерений.

Для каждого сегмента сохраняются команда, начало/конец workload, identity,
параметры, лог, `.trace` и исходный TOC. Известные имена `time-profile`,
`potential-hangs` и `hangs-threshold` подтверждены историческим реальным TOC
проекта; это не обещание схемы любого нового Simulator. Неизвестная схема
остаётся `captured_unassessed`; ошибка экспорта сохраняет evidence и завершает
жизненный цикл ошибкой. Явный известный Hangs threshold250 вместо100 запрещён.
Даже распознанный TOC не доказывает отсутствие зависаний: нужны дальнейший
экспорт actual rows, покрытие main thread и workload intervals. Счётчик
пропущенных display frames здесь вообще не выдаётся.

CPU-проверка маршрута:

```sh
python3 -m unittest discover -s Tests/NotebookDocumentAcceptance -p test_system_trace.py -v
```

14сентября:16/16 CPU tests PASS; Swift6 strict semantic для UIKit probe,
XCTest helper и документных UI сценариев PASS. CPU tests используют fake
xctrace только для проверки порядка событий и отказов, не для приёмочных
квитанций. Настоящий smoke 14 сентября в 07:35–07:36 UTC дошёл до проверенного
живого PID, но не получил `Recording started`: системный DVT Instruments
сообщил об отказе tap configuration/start. Это отрицательное доказательство,
не успешно собранная трасса. Диагностика и точная идентичность сохранены в
`.build/v6-trace-diagnosis/`; пороги и границы измерений не изменены.

15 сентября: прежнее ожидание строки `Recording started` заменено публичным
событием xctrace. Настоящий host-Mac recorder успешно завершил запись, не выдав
такую строку вообще; notification пришёл за 1,965 s при живом процессе.
18 CPU/notification contracts PASS, включая настоящий libnotify descriptor,
изоляцию имени, освобождение и запрет запуска workload по одному логу.
Это исправление START-barrier не снимает отдельный отказ Simulator tap: проба
`.build/profiler-simulator-notification-diagnostic` не получила события за20s,
запись не принята. Mac trace не выдан за Simulator CPU/GPU/frames acceptance.
