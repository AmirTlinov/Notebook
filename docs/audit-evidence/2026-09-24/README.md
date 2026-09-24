# GUI-295 — воспроизведение разрывов публикации

База `a212734402e794ff56c5dd8ffd6465c92dffd262`, приложение соответствует реализации
пары 194. Во время диагностики менялись только тесты. Новая пара не собиралась
и не устанавливалась; нативные проверки iPad использовали отдельную test identity
на физическом устройстве, удалённую штатным cleanup. Исторические архивы и
пользовательское содержимое не менялись.

`page-publication-regressions.patch` добавляет три проверки желаемого поведения.
**На этой базе они падают** — это сохранённый диагностический материал, не
выключенные или замаскированные acceptance failures. Применять в изолированном
checkout нужной базы; не поверх чужих изменений:

```sh
git apply --check docs/audit-evidence/2026-09-24/page-publication-regressions.patch
git apply docs/audit-evidence/2026-09-24/page-publication-regressions.patch
./verify.sh --only --optimized \
  --test NotebookTests/PageTurnSelectionTests/testNotebookAcknowledgementCannotBecomeAnUnrequestedReverseTurn \
  --test NotebookTests/NotebookPageAddressTests/testUnchangedReloadRetainsThePreparedPageSourceIdentity \
  --evidence-dir .build/gui295-owner-reproduction
./verify.sh --only --optimized \
  --test NotebookMacTests/MacPagePublicationTests/testPageChangePublishesStaticMaterialAsOnePage \
  --evidence-dir .build/gui295-page-publication-reproduction
```

Один Xcode runner, только физический iPad. Первый диагностический Mac-probe
ошибочно проверял только `layer.contents`, хотя NSImageView хранит изображение
в `image` либо crop sublayer; его нулевой счёт **не** принят за дефект приложения.
После исправления наблюдателя получен `mac-cold-publication.json` с реальной
последовательностью 0 → 1 → … → 35. Вариант перехода сначала имел compile error
(пропущенный navigationGeneration); он исправлен до предметного прогона.

Сохранены экспорты xcresult без редактирования assertions:
- `ipad-ownership.json`: 2 FAIL; старое подтверждение становится переходом и
  равное чтение получает новую identity источника.
- `mac-cold-publication.json`: 1 FAIL; 35 картинок предъявляются частями,
  без промежуточного захвата изображения.
- `mac-page-change.json`: 1 FAIL; то же при переходе с уже открытого листа
  обычной командой модели. Этот прогон включает стоимость снимка.
- `mac-partial-page.png`: AppKit capture нового листа, один рисунок и 34 заглушки;
  не системная видеозапись и не измерение физической задержки.

Полные `.xcresult`, команды, подписи и source manifests остались в каталогах
`.build/`, указанных в JSON. Source hashes различаются из-за версий probe;
код приложения между этими прогонами не менялся. Переходные системные кадры iPad,
причинный порядок в жесте Амира и полная performance-приёмка остаются непроверенными.

## Дополнительная регрессия и замер библиотеки

`page-owner/camera-selection-baseline.json` — обычный `requestShow` холодного
листа в открытой тетради: камера теряет принятый переход. Регрессия находится
в `NotebookPageLifecycleUXTests`; её предел 1 с включает штатное движение камеры
0,3 с. Первый вариант probe ошибочно использовал общий предел 100 мс, поэтому
он не принят как доказательство этого дефекта; здесь сохранён корректный baseline.

`svg-runtime-probe.c`, `svg-runtime-probe.svg`, `svg-runtime-baseline.json` —
изолированный вызов именно текущего FFI, 10 новых процессов × 35 конвертаций.
Запуск из корня исходников после подготовки подписываемой runtime-библиотеки:

```sh
clang -O2 -ISources/CNotebookTypesetter/include \
  docs/audit-evidence/2026-09-24/svg-runtime-probe.c \
  .build/notebook-typesetter-runtime/macosx/libnotebook_typesetter_runtime.a \
  -framework Security -framework SystemConfiguration -liconv -lresolv \
  -o .build/svg-runtime-probe
/usr/bin/time -l .build/svg-runtime-probe \
  .build/notebook-typesetter-runtime/Resources/{texlive.zip,latex.fmt,fonts.tsv} \
  docs/audit-evidence/2026-09-24/svg-runtime-probe.svg
```

Это только процесс библиотеки на Mac. Начальное открытие TeX-ресурсов не входит
в отдельные строки SVG, но входит в totalMS; RSS включает весь процесс.
