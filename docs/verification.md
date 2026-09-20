# Verification record

## 20 сентября — GUI-289: отношения в повторном отображении и экспорте (часть S4)

Окончательная выбранная проверка `.build/gui289-settled-v4/verification.json`,
SHA-256 `5b38d55e3adcea687cd27b3007c4766f0bd458a3cd31bc29333c2b944c4b9924`:
**физический iPad 46/46, Mac 13/13**, без пропусков и runtime-предупреждений.
Подготовка страницы, доски/обложки и экспорт теперь используют `InkSampleRelations`
и существующую компактную геометрию напрямую. Прежняя пересборка принятых измерений
в массивы `PKStrokePoint` удалена из приложения; несокращённый эталон остаётся
только в тестах. Нового рендерера, владельца кэша или долговечного формата нет.
Мировые плиточные адреса не меняются; origin/crop/масштаб применяются при выводе.

Проверены live → settled → reload, очередь принятого ввода/undo, painter order
пера/ластика, крупные и дальние мировые координаты, отбор GPU-участков, передача
готовой поверхности, региональный экспорт, края плиток и текущие временные
бюджеты. Новый рабочий PageInkMesh выдаёт **64 узла вместо 4096** на доказуемо
прямом штрихе; холодное распознавание всё ещё читает все исходные события.
Соседние отсчёты после Float-проекции могут совпасть: их сокращение теперь
ограничено порогом общего нормализатора и консервативной погрешностью проекции.
Регрессии покрывают очень мелкий шаг, масштаб 0,02 и большие смещения.

Переход через PencilKit ранее квантовал alpha (`0,5 → 0,4999771`,
`1 → 0,99998474`). Новый путь оставляет принятое значение точным. Поля исходника
сравниваются побитно, геометрия проверена отдельно от прежнего квантования alpha;
допуск отображения 1/4096 не менялся. GPU-картинка прямого штриха осмотрена.
Повторный стенд полного маленького прохода даёт **2,08× iPad / 2,09× Mac**;
нерегулярный/измеренный p50 +2,39–7,88%. Это не скорость живого ввода или FPS.
Сырые времена и сводка: `docs/evidence/gui289-settled/`.

Промежуточные v1/v2 не прошли новые побитные сравнения GPU-alpha с квантующим
PencilKit-эталоном; точность содержания не ослаблялась. В более широком v3
прошли все 46 iPad и 13 Mac проверок чернил, но два сценария публикации WebKit
(`testTargetPageCompositeKeepsCameraAndReportsRuntimeDiagnostics`,
`testTargetPageLargerThanTheRasterCachePublishesOneOrderedResult`) вернули
`snapshot_pending`. Они не исправлены и не объявлены принятыми; v4 явно ограничен
чернилами и их композицией, не полной приёмкой WebKit.

Это **не завершение S4 и не выпуск**. Активный контакт и источник выбора ещё
требуют подключения; установленная рабочая пара остаётся **136**. Полная память,
аппаратный Pencil, причинное сохранение отношений и программа S5–S9 открыты.


## 20 сентября — GUI-288: локальные сокращения и явная стоимость каскада (не выпуск)

SHA-256 `eef74de0210e1044e7dded347ec1e27c49749b669b3e029ec48d182e865be78f`,
`.build/gui288-v5/verification.json`: **iPad 17/17, Mac 17/17**, без пропусков и
предупреждений выполнения. Проверены применимые области R1–R8, отрицательные
условия, точная последовательность после правок/undo, конечность сокращений,
границы изменения и реальное GPU-изображение. Правка середины замкнутого пути
обновляет геометрию даже при прежнем выходе. Бюджет сокращений не обрывает
обязательную зависимость: оставшаяся работа помечается явно, неподдерживаемый
точный перенос отвергается до публикации результата.

100 локальных правок миллионного повтора после пяти прогревов, Debug:
**iPad p50/p95/p99 0,235 / 0,249 / 0,253 мс**, **Mac 0,145 / 0,157 / 0,174 мс**.
Каждая посещает 5 узлов индекса и проверяет 100 событий тела, а не миллион;
затронуты 3 соседних события. Это стоимость правки источника, не кадра приложения.
Отрицательный контроль с несовместимыми общими двоичными масштабами требует
обработать все 100 000 событий: **194,700 мс iPad / 123,987 мс Mac**, один замер;
обход 1544 узлов, незавершённое необязательное сокращение явно отмечено.

Повторный полный проход «новый источник + сетка + GPU-растр», 100 чередующихся
повторов: прямой штрих **17,037 → 8,146 мс iPad (2,09×)** и
**11,291 → 5,371 мс Mac (2,10×)**. Нерегулярный/измеренный корпус замедляется
на 2,38–9,82%, в заранее принятом временном бюджете. Сырые времена, холодная
подготовка, p50/p95/p99 и область снимков памяти: `docs/evidence/gui288/`.
Полная пиковая память совместного живого владельца ещё не принята.

Промежуточный v4 выявил рост глубины индекса при распределении общих оснований.
Исправлена идентичность области основания при точной композиции, а не ослаблен
порог глубины; повторная проверка 250 правок и сложных несоставимых оснований
прошла. Установленная пара остаётся **136**: S3 работает в отдельных нативных
тестовых приложениях, не в пользовательском вводе. S4–S9, аппаратный Pencil,
причинное сохранение отношений, системные измерения и длительная приёмка открыты.


## 20 сентября — GUI-287: адресный повтор и неизменяемый индекс (не выпуск)

SHA-256 `810bf9a83e1cc6fddde6ca214f57881bb488f4556c71e96f7e3aeccab7c5ab37`,
`.build/gui287-v5/verification.json`: **iPad 10/10, Mac 10/10**, без пропусков.
Плоский список блоков заменён неизменяемым сбалансированным индексом того же
источника. Тело повтора разделяется между вхождениями; jump ограничен точным
переносом координат/времени. Правка измерения и изменение выхода тела разделены:
последнее сдвигает суффикс только после проверки точного домена. Ноль событий
не уничтожает ненулевой переход. Устаревшие адреса отвергаются, undo сохраняет
исходный корень. Полный экспорт идёт по дереву, а не повторяет поиск для каждого
события. Сводные границы учитывают выступающие стыки пера и округление GPU.

**Физический iPad M1, Debug; явно заданное тело из 100 событий:**

| Измерение | 100 тысяч событий | Миллион событий |
| --- | ---: | ---: |
| Создать тело и закодировать | 0,178 мс | 0,178 мс |
| Создать Repeat поверх тела | 0,00429 мс | 0,00450 мс |
| Доступ: p50 из 103 обращений | 0,000959 мс | 0,000959 мс |
| Одна адресная правка, один замер | 0,250 мс | 0,251 мс |
| Последовательный контроль переходов | 0,396 мс / 999 | 4,017 мс / 9999 |

Доступ раскрывает **1 событие** с одним jump. Запрос почти всего диапазона
посещает 3 узла и раскрывает 158 граничных событий, не весь повтор. Описание
содержит 2 физических узла, после правки — 17; оценка layout 3280 → 10120 байт,
**не** пик памяти процесса. Выбранные 41 событие из середины обоих размеров
отрисованы существующим GPU-путём и экспортированы в PNG; изображение диапазона
миллионного источника осмотрено. Это не новый пользовательский жест выбора.
Вложенность, переполнение, n=0, m=0, сдвиг суффикса, 250 последовательных правок
и границы реальной GPU-геометрии проверены отдельно.

Отрицательный контроль: полный экспорт перекрывающегося повтора из 100 000
событий всё ещё создаёт 100 000 записей / 10,4 МБ: 54,251 мс на iPad и 30,613 мс
на Mac. Универсальная сублинейность не заявлена. С учётом нового индекса полный
маленький проход S1 даёт теперь **2,07× iPad / 2,12× Mac** на прямом штрихе;
нерегулярный/измеренный корпус замедляется на 2,48–8,92%, в прежнем бюджете.
Предыдущие 2,43–2,50× относятся к источнику без этого индекса. Сырые p50/p95/p99,
холодные затраты и контроли: `docs/evidence/gui287/`.

В промежуточном v1 обнаружено нарастание глубины после серии правок: перенос
скрывал высоту поддерева. Исправлено распределение переноса при балансировке,
а не ослаблен порог теста. Проверка кода также выявила недостаточную границу
стыка; предел теперь берётся из общего владельца геометрии, с прямой регрессией.
Установленная рабочая пара по-прежнему **136**. S1/S2 не закрывают бюджет полной
памяти, подключение ввода/ластика, причинное сохранение/доставку, нормализацию всех
правил и физическую приёмку программы GUI-285; задачи остаются в работе.


## 20 сентября — GUI-286: первый точный проход отношений (не выпуск)

Один производный источник сохраняет биты восьми полей измерения, контекст пера/
ластика и адрес `(действие, ревизия, индекс)`. Точные двоично-рациональные
прогрессии сокращаются только после побитной проверки; неподходящие значения
остаются литералами. Правка сохраняет неизменяемый источник для undo; порядок
целых преобразований не переставляется. Использован существующий Metal-рендерер.

На физическом iPad и Mac пройдены **6 + 6** нативных проверок, без пропусков
(`.build/gui286-s1-v4`, source `2fbd403569bbadb6a22facd0ff4fef9bf03033e7f05d5b87596e75dba9391fa4`).
Проверены закрытый путь против пустого, различная середина при одинаковом конце,
ограничение точной арифметики, stale address, правка/undo, порядок пера/ластика,
поворот целого, GPU-изображение и PNG. Частный измеренный штрих из текущего
пространства: 413 событий со временем, нажимом и наклоном, без публикации данных.
Это сохранённый корпус, **не новый аппаратный жест Pencil**.

Финальный замер стоимости (`.build/gui286-s1-cost-v5`, source
`d49a8232f552a3c146454f256ae9d2c3af5c3ecd6399b33ec8fd670f5aa9bebb`)
удерживает источник до получения растра и снимка памяти. 100 чередующихся
повторов после пяти прогревов, Debug, новый источник + сетка + растр 640×640
каждый раз; не время кадра и не input-to-present.

| Корпус | iPad p50, прежний → отношения | Mac p50, прежний → отношения |
| --- | --- | --- |
| Прямой штрих, 4096 событий | 17,109 → 7,031 мс (2,43×) | 10,997 → 4,405 мс (2,50×) |
| Нерегулярный, 4096 событий | 113,853 → 115,304 мс (+1,27%) | 73,707 → 74,428 мс (+0,98%) |
| Измеренные позиции, 656 событий | 6,689 → 6,895 мс (+3,08%) | 4,281 → 4,470 мс (+4,41%) |

Временные бюджеты p50/p95/p99 соблюдены; прямой штрих отправляет 64 узла вместо
4096, остальные два случая — прежнее число узлов. Числа не умножаются на 58×.
Сырые времена, холодные затраты, layout источника/сетки и снимки process footprint
сохранены в `docs/evidence/gui286/`. Снимки процесса не обнаружили устойчивого
роста на нерегулярном корпусе, но **не доказывают пиковую память**: исходный массив
и производное описание в этом стенде сосуществуют. Бюджет полной памяти в живом
владельце пока не закрыт, GUI-286 остаётся в работе.

Установленная рабочая пара остаётся **136 / GUI-284**. Новый источник исполнялся
в нативном тестовом приложении на физическом iPad, но не подключён к вводу,
сохранению и доставке. Эти проверки не закрывают GUI-285 или физическую UX-приёмку.


## 20 сентября — GUI-284: векторный источник и адресное редактирование, сборка 136

Исходники `c3516cc4`, SHA-256
`1fbaeb0ac163ed2f5bb7b7280e3c411aeaa61bc55f8a5a0366111075a8609307`.
Нативные чернила и вырезы остаются векторным содержанием. Пиксельная проверка
лассо удалена; выбор использует геометрическое пересечение с учётом поздних
вырезов, прозрачности и порядка слоёв. Один индекс границ служит отображению и
редактированию. Правка положения/поворота/стиля сохраняет векторный источник и
его подготовку: больше нет полного кодирования/декодирования вершин ради одного
поля. Свободная рукопись передаёт на GPU только видимые диапазоны; ластик остаётся
компактной измеренной траекторией, не разворачивается целиком в треугольники на
каждую картинку. Сохранённые исходные измерения и wire 37 / manifest 18 не менялись.

**Окончательные проверки:** физический iPad **33/33**, Mac **12/12**, без пропусков
и предупреждений выполнения: `.build/gui284-final136b/verification.json`.
Core **30/30**, включая сохранение/повторное открытие, доставку, конкурирующие
правки и причинную отмену: `.build/gui284-core-final136.log`. Проверены местный
выбор, границы изменяющегося пространственного окна, другой мировой origin,
исключение уже преобразованных штрихов без перестроения источника, лассо через
настоящего владельца Pencil, прозрачность и вырезы, affine/crop против полного
Metal-кадра, масштаб страницы 1–8×, перенос выделенного объекта, pinch/pan и
возврат страницы, десять поворотов плиток возле лимита памяти. Снимок векторного
GPU-фрагмента осмотрен. Контакты Pencil синтетические на физическом устройстве.

**Измеренный пропуск работы, iPad Pro M1, Debug XCTest:**

- Локальное лассо: **65 кандидатов из 100 000 измерений**; затем обрабатываются
  **250 измерений выбранного целого штриха**, не вся страница. Медиана 15 повторов
  **1,504 мс**. Первая подготовка с декодированием и построением индекса отдельно
  **346,819 мс**, один холодный замер; этот расход не вычтен из первого обращения.
- Локальный запрос свободной рукописи: **706 из 60 800 исходных элементов**
  (60 000 вершин пера и 800 измерений ластика), посещены 73 узла индекса.
  Не менее **98,8% исходных элементов** не входят в диапазоны этого запроса;
  это не процент всего времени приложения.
- Метод изменения поля поворота того же объекта, 3 прогрева и 7 чередующихся
  измерений: на iPad **1612,602 → 0,06054 мс**, на Mac M5 Max
  **773,755 → 0,06008 мс**. Контроль в тестах воспроизводит прежнее полное
  кодирование/декодирование источника; новый путь читает **0 вершин источника**
  после подготовки. Это только CPU-правка поля, **не** вся транзакция записи,
  отрисовка, доставка или FPS; отношение не умножается на прежние GPU-числа.

Сырые результаты и сводки — `docs/evidence/gui284/`. Импортированные PNG остаются
изображениями: утраченные при импорте измерения не выдумываются. Холодное открытие
нового источника, преобразование выбранного целого, полное сохранение/экспорт и
плотные перекрытия не становятся O(1); прежние лимиты содержания не увеличены.
Проверка чувствительности на масштабе ниже пикселя не задаёт пиксельную границу
редактирования; численные вырожденные остатки отбрасываются по точности координат.

Промежуточные попытки `.build/gui284-*` сохранены. Исправлены ошибки компиляции
новых тестов, численный остаток полностью стёртого тонкого треугольника и
замедление векторного вычитания плотного ластика: положительный ответ теперь
сначала доказывается сохранившейся векторной точкой, отрицательный по-прежнему
требует геометрической проверки. v6 прошёл оба ранее падавших сценария; полный
выбранный маршрут после этого пройден дважды, последний — с переиспользованием
индекса при изменении списка исключённых штрихов. Добавленные после проверки
экспорты сначала нарушили опись её папки: их вынесли отдельно, исходные сводки
восстановлены **побайтно до хешей квитанции**, квитанция и результаты не менялись.

**Установка:** подписанная пара **0.3.133 (136)** установлена поверх 135 на Mac и
физический iPad, без удаления контейнеров, сброса или восстановления архивов.
Mac закрылся штатно; предупреждение об активной работе сначала остановило
установку до замены приложения, продолжение отдельно разрешил Амир.
До повторного запуска байты Mac-хранилищ, каталога пространств и активации
не изменились; реестр пространств iPad совпал. Установленные версии обоих
приложений прочитаны как 136. Живой MCP вернул `ready`: совпали basis,
заголовки пространства/страницы и ревизия содержимого доски; внешний cursor
26059 → 26069. Device-local presence не сравнивалась как общее содержание.
На экране iPad видны текущая тетрадь и прежняя рукопись, на Mac — рабочая доска
с обложками, без ошибки запуска. Квитанции `.build/gui284-build136/build.json`,
`.build/gui284-install136/installation.json`; краткая квитанция без личных
данных — `docs/evidence/gui284/installation.json`.
Аппаратный Pencil, системные FPS/энергия и 30-минутная UX-приёмка не заявлены.


## 20 сентября — GUI-282: компактный GPU-путь в приложениях, сборка 135

Исходники `9479a0f8`, SHA-256 `bc02fcc7474997c2e4b40756ca77bfc3ccac6b64503ab9c925a021640675a6c5`.
Сохранены исправления установленной пары 134 и включён GUI-283 (`fae917b0`):
плотность экранных пикселей при зуме не подменяется растягиванием старого растра.
Единый путь отображения измеренных штрихов — `CompactInk.metal`: 24-байтовый узел,
общий цвет, 43 296 байт общей связности вместо поузловых соседей/индексов,
аффинное состояние целого, экранный LOD и границы реально повреждённых плиток.
Исходные измерения, порядок слоёв, форматы сохранения и доставки не менялись.

**Проверено:** физический iPad **49/49**, Mac **15/15**, без пропусков и предупреждений
выполнения; Core **8/8**. Квитанция `.build/gui282-final135c/verification.json`.
Проверены давление/контур/концы/ластик и аффинное искажение против CPU-контроля,
возврат деталей при увеличении, перерисовка и очистка старого следа, продолжение
контакта при смене размеров, сохранность лассо, масштаб 1–8×, настоящий pinch,
перенос выделенного объекта, панорамирование и возврат страницы. Почти полный
лимит памяти выдержал десять смен ориентации. Снимок плиточной линии осмотрен.
Нативные контакты Pencil синтетические на настоящем устройстве, не аппаратная
приёмка нажима реальным пером.

Стенд настоящего shader, 100 000 узлов, **iPad Pro M1**; медианы 15 повторов после
3 прогревов, чередующийся порядок, Debug XCTest, 4× MSAA:

| Режим | GPU, мс | Отправка + ожидание GPU, мс | Полезные GPU-данные |
|---|---:|---:|---:|
| Канонические CPU-треугольники | 1,14050 | 1,73617 | 20,045 МБ |
| Точные компактные узлы | 0,67650 | 1,23938 | 2,400 МБ |
| Компактные узлы + экранный LOD | 0,20088 | 0,76108 | 0,096 МБ |

Последние две строки дополнительно используют общие 43 296 байт связности.
LOD дал **5,68× по GPU и 2,28× по отправке/ожиданию**, без LOD — **1,69× и 1,40×**.
Это конкретный синтетический рисунок, не все штрихи и не FPS интерфейса.
На Mac M5 Max при миллионе узлов: GPU 0,51600 → 0,07692 мс (**6,71×**),
отправка/ожидание 1,30883 → 0,99175 мс (**1,32×**); точный режим даёт меньший
выигрыш. Подготовка с LOD отдельно стоит 47,64 мс против 73,53 мс CPU-контроля
(одиночный холодный замер). Полный точный рисунок совпал с контролем по RGBA;
LOD RMSE по четырём каналам ≤0,0191 на плотном миллионе. Ошибка обоих краёв
ограничена 0,20 экранного пикселя, альфа — 1/4096. Сырые времена, среда и сводки:
`docs/evidence/gui282/`; воспроизведение — `Tests/Performance/CompactInk/run.sh`.

Промежуточные попытки сохранены в `.build/gui282-*`: два забытых потребителя
старого поля vertices исправлены; v4 выявил, что первое касание после частного
предъявления ещё перерисовывало все плитки — подписи теперь устанавливаются
владельцем вместе с предъявленным кадром, v6 прошёл 37/37. В final135 два старых
UI-сценария посылали палец вместо Pencil: физический input gate намеренно это
не допускает. В final135b два старых сценария ожидали перетаскивание ещё не
выделенной фигуры, хотя действующий сценарий сначала выбирает её. Код ввода и
ожидания тестов не ослаблялись: окончательный маршрут использует нативные
Pencil-контакты и проверенный текущий жест selection → drag → zoom → pan.

**Установка:** подписанная пара **0.3.132 (135)** установлена поверх 134 на Mac и
физическом iPad; обе версии прочитаны обратно. Mac завершён штатно после записи
очереди, без принудительного завершения; контейнеры не удалялись. Байты хранилищ,
пространств, реестра и активации Mac до запуска новой версии не изменились;
реестр пространств iPad сохранил прежний хеш. Живое чтение установленного
помощника после запуска: курсор 25775 → 25780, проверенные заголовки пространства
и страницы, ревизии содержания доски и чернил совпадают. Локальная видимость
устройств не сравнивалась как общее содержание: iPad вернулся к своей странице,
Mac — к своей доске. Окно точной установленной копии Mac и снимок физического
iPad осмотрены, существующие материалы отображаются. Квитанции:
`.build/gui282-build135/build.json`, `.build/gui282-install135/installation.json`;
сводка без содержимого пользователя — `docs/evidence/gui282/installation.json`.

Ограничения: прежние 58× относятся только к обновлению состояния в GUI-281 и
не умножаются на LOD/плитки. Здесь преобразуется локальный контур, а не заново
строятся стыки в мировых координатах. Произвольные независимые тензоры узлов и
новый битовый формат хранения не вводились; Float32-радиус сохраняет точность
при приближении. Ластик не упрощается. Сохранённые произвольные freehand-треугольники
в экспорте всё ещё подготавливаются на каждый raster job; страничные MTKView и
одноразовый экспорт не стали вторым retained-плиточным кэшем. Долговременная
UX-приёмка, системные FPS/CPU/память/энергия и аппаратный Pencil остаются открыты.

## 20 сентября, 01:42 МСК — GUI-281: преобразование целого

Изолированный `Tests/Performance/TensorWhole/`, Mac M5 Max: целое владеет одним
32-байтным аффинным состоянием, локальные координаты/форма не переписываются.
Общий GPU-вычислитель получает `p = A p_local + t`, `Q = A Q_local Aᵀ`.
Контроль — настоящая GPU-запись центра и Float32-Q каждого узла, не CPU-цикл.
Поддержаны группы целых штрихов, а не произвольная середина одного штриха.

Три процесса × (4 разогрева + 32 измерения), 5174 проверки PASS в каждом.
На миллионе узлов с одинаковым Float32-форматом: GPU только обновления
0,12396 → 0,00213 мс, внутрипроцессные отношения 57,677/57,766/59,393;
полное время обновления 0,27875 → 0,13444 мс. Правка с отрисовкой:
GPU 0,76090 → 0,64927 мс, весь цикл 0,93463 → 0,81808 мс, отношения полного
цикла 1,145/1,136/1,142. Готовый кадр не ускорился. Компактная локальная форма
дала сходный полный выигрыш 1,131–1,154; на небольших сценах выигрыш невелик.
Логические записи 24 МБ → 32 байта, но физический трафик памяти не измерен.

Локальные буферы и независимая группа побитно неизменны; порядок поворота и
растяжения меняет контур до 110,37 pt. Максимум ошибки контура против
поузлового контроля 0,0004402 pt, после 256 действий дрейф 0,0001857 pt.
Малый пример совпал по RGBA; на больших сценах RMSE ≤0,000275, доля отличий
>2/255 среди занятых пикселей ≤0,140%. Metal PNG осмотрены. Общие пути повторно
проверены: прямой GPU 3892 PASS, плитки 624 PASS. Хеши/сырые времена/снимки
сохранены в `Tests/Performance/TensorWhole/Results/`.

Первичная подготовка остаётся O(N); полный контур рисуется, плитки/LOD сюда
не интегрированы и их ускорения не перемножаются. Речь о формуле формы и
видимых центрах, не точном аффинном переносе старых дискретных треугольников.
Сохранение/доставка, произвольное членство, стыки внутри штриха, Pencil, ластик,
FPS, энергия и физический iPad не проверялись. Приложения и содержание не менялись.

## 20 сентября, 01:30 МСК — GUI-280: перерисовка затронутых плиток

Изолированный `Tests/Performance/TensorTiles/`, Mac M5 Max, общий прямой
битово-тензорный вычислитель GUI-279 без CPU-треугольников. Адресная правка
перерисовывает объединение старых/новых плиток с сохранением порядка прозрачных
пересечений; при превышении работы полного кадра заранее выбирает полный проход.
Производный пространственный индекс находится только в стенде, не в приложении.

Шесть процессов × (4 разогрева + 30 измерений), 624 проверки PASS в каждом.
На миллионе видимых узлов и фиксированной локальной плотности: правка 32 узлов,
4/96 плиток, 2000 исходных узлов повторной отрисовки, 18 738 вместо 6 264 000
индексов. Медианы GPU 0,6480 → 0,0423 мс; полный цикл с ожиданием GPU
0,7872 → 0,2726 мс. Внутрипроцессные отношения: GPU 13,020–17,032,
полный цикл 2,528–4,015. На 10 тысячах полный цикл немного медленнее,
на 100 тысячах выигрыш полного цикла нестабилен. Плотное наложение выбирает
полный кадр и сохраняет небольшие накладные расходы, а не радикальное ускорение.

Все проверенные RGBA совпали с полным кадром побитно; шесть увеличений/сжатий
через границы плиток не изменили внешние пиксели и удалили старый контур.
Негативные контроли обнаружили 238 пикселей при неверном порядке и 287 при
неполной очистке. PNG осмотрены. Исходный GPU-стенд после выделения общего
`Support.swift`: 3892 проверки PASS. Сырые замеры/изображения/хеши — в
`Tests/Performance/TensorTiles/Results/`.

Цена: на миллионе узлов 14 005 824 байт используемых данных CPU-индекса
(без ёмкости/аллокатора, не RSS), 25,433–30,961 мс его построения; первый полный
кадр платится отдельно. Полноразмерный MSAA target сохранён для полного прохода.
Только фиксированная камера/связность и известные адресные правки общего масштаба;
не ластик, произвольная деформация, LOD или Pencil-интеграция. Это offscreen
latency, не FPS/энергия/iPad-приёмка. Приложения и живое содержание не менялись.

## 20 сентября, 00:58 МСК — GUI-279: прямой тензорный GPU-прототип

`Tests/Performance/TensorGPU/`: Metal на Mac M5 Max, без CPU-треугольников в
прямом пути. Реализованы скалярный контроль, локальный тензор формы и одно
32-битное слово формы с вычислением тензора в shader. Адресные относительные
нажим, растяжение и поворот выполняются на GPU; проверены неизменность остальных
узлов, влияние порядка операций и ограниченная точность обратных правок.

Три окончательных процесса, каждый 4 разогрева + 30 повторов на вариант/сценарий,
3892 утверждения PASS. На 98 304 узлах: GPU-буферы 19 685 376 → 6 005 760 байт;
полная подготовка с отрисовкой 5,6383 → 2,7715 мс; парные отношения времени GPU
готового кадра 1,788/1,790/1,797. На 11 159 узлах измеренных траекторий (радиус
синтетический): подготовка 0,8488 → 0,5402 мс, но полное время 32 локальных
правок с отрисовкой практически прежнее, 0,2930 → 0,2914 мс. Скалярный прямой
контроль почти так же быстр: отдельное ускорение от тензорности не заявляется.

Максимальная ошибка битового контура 0,00561 pt; после анизотропной правки
0,02713 pt против Float32, после обратных операций 0,04338 pt против исходного.
Настоящие Metal-снимки осмотрены, полный отчёт/хеши/сырые времена в `TensorGPU/`.
Нет поиска узла при известном индексе, но чтение памяти и полная растеризация
остаются. Это offscreen GPU timing, не FPS, энергоэффективность или приёмка iPad.
Production и установленные приложения не менялись; интеграция не выполнялась.

## 20 сентября, 00:34 МСК — GUI-278: изолированный битовый радиус

В `Tests/Performance/RelationalInk/` выполнен CPU-эксперимент на Mac M5 Max:
три процесса по 2 разогрева + 10 повторов, шесть корпусов, текущий построитель
`InkStrokeGeometry` без изменения. Координаты 79 реальных траекторий содержат
11 159 узлов; радиус синтетический. На каждом процессе прошли 1 691 176
проверок формата, ошибки и сохранения геометрических атрибутов; PNG осмотрен.

Относительные 8 бит: полезные данные узлов 357 088 → 281 871 байт (−21,06%),
восстановление и треугольники 0,3919 → 0,4242 мс; с кодированием
0,3944 → 0,6252 мс. Обычные 8 бит: 279 607 байт, 0,4165/0,4985 мс и меньшая
ошибка контура (0,01216 против 0,03065 pt). Относительные 4 бита не прошли
границу 0,1 pt; 8/12 прошли. С учётом одинаковых готовых треугольников экономия
относительных 8 бит составляет лишь 2,82% payload, не RSS приложения.

Полное правило, выбранные дополнительные допущения, все времена и хеши
зафиксированы в `Tests/Performance/RelationalInk/README.md` и `Results/`.
Это кодирование радиуса с последующим обычным построением геометрии, не тензорный
GPU-рендерер. Живой нажим сейчас меняет прозрачность, а не ширину пера.
Инкрементальный ввод, FPS, энергопотребление и физический iPad не измерялись;
production, установленные приложения и содержание не менялись. Выигрыш скорости
не подтверждён; внедрение данного механизма в приложение не рекомендуется.

This record separates code checks, installed builds, live readback, and physical
acceptance. Linear owns task state. Results apply only to their named source and
environment; later changes do not inherit acceptance automatically.

## Current recorded state — September 19–20, 2026

- Latest completed installed pair recorded here: **0.3.133 (136)** on Mac and
  physical iPad, source commit `c3516cc4`, wire **37**, content manifest **18**.
  GUI-284's exact receipt and scoped acceptance are recorded above; full
  performance and hardware Pencil acceptance are not implied.
- GUI-266's lasso-selection lifecycle follow-up is installed and awaits
  Amir's physical user acceptance; scoped checks are not full acceptance.
- GUI-240 is **Done by Amir's explicit decision**; its integration is complete.
  Remaining GUI-250 performance/long-session conditions were not declared passed.
- GUI-183, GUI-196, and GUI-197 remain In Progress in Linear as checked on
  September 19 at 22:18 UTC. Their scoped evidence remains useful; broader
  acceptance is tracked independently.
- Documentation translations do not change application behavior. Source-directory
  Markdown belongs to the build inventory, so this documentation revision has a
  different input identity from earlier installed releases.

## GUI-283 — резкость собственных чернил при увеличении страницы

Изолированная ветка `codex/ink-zoom-sharpness` основана на `93328088`, без изменений рабочей ветки параллельной задачи. Канонические координаты и исходные измерения сохранены: `PageInkProjection` следует существующей камере и рисует только видимую область страницы в фактической плотности экранных пикселей, вместо растягивания прежнего Metal-изображения. Перо, ластик и импортированная растровая основа используют согласованное смещение; Mac уведомляет страницу при изменении нативной проекции. Буферы выделяются только для непустых чернил; MSAA на Apple GPU использует временную память плитки, без второй полноэкранной копии.

Окончательная проверка неизменных исходников: **физический iPad 14/14, Mac 8/8**, предупреждений выполнения нет. Проверены масштабы 1–8× и возврат без перестроения исходной геометрии, резкость диагонального края на снимке при 8×, координаты ввода, перо/ластик, сохранённая геометрия и импортированная основа, настоящий pinch, перемещение увеличенной страницы и перелистывание вперёд/назад. Три подготовленные страницы по 600×600 пикселей прошли при общем бюджете резервирования 16 МиБ; после очистки резервы освобождены — это проверка учёта, не измерение RSS. Снимок `own-ink-native-8x-sharp` просмотрен.

Источник SHA-256: `0387f0680b50651a5eba47a0bdd70b6585fbbf7ab2efa6b22750aa91b8b2f1cf`. Свидетельства в рабочем дереве `/Users/amir/.codex/worktrees/ink-zoom-sharpness/Notebook`: `.build/gui283-check-v4/verification.json`, снимки `.build/gui283-images-v4/`. Предыдущие попытки сохранены: v1 — неверное имя модуля в новом тесте Mac; v2 — тест ошибочно использовал исходный масштаб 0,22 вместо 1; v3 — 13/13 и 8/8 до уточнения расхода памяти. Один запуск v4 корректно отказался запускать второй Xcode одновременно с основной задачей.

По явному ответу Амира **только код и проверки**: рабочие Mac/iPad-приложения, их версии, данные и ключи не менялись; использовались изолированные тестовые приложения, без симулятора. Установка, аппаратная проверка Pencil пользователем и длительная приёмка не заявлены. Эта правка не включает экспериментальный тензорный рендерер и не добавляет измерений ускорения.

Позднее проверенная правка `fae917b0` включена в сборку 135 в рамках отдельно
разрешённого внедрения GUI-282; результат общей проверки и установки — выше.

## GUI-266 follow-up: lasso selection survives scene publication — build 134

Source commit `3fc651d45662975749dc81dd58161cf541309384` is pushed. Immutable input SHA-256: `351d62d13e7ae42797cc0a5f1e72d64644c455d15db47669532f3f2b91862450`. The signed pair retains wire 37 and manifest 18.

- Reproduced the reported Pencil outline without retained selection in the mounted native scene: an older SQL scene cut discarded accepted lasso selection while its ink conversion was still being written. The existing accepted-working-graphic owner now retains it until exact publication; no new selection state or fallback was added.
- A second, independent `AgentOverlayView` callback cleared the selection from its rendered element list even after the conversion had saved. Its removal leaves reconciliation to the model instead of two competing owners. A captured diagnostic stack identified this callback; temporary logging was removed before the final run.

Final unchanged-source verification: **physical iPad 34/34**, zero failures/skips, runtime warnings empty. The mounted-scene regression blocks the SQL writer, completes lasso through the installed Pencil recognizer, publishes the older scene, then releases persistence and verifies the same selection and geometry survive. It includes 27 pen strokes and a long self-intersecting eraser, preserving the original ink journal. Native coverage also exercises type filters and accepted moves; device UI gestures cover selected-object drag, edge taps, zoom/camera pan and page curl. The retained selection screenshot was inspected. Pencil contacts in the native regression are synthesized on the physical device, not hardware Pencil acceptance. No simulator was used.

Diagnostic runs remain recorded: A corrected a missing notebook pin in the regression setup; B reproduced the original premature deselection; C/D isolated the remaining view-owned reset after the model fix. Final evidence: `.build/gui266-lasso134e/verification.json`, `.build/gui266-followup134/attachments-e/`, `.build/gui266-build134/build.json`. A read-only copy of live page ink was separately selected and saved in isolated stores; it was not a production-content mutation or a live UI acceptance claim.

Mac and physical iPad were updated in place to **0.3.131 (134)** and launched at about **23:05 UTC on September 19**. Amir explicitly authorized interrupting active work; ordinary AppKit shutdown completed without forced termination. Mac store/spaces/registry/activation bytes before relaunch and the iPad workspace registry digest were preserved. Installed versions were read back on both devices. Fresh installed-helper readback at cursor **25774** matched baseline **25753** for the checked page and board data/content/ink revisions. The installed iPad screenshot shows the existing user notebook and ink. Receipt: `.build/gui266-install134/installation.json`. GUI-266 user acceptance, hardware Pencil feel and full performance/long-session acceptance remain open.

## GUI-266 follow-up: page gesture ownership and large selection — build 133

Source commit `8d02d9469e1122f10b52461e629fad173822da4f` is pushed. Immutable input SHA-256: `993a14ae101f3bc556ee4eef5c60cac11a24e4ccd2b8901927c3bdfc372400a6`. The signed pair retains wire 37 and manifest 18.

- UIKit's curl now waits for contact admission before beginning, instead of being cancelled after it has already started. Selected-object manipulation, editing and zoom own their contacts. System edge-tap page turns are disabled. Curl playback is 1.8 times faster while transitioning, with ordinary layer timing restored afterwards.
- The existing one-finger camera owner now also pans zoomed paper, constrained by the reading camera. Selected graphics own their visible selection envelope; erased graphics retain exact remaining-paint hit testing.
- Viewport-sized figures are no longer excluded from selection. Measured-ink point picking uses the retained triangles directly rather than building a pathological overlapping stroked path; chronological erasure and transformed geometry remain intact. Raw-ink selection budgets were not changed.

Final unchanged-source verification: **physical iPad 40/40**, runtime warnings empty; **Core 4/4**. Real device UI gestures exercise selected-object drag, both edge taps, pinch zoom, one-finger camera pan, return to fit, forward/reverse curl and the existing inline text/formatting/layer flow. Screenshots were inspected. A 60,000-vertex Core picking regression completed in 14 ms. Synthetic native contacts do not establish hardware Pencil feel; no simulator was used. Diagnostic runs A/B remain recorded: a recognizer-reset assumption and UI pinch targeting/near-fit precision were corrected in the tests, without weakening production admission thresholds. Final evidence: `.build/gui266-selection133c/verification.json`, `.build/gui266-followup133/core.log`, `.build/gui266-followup133/attachments-c/`, `.build/gui266-build133/build.json`.

Mac and physical iPad were updated in place to **0.3.130 (133)** and launched at about **22:37 UTC on September 19**. The first normal Mac quit waited at its active-work confirmation and timed out before replacement; it was cancelled. Amir then explicitly authorized interruption, and the ordinary AppKit shutdown completed without forced termination. Mac store/spaces/registry/activation bytes before relaunch and the iPad workspace registry digest were preserved. Installed-helper readback at cursor **25133** matched baseline **25126** for both checked pages and the board's content/ink revisions. The installed iPad screenshot shows the existing user notebook and ink. Receipt: `.build/gui266-install133/installation.json`. User acceptance, hardware Pencil feel and full performance/long-session acceptance remain open.

## GUI-266 follow-up: one layer menu — build 132

Source commit `f7e3b25b3d77f6fb7e56b293bae508d3fd5e1b4b` is pushed. Immutable input SHA-256: `33530e103e28b9c8d6d209df5b600eceab377246dbcc3b1f960c1045167a935a`. The signed pair retains wire 37 and manifest 18.

- One layer button opens four textual actions: one layer down/up and all the way to the bottom/top. iPad and Mac share one action enum and native command owner; old front/back callbacks were removed. The complete durable painter order, not the viewport, determines the result. Stable ordering within selected groups, undo and exact-source admission are preserved.
- The first physical UI check exposed a separate text jump during keyboard dismissal. Finger displacement was measured relative to a moving SwiftUI anchor. The recognizer now measures displacement in its stationary window, while hit resolution remains scene-local; an active text editor cannot start an object drag.

Final verification: physical iPad 8/8, Mac 1/1, runtime warnings empty. The iPad UI scenario executes all four menu actions, formatting, selection and finger drag, checks edge-disabled actions, fitted bounds and unchanged paper/ink. Screenshots were visually inspected. A native regression keeps the finger stationary while the layout moves, then verifies the exact physical drag delta. Core 5/5 includes all four moves on page/board, offscreen membership, reopening, undo, stale-source rejection and a 100,000-ID ordering pass. No simulator was used. Initial diagnostic failure remains recorded in `.build/gui266-selection132`; final unchanged-source success is `.build/gui266-selection132b/verification.json`.

Other evidence: `.build/gui266-followup132/core.log`, `.build/gui266-followup132/attachments-b/`, `.build/gui266-build132/build.json`.

Mac and physical iPad were updated in place to **0.3.129 (132)** and launched on September 19 at about 21:59 UTC. Receipt: `.build/gui266-install132/installation.json`. Mac store/spaces/registry/activation bytes before relaunch and the iPad workspace registry digest were preserved. Fresh installed-helper readback at cursor 24243 confirmed the two checked pages and board content/ink revisions unchanged from the pre-install baseline. Installed iPad screenshot was inspected; the existing user notebook is shown. GUI-266 physical user acceptance and full performance/long-session acceptance remain open.

## GUI-266 follow-up: lasso and text selection — build 131

Source commit `df490a0203790c5b41ab1635391a83c8d44714f4` is pushed. Immutable input SHA-256: `74c6fef051ee0b2e987509362e7816747df8f3102ff08a82276908190f58124d`. The signed pair includes GUI-183, GUI-240 and GUI-273 (wire 37, manifest 18).

- Lasso now rasterizes measured triangles in bounded batches instead of constructing a pathological overlapping CoreGraphics path. Ink projection uses the graphic's source budget instead of a second, obsolete 16-stroke limit. A read-only copy of 48 live ink actions reproduced both failures; isolated probes selected 27/21/5 strokes in 62/74/147 ms and saved each conversion. These timings describe selection calculation, not durable write completion.
- Native text uses one fitted geometry for rendering, hit testing, selection and manipulation. The duplicated drag projection was removed on iPad and Mac. Legacy oversized text frames can commit a move.
- Both text-selection contexts have one clipboard menu with textual Cut/Copy/Paste actions. UIKit owns inline paste. Native-text A| is removed; layer order is exposed in the primary selection bar.

Final checks: physical iPad 12/12, Mac 1/1; runtime warnings empty. Core DrawingToolsContent 5/5 includes conversion of 27 strokes, reopening, original ink preservation and undo. Native scene checks exercise the installed Pencil recognizer with measured, synthesized Pencil contacts; this is not hardware Pencil calibration. UI checks exercise real selection, formatting, finger drag, copy/paste/cut and visually inspected fitted bounds. Diagnostic runs A/B exposed a legacy-frame commit mismatch and a system paste-permission interruption; these were resolved before the immutable final run C. No simulator was used.

Evidence: `.build/gui266-selection131c/verification.json`, `.build/gui266-followup131/core-c.log`, `.build/gui266-build131/build.json`, `.build/gui266-install131/installation.json`. Mac and physical iPad were updated in place to **0.3.128 (131)** and launched on September 19 at about 21:31 UTC. Mac store/spaces/activation/registry bytes before relaunch and the iPad workspace registry digest were preserved. Fresh installed-helper readback at cursor 23608 confirmed both page content/ink revisions and the board content revision unchanged. The installed iPad screenshot shows the existing user page and ink.

At that receipt GUI-266 was In Review for Amir's normal Pencil use on that page.
Full physical/performance/long-session acceptance was not claimed.

## Recent integrated releases and milestones

Detailed original attempts, failures, raw identifiers, and local evidence paths
remain in the
[immutable journal through commit 1723ec2b](https://github.com/AmirTlinov/Notebook/blob/1723ec2be6f6b8dda29e3a575fd6376fff03e093/docs/verification.md).
The summaries below preserve scope; they do not reclassify historical failures.

### GUI-183 — remote Codex integration, September 19

Merge `5a8f3960` integrated `fdfb6eb7` into `e9716207`, retaining the
current editor, typesetter, and account-owned bootstrap. Wire became 37;
content manifest stayed 18. The pair requires coordinated updating.

Immutable merge checks: Core/Codex 7/7, Mac 3/3, physical iPad UI 1/1.
The actual UI opened the fourth of four 60 KB requests and addressed all four
decisions. Its screenshot showed the full request, command, and buttons.
A real isolated `notebook-acceptance prepare-device` check confirmed shared
account credential, portable iPad root, and separate Mac bundle.
Evidence: `.build/gui183-merge/native-20260919/verification.json`,
`core.log`, `portable-bootstrap.json`, and `approval-render/`.

That merge did not itself install production or prove WAN operation. Later
build 131 included it. GUI-271's backend setup/repair and tool-filter preservation
were exercised with real signed Codex 0.155.0 and isolated state. Its Mac setup
button's direct UI click remained unverified after ScreenCaptureKit failed.
GUI-272 dictation was intentionally left unchanged at Amir's request;
that decision does not certify the existing private HTTP/JWT route.

### GUI-266 — build 130, September 19

**0.3.127 (130)**, wire 36/manifest 18, followed integration `7841111c`.
It unified empty-text lifecycle, addressed text editing/deletion, direct object
selection, formatting/clipboard, and measured-ink selection.

Immutable source SHA:
`ef0d4891404982db0faeea78a3d245f1f71f80fef96bbc32b3e2dd01ac41dcea`.
Final physical iPad 23/23 (20 native + 3 UI), Mac 1/1, Core 15/15, MCP schema
10/10, and MCP source TypeScript checks passed. Earlier compile/UI failures
remained recorded. Synthetic UIKit Pencil contacts did not establish hardware
Pencil behavior.

Installed over 129 at 20:22 UTC with container/identity preservation.
Live readback cursor 23103 matched baseline 23097. The immediately preceding
IPC attempt was unavailable and remained a failed observation. The inspected
post-install screenshot had a lock-screen overlay; unlocked user acceptance
was not claimed. Evidence: `.build/gui266-selection130f/`,
`.build/gui266-build130/`, and `.build/gui266-install130/`.

### GUI-273 — geometric ink and preview recovery, build 129

**0.3.126 (129)** removed an observed main-thread CoreGraphics softmask stall
from automatic preview by preparing the canonical erase mask off-main.
Measured page ink stayed geometric after pen-up, settle, and reopen.
Content-digest invalidation replaced unnecessary camera-driven regeneration.

Source SHA:
`4dcd0c3104e9b93cd5eef9ace06e7bcb06ff73f2c3a9eec3af17f7c525799906`.
Physical iPad 17/17 and Mac 2/2 passed; Core scene-paint revision 1/1 passed.
The 3,603-sample Mac regression took 0.821145 seconds for preview+tile with
maximum main-actor heartbeat gap 0.011097 seconds; warm publication took
0.128907 seconds. These are scoped regression measurements, not system FPS.

Installed in place at 19:42 UTC. Readback cursor 23047 matched baseline 23040.
A later Mac document-opening gesture could not be confirmed because CUA returned
`noWindowsAvailable`. Evidence: `.build/gui273-verify129c/`,
`.build/gui273-results/`, `.build/gui273-build129/`,
and `.build/gui273-install129/`. Hardware Pencil feel, full system metrics,
ten repetitions, and 30-minute collaboration remained outside this check.

### GUI-240 — scientific visualization integration

At Amir's explicit request, GUI-240 was closed and the completed branch integrated
as `451161d7` (`17b6cc5b` into `2459e309`). Eight conflicts were resolved
while preserving document toolbar/LaTeX/program behavior and the current
library/devices/formatted-text implementation.

Integration checks in `.build/gui240-merge/`: Core 21 + 21 tests in partially
overlapping suites, MCP TypeScript plus 33 tests, Mac and iPad Simulator
compile/link. A generic iOS attempt lacked its staged device typesetter library;
the final iPad integration build used the prepared Simulator runtime.
That step did not install applications or establish a new signed release,
physical acceptance, or `verify.sh --full`.

Implemented contracts are maintained separately:
[lifecycle/packages](document-program-fragments.md),
[authoring](../MCP/skills/notebook/references/programs.md),
[canonical paper](document-page-fragments.md),
[shared attention](shared-context-contract.md), and
[export](document-export-contract.md).

Important scoped results and remaining limits:

- A 300 MiB program resource was delivered to the private Simulator and read after
  the sending Mac stopped. Staging, delivery, and actual offline display were
  recorded separately.
- Native/source/geometry checks and direct Mac/browser interactions found and
  fixed paper distortion, idle layout feedback, source/side-by-side presentation,
  program-source visibility, bottom spacing, and linear-example resize/drag.
  These successes do not erase later reader-entry UI failures.
- Final bounded-paper checks in `.build/gui250-visible-paper-v4/`:
  Simulator native 33/33, Mac native 11/11, no skips/runtime warnings.
  Inspected A4/Letter PNGs and real native curl landings are not a full UI or
  system-performance run.
- Two Sound request-to-installation observations were **1,864 / 1,174 ms**,
  not p95. The **cold ≤500 ms goal was not met**.
- The final addressed Mac reader-entry attempt
  `.build/gui250-addressed-reader-ui-v1/` built but passed **0/3 UI tests**:
  search found the cover, double-click did not establish the reader surface.
  Window title alone was insufficient. Its later UI-only WIP fixture was not
  run and was removed when work stopped.
- Full reference review, shared/recovery scenarios, system FPS/CPU/GPU/memory,
  ten repetitions, and 30-minute acceptance were not all completed for the final
  integrated GUI-240 source. Closure was an owner decision, not a fabricated PASS.

### S1–S10 programmable SDK milestone — September 18

This separate earlier milestone was accepted on production builds 105/106.
Build **0.3.103 (106)** used source `6bf6159`, retained containers and keys,
and confirmed saved/received/shown state without rerunning the prior undo.
The final surface retained human continuation `SDK count101`; cleanup removed
only the four test-created items and returned item count 7→7.

The final aggregate checked 70 scenario runs (seven × ten), 60 exact publications,
and 125 successful native summaries, excluding five failed/invalid summaries.
The original record also reports a >30-minute collaborative native/MCP scenario.
This is not a claim that every historical suite or `verify.sh --full` passed.

System traces lasted 135.816 and 300.948 seconds. The latter was a bounded
five-minute lifecycle/undo/idle recording, separate from the long collaborative
session. For Notebook PID 7976:

| Metric | Median / p95 / maximum |
|---|---|
| Physical footprint, 293 samples | 279.361 / 288.470 / 457.127 MiB |
| CPU, 292 samples | 25.681 / 72.051 / 127.697% |
| Device Core Animation FPS estimate, 298 samples | 8 / 60 / 60, including idle |
| Device hardware GPU, 298 samples | 0 / 55 / 68% |

Notebook GPU intervals summed to 854.219 ms across 817 possibly overlapping
intervals, not wall-time utilization. System display/GPU values do not establish
isolated Notebook 60 FPS or absence of hitches. Compiler memory and SDK v1/v2
comparisons were separate measurements.

Evidence: `.build/s10-complete-20260918/final-receipt.json`,
lifecycle/ink/publication receipts, final read, trace/XML, native AX/PNG, and
public requests/replies. [Measurement summary](programmable-notebook-measurements.md).
This milestone does not accept later Mac workspace, drawing, or GUI-240 changes.

## GUI-277 — English documentation and contract corrections

The September 19–20 documentation update reviewed all 87 tracked Markdown files
and changed 79. Project-owned Russian documentation is now English; existing
English upstream notices and licenses remain unchanged. No application or test
implementation changed in this slice.

Corrections cover current export formats and canonical typesetting, the three
public MCP tools, package authoring/publication, scientific-example inventory,
resource budgets, direct selection/drag, account-owned connection, and verification
scope. The retired native TeX probe is labeled historical and its missing old
runtime dependencies are explicit. Long historical journals are summarized here
with immutable links to their complete original records.

Checks: 261 local Markdown links and 11 heading targets resolve; all eight fenced
JSON examples parse; code fences are balanced; tracked Markdown contains no
remaining Cyrillic prose; Markdown diff whitespace checks pass. Referenced current
repository paths resolve; the single absent path is the explicitly retired TeX
lockfile in the historical probe guide. No native build, app installation,
physical acceptance, or external-link availability is claimed by these checks.

## Earlier history

The immutable journal above preserves all earlier release attempts and evidence,
including negative or incomplete results. Supporting English summaries:

- [September 8 audit](audit-2026-09-08.md) and
  [September 13 audit](audit-2026-09-13.md).
- [September 13 implementation series](implementation-2026-09-13.md).
- [Historical render-boundary measurements](live-document-render-boundary.md).
- [Document editor opacity check](document-editor-opacity-verification.md).
- [Data preservation](current-mac-preservation.md) and
  [retired-owner conversion](retired-owner-conversion.md).
- [SDK v1/v2 measurements](programmable-notebook-measurements.md).

Local `.build/` evidence is not guaranteed to exist in every checkout. Git retains
the report, not all large traces or application containers. An unavailable artifact
limits re-verification; its path alone cannot support a new acceptance claim.

## How to record new results

Follow [verification selection](release-build-contract.md#verification-selection)
for the smallest sufficient regression plus affected user scenario.
A receipt should identify:

1. Exact source commit and immutable input hash, build/version, platform/device,
   and any diagnostic instrumentation.
2. Executed tests and gestures, failures/skips/warnings, and the observed result.
3. Evidence paths and the boundary between simulated/native/hardware input.
4. For installation: signed artifact identity, preservation checks, launch, and
   fresh installed-helper readback.
5. Remaining conditions, separately from issue closure or merge state.

Full acceptance additionally needs system frame/CPU/GPU/memory measurements,
ten scenario repetitions, and 30 minutes of collaborative work on the named
build. Video, CADisplayLink, compiled UI, and cached pixels cannot replace the
corresponding system or physical observation.
