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

Registry/parser unit tests with explicitly fabricated command runners also own
an explicit fixture capability inventory. That discovery replacement is scoped
to the fake-runner call and restored afterwards; it never changes production
prerequisite checks. A separate negative test requires production to reject a
missing Swift toolchain before invoking it. These portable contracts are not
Swift compilation or native-execution evidence.

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
Runtime admission and document publication are native checks; direct MCP has an
installed transport check, and user interactions are accepted on the physical iPad. Historical reports cannot become receipts retroactively.

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
under `runtime/NotebookRuntime.app`;
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

Both apps require genuine Apple Development signatures from team `M94V58FCVP`,
matching pair versions and exact bundle identities:

- iPad: `com.amirtlinov.notebook.preview`, its existing Keychain group and a profile
  admitting the certificate and designated physical device.
- MCP runtime: `com.amirtlinov.notebook.mac`, arm64, `LSUIElement` and
  `NotebookHeadlessRuntime`. It bundles the MCP server and runs AppKit for system
  document adapters without a Dock icon or workspace window. Closing a MCP connection
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

## Pinned Codex build inputs

`Applications/NotebookCodexRuntime.lock.json` is the reviewed source pin, derived
from the complete, SHA-verified official Codex archive and the exact Node binary
and license members. It specifies every payload path, file hash, byte count,
type and mode. A cache's `runtime.json` is only an identity receipt, never an
alternative trust source. Updating these inputs requires reviewing the archive
pins and their complete inventory together.

The existing `prepare_notebook_codex.py --prepare --stage-root <root>` owner
returns the exact immutable `<root>/<manifestSHA256>` stage. The default root is
`.build/notebook-codex-runtimes`. Each admission checks the complete payload,
official Codex/Node signatures and both actual executable versions. Reuse makes
one full payload SHA pass, without downloading, extracting or copying. This adds
hashing cost compared with the old marker-only reuse; it is not a startup speed
claim. The preparer is a build prerequisite, not a live-runtime startup path.

Selected checks that use Node and signed pair builds prepare that stage once
before probing tools. The recorded command environment puts its exact directory
first on PATH; explicit Node probes and runtime packaging use `<stage>/node`.
Receipts bind both version probes and the scoped PATH to the checked source pin.
Pure Python selections retain their existing prerequisites.

Admission holds every parent directory by descriptor, opens leaf files relative
to those parents without following links, and rejects hardlinked payload files.
Root/name bindings and all file/directory fingerprints must remain unchanged
through the complete hash and use operation, including already-hashed files.
The streaming hash works without Python 3.11-only APIs.

A bounded per-manifest OS lease serializes writers. Only a complete, checked
private temporary stage is atomically renamed into its final name. A published
stage is never overwritten or deleted by this owner, including when invalid:
invalid/partial stages fail closed. This is cooperative-owner immutability, not
an OS immutable flag or protection against arbitrary same-user changes after
admission. Changes during the checked operation are detected. Cancelled attempts clean their own temporary
files; process-death leftovers are ignored. The former flat
`.build/notebook-codex-runtime` is neither read nor removed, so an older active
build can finish using its own input. There is no fallback to its old marker.

The same returned stage is supplied explicitly to release, selected native checks
and acceptance Xcode builds. Xcode has no default cache lookup. Bundling checks
the source and copied output against the same lock; release rechecks the final
bundle and records the identity in `build.json` and signature evidence. Selected
verification records that identity only when it actually admits Codex, and binds
the command, stage and receipt to the source pin. The release owner publishes and verifies this same signed runtime.

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

The installer completes device, signature and storage preflight before requesting
the installed runtime's saved quit. It admits only bundle paths resolved from the
installed runtime path, matching the IPC peer's kernel audit token,
running path and CDHash. Token-bound SIGTERM cannot target a reused PID. The same
writer-lease FD stays held through publication, direct MCP registration and
installed payload validation. Up to three verified relaunches may be retired; unsaved work,
an unknown owner or a 30-second drain timeout refuses publication without force.
Downgrades and changed signed bytes refuse installation. The installer then
updates iPad in place and reads back its identity. Unknown outcomes remain
`incomplete`; it never restores data or retries an uncertain installation.

The iPad preservation check uses its bundle domain. Before preparation, immediately
before the iPad update, and afterward, it compares the full catalog's canonical
JSON hash and IDs. Object-key order and JSON formatting are insignificant; array
order and every value remain significant. Numbers must use integer notation,
matching the current catalog format. Duplicate keys and nonfinite numbers refuse
admission. Each readback retains its raw bytes, hash and size as diagnostics.
The selected SQLite must remain a readable nonempty file.
An installed app with neither a catalog nor a store has an empty baseline. Data
without a provable catalog refuses installation. App-group IDs stay unchanged;
iPadOS container paths and SQLite/WAL sizes are diagnostic. The installer reads
only the small catalog and file metadata, never copies SQLite or archives.

`install-pair` publishes the signed runtime into
`~/Library/Application Support/NotebookRuntime/NotebookRuntime.app` and registers
its bundled Node/launcher with `codex mcp add notebook`. The publisher verifies
the staged payload before atomic replacement; changed bytes under an already
published build are refused. Installer code comes from the verified source copy.
There is one release owner and one runtime publication path.

Publication holds an OS `flock` shared with its Node adapter through an inherited
descriptor. The last process exit releases it; the next admitted attempt handles
unfinished copy stages. No persistent directory lock requires manual removal.
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
dSYM. Selected Mac unit builds retain matching host/test dSYMs in their evidence
and remove local linked symbols before the existing bundle reseal. Their dSYM
symbol tables retain one local alias per address, with DWARF bytes unchanged. External
`@testable` exports remain intact; folded typesetter aliases otherwise stall
XCTest's failure symbolication. Native unit hosts may enable testability; their timing observations are
not silently substituted for the deployed acceptance application. A strip phase
or a dSYM by itself does not establish successful profiling or UI acceptance.
