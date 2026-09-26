# Verified pair builds

`Applications/notebook_release.py` owns build-input inventories, evidence
validation and signature checks. `verify.sh`, the first-Lab installer and the
pair builder share this implementation.

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

`verification.json` is written only after success and binds immutable sources to
the complete evidence directory. The full route includes both xcresults, logs and
the Mac workspace image. `./verify.sh:selected` includes `selection.json`,
executed commands and the affected platforms' xcresults. Every requested XCTest
must actually run. Historical reports cannot become receipts retroactively.

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
and builds Release iPad, then Mac. Xcode, Swift, SDK, XcodeGen, Node and npm must
match verification and remain unchanged.

Both apps require genuine Apple Development signatures from team `M94V58FCVP`,
matching pair versions and exact bundle identities:

- iPad: `com.amirtlinov.notebook.preview`, its existing Keychain group and a profile
  admitting the certificate and designated physical device.
- Mac: `com.amirtlinov.notebook.mac`, arm64 and the bundled MCP server.
  It is a normal Dock/window application; closing the window leaves storage,
  transport and MCP alive.

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

`bundle_notebook_typesetter.py` copies only declared, hash-checked resources.
Release validates the inventory in both apps. `--check` neither downloads nor
builds. TypeScript uses its separate signed child of the markup XPC service and
inherits its sandbox. The current print route has no native TeX/image helper.

## Build versus installation

A `build.json` with `verified-build` records signatures, binary UUIDs and bundle
inventories. It proves the build, not permission or completion of installation.
The builder does not copy user archives, launch, install, delete, force a failed
check or reuse an old attempt. The first-Lab installer still rejects an existing
Lab, including with `--build`.

Ordinary in-place updates preserve containers, identities and keys.
Historical archive conversion is a separate explicitly authorized operation, not
a prerequisite to each release. Use current installation tooling and live
readback; see [verification](verification.md) for the last installed pair.

## Isolated acceptance

`Applications/notebook_acceptance.py` builds separate Release
`NotebookAcceptance` and `NotebookMacAcceptance` targets. The iPad acceptance app
uses `.acceptance` in the selected Simulator; Mac uses
`.acceptance.<12-hex SHA-256 of canonical checkout path>`. Each checkout has its
own app/UI-runner identity. The driver locks a particular Mac bundle or Simulator
UDID; independent destinations/derived data can run separately. It has no physical
device install command.

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
