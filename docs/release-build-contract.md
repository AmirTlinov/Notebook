# Verified pair builds

`Applications/notebook_release.py` owns build-input inventories, evidence
validation, signature checks and pair installation. `verify.sh` and the pair
builder share this implementation.

Inventory format 2 covers `Package.swift`, optional `Package.resolved`,
`verify.sh`, `Sources`, `Tests`, `Applications` and `MCP`. File additions,
deletions, bytes and executable mode affect its hash. Symlinks and special files
are rejected. Enumeration is independent of Git and excludes only explicitly
named generated files, build directories and installed dependencies. Root
Markdown and `docs/` are outside the build inventory; Markdown inside an
inventoried directory is an input.

## Verification selection

For an ordinary change, select the defect regression and affected user scenario.
`./verify.sh --plan` proposes a starting selection; `./verify.sh` runs it.
Use `--base HEAD^`, for example, to describe the last committed slice.

- `--test target/suite/method` and `--profile name` add to automatic selection.
- `--only --test … --profile …` runs only the explicit scope and records
  `selectionMode: explicit-only`. A single regression may need only one selector.
- `--profile compiler` prepares the pinned TypeScript runtime before discovering
  and executing the CLI, process and memory contracts. Swift selectors resolve
  against the toolchain's discovered function IDs, including parameterized tests.
- `--optimized` compiles selected native Debug checks with Swift `-O` and C `-Os`,
  preserving isolated fixtures without charging an unoptimized QuickJS interpreter
  to the production CPU budget. The selection and receipt
  record this choice; it is not a Release artifact or the `--full` route.
- `navigation-ux` additionally exports system `XCTHitchMetric` samples and rejects
  any zoom/page-turn ratio above 1 ms/s or total hitch time above 33 ms in each
  of ten repetitions, or missing measurements. A relative Xcode
  baseline cannot waive the absolute limit; release validation rechecks it.
- An unmapped native source seeks a matching `*Tests.swift` on its platform.
  `document-web` covers JavaScript contracts and four native WebKit boundaries;
  `documents` is the broader integration profile.
- `unclassified` files require engineering selection, not a compulsory map entry.
  Explicit selection retains them in the receipt; unresolved automatic selection
  stops. A shared UI fixture requires a named gesture.

An empty selection, unexecuted selector, failure, skip, runtime warning or tool
version change prevents PASS. UI changes require the affected gesture; Node and
native unit checks do not substitute for it. A 100,000-item load is relevant when
the corresponding algorithm changes. `--full` is separate broad verification,
not the default for every edit and not physical acceptance by itself.

[The check registry](../Applications/notebook_check_registry.py) owns each check's
ID, contract, owner, platform, prerequisites, command, parser and evidence files.
Profiles and `--full` use that same execution path. Pure Python and Node contracts
read only their own toolchains; they do not require an Xcode build. Native Mac
checks use the headless `NotebookRuntime` host; iPad checks use the physical
release device. The full route preserves distribution, eraser, Core IPC and
computation proofs without starting a simulator or standalone Mac workspace.
Routes serialize mutable preparation in one checkout; native routes also claim
the host's Xcode slot. Physical iPad checks verify lock state before preparation,
enumeration and execution, stopping when the device requires a passcode.

`verification.json` is written only after success and binds immutable sources to
the complete evidence directory. Both routes record actual discovered, planned
and executed IDs, exact argv and source roots, toolchains, and prerequisite
commands. Native checks retain their xcresults; Swift inventories all products
through a captured stdout pipe and executes each selected product with its own
event file. Parameterized case counts accompany function IDs in the receipt;
Python and Node retain per-test outcomes. An unmatched selector, incomplete or
malformed report, selected skip, changed argv/source or missing prerequisite
refuses the receipt. `./verify.sh:selected` names the selected scope; `./verify.sh`
names all registry contracts. Neither receipt certifies physical acceptance.
Runtime admission and document publication are native checks; the real Codex panel
has separate host acceptance. Historical reports cannot become receipts retroactively.

Selected iPad verification installs signed Debug `.native-test` on the physical
release device. The selector removes that exact test identity before and after the
run, including a failed test command, so it cannot remain as a second installed app
or process beside Notebook Lab. Its isolated fixtures do not replace production
content, admission or Keychain groups. The separate Simulator acceptance route is
described below.

## Signed build

```sh
Applications/build-verified-pair.sh \
  --verification-dir /absolute/completed-verify-evidence \
  --evidence-dir /absolute/new-build-directory
```

The builder verifies current inputs, its own executable code and all evidence,
retaining the selected/full distinction in `verificationRoute`. It creates an
independent source copy, installs locked MCP dependencies without install scripts
and builds Release iPad, then `NotebookRuntime`. It packages the signed runtime
with the plugin metadata under `plugin/notebook/runtime/NotebookRuntime.app`;
`build.json` identifies that payload and both native products. Packaging preserves
the signed bytes. Xcode, Swift, SDK, XcodeGen, Node and npm must
match verification and remain unchanged.

The source snapshot reuses the selected checkout’s prepared Codex/Node runtime.
The same preparer still checks its pinned version marker and official signatures;
Mac build phases receive that exact stage, not a fresh network-only copy.
`NOTEBOOK_TYPESETTER_RUNTIME` selects the print compiler stage for verification
and pair builds. Both platforms use that same resolved path; without an override
the checkout's `.build/notebook-typesetter-runtime` remains the default. The
preparer verifies source identity and resources before reusing a stage.
The browser Swift module is also compiled before Xcode. `NOTEBOOK_SURFACE_STAGE`
points at the original checkout's prepared WASM and receipt. The Mac bundle
phase verifies that receipt against the snapshot's inputs and module bytes;
the Xcode script sandbox remains enabled.

Both apps require genuine Apple Development signatures from team `M94V58FCVP`,
matching pair versions and exact bundle identities:

- iPad: `com.amirtlinov.notebook.preview`, its existing Keychain group and a profile
  admitting the certificate and designated physical device.
- Plugin runtime: `com.amirtlinov.notebook.mac`, arm64, `LSUIElement` and
  `NotebookPluginRuntime`. It bundles the MCP server and runs AppKit for system
  document adapters without a Dock icon or workspace window. Closing a panel
  leaves storage, transport and active agent work alive.

Both signatures require `iCloud.com.amirtlinov.notebook`, CloudKit and Production;
Push remains development for Apple Development signing. Mac also requires an
embedded profile, its Provisioning UDID (not Hardware UUID), valid expiry and
certificate. A profile may allow iCloud services with `*`; the app signature still
requires exactly CloudKit and the explicitly admitted container/environments.
Unknown rights, foreign Keychain groups, Simulator Mach-O or modified signed
files reject the pair. See [cloud delivery](cloud-delivery-contract.md).

Mac contains exactly two XPC services: `NotebookScriptService` and
`NotebookMarkupService`, with distinct identities, Application service type,
their SDK/parser resources and the same signing team. Their rights are limited
to App Sandbox: no network, expanded file access or foreign Keychain groups.
QuickJS is linked into the worker, not the main application.

Bundle IDs and entitlements are target-specific. Global
`PRODUCT_BUNDLE_IDENTIFIER` or `CODE_SIGN_ENTITLEMENTS` overrides would corrupt
nested identities and are forbidden. Native tests may use their documented
ad-hoc worker route; release still requires genuine developer signing.

Xcode 27 adds broad temporary read rights to tested sandbox targets. Mac native
verification therefore uses build-for-testing, reapplies each service's exact
source entitlements, reseals the host, verifies signatures, then runs
test-without-building. Test-host rights never expand the worker contract.

## Bundled compilers

`NotebookTypesetter` is statically linked into both apps.
`prepare_notebook_typesetter.py --prepare --platform <SDK>` validates pinned WASM
cores, prepares AOT/host code and the declared fonts/packages. `Runtime.lock.json`
pins resources, source and toolchain. The full offline distribution is about
1.48 GB; the lockfile and generated inventory own the exact size and hashes.

To rebuild the TeX guest from its pinned source on Apple Silicon macOS:

```sh
python3 Sources/NotebookTypesetterRuntime/build/rebuild-tectonic.py \
  --work .build/typesetter-build/tectonic-rebuild
```

Use a fresh directory and the explicit Rust toolchain/`wasm32-wasip1` target
declared in the lockfile. The command verifies a local WASI SDK and dependency
archives, applies the reviewed patch and runs the existing upstream build with
locked Cargo dependencies. It does not install a global toolchain, replace the
tracked kernel or prepare/install either app. Its receipt, logs and source
snapshots identify the output; admit the checked `tectonic.wasm.gz` and its
lockfile hashes together, then run the existing runtime preparation above.

Only the immutable `/bundle` and `/fonts` resource owners supply read-only TeX
handles. They do not hash requested bytes or drain unread tails at close to
produce discarded digests. Primary source, `/input`, generated auxiliary files
and outputs retain their digest semantics; TeX convergence still compares
actual auxiliary bytes. Resource validation, bounded memory and cancellation
remain owned by the same capability runtime.

The pinned AOT generator polls cancellation at guest function entries and loop
back-edge targets; forward-only labels carry no gate. It rejects unknown control
flow. `build/test-supervisor.py` executes generated loops, indirect recursion and
trap recovery; native checks join ten cancelled compilations. Resource reads
validate the ZIP entry's CRC and declared length before admitting cached bytes.

`bundle_notebook_typesetter.py` copies only declared, hash-checked resources.
Release validates the inventory in both apps. `--check` neither downloads nor
builds. TypeScript uses its separate signed child of the markup XPC service and
inherits its sandbox. The current print route has no native TeX/image helper.

## Build versus installation

A `build.json` with `verified-build` records signatures, binary UUIDs and bundle
inventories. It proves the build, not permission or completion of installation.
The builder does not launch or install either product. Install its verified pair
through the same release owner:

```sh
python3 -B Applications/notebook_release.py install-pair \
  --source-root "$PWD" \
  --build-dir /absolute/verified-pair \
  --evidence-dir /absolute/new-installation-directory
```

Before installation, finish the serving runtime through ordinary quit and wait
for its process to exit. On the first plugin transition, unregister the former
Notebook login item. The installer refuses a live owner, downgrades and changed
signed bytes. It publishes the complete verified plugin, installs it, checks its actual cached payload,
then updates iPad in place and reads back the installed identity. Unknown outcomes
remain `incomplete`; it never restores data or retries an uncertain installation.

The iPad preservation check uses its bundle domain. It compares the bounded
workspace catalog bytes and IDs before preparation, immediately before the iPad
update, and afterward; the selected SQLite must remain a readable nonempty file.
An installed app with neither a catalog nor a store has an empty baseline. Data
without a provable catalog refuses installation. App-group IDs stay unchanged;
iPadOS container paths and SQLite/WAL sizes are diagnostic. The installer reads
only the small catalog and file metadata, never copies SQLite or archives.

`MCP/plugin` is authored input. `install-pair` publishes its frozen metadata and
signed runtime together into `~/Library/Application Support/NotebookPlugin/marketplace`.
The publisher validates the copied package before atomically changing the catalog
pointer to `releases/<version>/notebook`. A version binds all metadata and runtime
bytes; reusing it for changed content is refused. Installation scripts come from
the verified snapshot. Edits in the primary checkout cannot change a published pair.
After the complete installed pair is confirmed, obsolete published packages are
removed; Codex's own cache and active connections remain host-owned.

Before the next authored version change, migrate an existing source registration once:

```sh
python3 -B Applications/notebook_release.py migrate-plugin-source \
  --source-root "$PWD" --evidence-dir /absolute/new-migration-directory
```

This adopts the currently installed signed cache as the first immutable publication,
then uses official `codex plugin marketplace remove/add` commands to retain the
`notebook@notebook-local` identity, version and enabled state at the new source.
It does not reinstall the plugin or change its cache. A failed registration restores
the previous source; an unfinished transition keeps a pinned receipt for the next
invocation with a new evidence directory. The catalog can briefly
disappear between the two CLI commands. Existing chats reconnect through the host's
normal lifecycle. Complete this transition before bumping the manifest; each later
native pair receives a new plugin version and is released only by `install-pair`.
The release owner holds an OS `flock` shared with its Node adapter and Codex CLI
through an inherited descriptor. The last process exit releases it; the next admitted attempt discards unpublished
copy stages. There is no persistent directory lock to remove after a crash.
Verify the live IPC peer and current data/trust separately after delivery.

Ordinary in-place updates preserve containers, identities and keys.
Historical archive conversion is a separate explicitly authorized operation, not
a prerequisite to each release. Use current installation tooling and live
readback; see [verification](verification.md) for the last installed pair.

## Isolated acceptance

`Applications/notebook_acceptance.py` builds the Release schemes
`NotebookAcceptance` and `NotebookRuntime`. The iPad acceptance app
uses `.acceptance` in the selected Simulator; Mac uses
`.acceptance.<12-hex SHA-256 of canonical checkout path>`. Each checkout has its
own runtime identity. The driver locks a particular Mac bundle or Simulator
UDID; run one Xcode runner at a time. It has no physical device install command.

`prepare` creates a new shared checkpoint with separate roots, manifests, settings
and Keychain services. It does not inject trust. Acceptance without iCloud cannot
prove initial account connection; already-connected scenarios require an admitted
pair. Real first connection uses signed apps and the private account directory.

Mac and both XPCs use one Apple Development certificate. Stateless pair-test workers
use `.acceptance-runtime-<lowercase signing team>`; native unit tests use
`.native-test`. Existing ad-hoc containers and ACLs are untouched. Workers are
resealed with exact source entitlements after Xcode.

`upgrade` resolves a relocated Simulator manifest through the current container
of the same bundle, validates run/workspace/actor scope and preserves its original
bytes. Inventories are compared after stopping the identified test processes and
before relaunch; relocation changes only the root.

`build --development` creates an immutable diagnostic snapshot marked intermediate.
Final `build` requires a clean commit, immutable inputs and the exact Simulator
UDID. UI attempts retain build/run identity, xcresult, named images, video and a
system trace when requested. Video failure does not erase test evidence.

`--pencil` is accepted only by the Simulator acceptance bundle. It sends measured
test contacts through the normal Pencil owner and records that limitation.
It is not hardware stylus calibration. Production bundles or overlapping working
stores reject an acceptance manifest before model creation.

Use the environment explicitly selected for the task and label it honestly.
Video and CADisplayLink are not system FPS measurements. Full physical acceptance
requires the separate gesture, CPU/GPU/frame, memory and long-session evidence
described in [verification](verification.md).

Historical release-harness runs and former transition gates are retained in
[the original report](https://github.com/AmirTlinov/Notebook/blob/1723ec2be6f6b8dda29e3a575fd6376fff03e093/docs/release-build-contract.md).

The isolated acceptance schemes use UI tests, not `@testable` app imports.
Their Release applications disable testability and apply Xcode deployment
postprocessing/linked-product stripping while retaining the external matching
dSYM. Native unit hosts may enable testability; their timing observations are
not silently substituted for the deployed acceptance application. A strip phase
or a dSYM by itself does not establish successful profiling or UI acceptance.
