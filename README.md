# PoTATo Agent CLI

`potato-cli` is a standalone PowerShell command-line interface for agent-driven Windows UI automation. It is intentionally smaller than the original PoTATo project: it keeps the UI Automation, window, selector, input, screenshot, report, log, and state primitives needed to build repeatable GUI tests for Office and Nucleus-style desktop applications.

It does not import the old `Potato` module and does not include legacy testcases, browser automation, Selenium, image recognition, OCR, Jira integration, VM tooling, or application-specific cleanup helpers.

Current reliability defaults: literal input uses a 5 ms delay per Unicode scalar, checking native focus while sending. `-InputDelayMs 0` explicitly requests bursts; `-TypeByCharacter` retains the legacy 50 ms delay. Use readback to verify content and preserve tested pacing in generated scripts. Filtered selector misses inside an application subtree now use the bounded child traversal used by observation; `SearchIncomplete` requires a narrower scope.

The CLI explicitly registers Windows' standard UI Automation providers. Native dropdowns, edit fields and menus can then expose their actual roles and supported actions instead of falling back to opaque Panes. Expand a dropdown with `click -Method Auto`, observe its named choices, and select the observed item; avoid guessed arrow counts. Discovery removes repeated references to the same UIA runtime identity, while distinct controls with identical labels remain ambiguous.

`click -Method Auto` uses selector-based physical input for native push buttons. Their UIA Invoke provider can send synchronous `BM_CLICK`, causing COM error `0x8001010D` in file dialogs. This rule uses the observed button role and native handle, never an application/button name. Dropdowns, menu items and windowless controls retain supported semantic actions. Existing scripts using explicit `-Method Invoke` on such buttons should use Auto or Mouse; after an application error, inspect the dialog and output before retrying.

`press-key` sends guarded native keyboard events rather than waiting in SendKeys. Repeated navigation stops when the foreground window changes; repeated arrows also stop if the native focus target changes. Observe the result before continuing. Guarded foreground observations report keyboard readiness relative to that dialog, without adopting its process.

For an observed system-hosted dialog, `-Scope ForegroundWindow -WindowSelectorJson '{"Name":"<exact title>","ClassName":"<exact class>"}'` with fallback reason/evidence permits observation, selector clicks, type and press-key without adopting the host process. Focused input also requires ExpectedFocusJson. It grants no cleanup ownership. Use windows -Foreground to obtain the observed identity without guessing. Scoped waits tolerate a foreground/owner transition; use `-InteractiveOnly` to wait for an enabled visible submit control, then verify the next dialog instead of repeating a blind click.

For shared application hosts, `start -RequireNewWindow` (the framework default) waits for a new visible window without demanding a new process. Cleanup uses an `ownedWindow` receipt with process identity and a window-lifetime token, preserving preexisting windows and the host. For a GUI action that opens another app, use `windows -Checkpoint` before the action and `focus -SinceCheckpoint <checkpointId>` with the observed new window selector afterwards. Plain `focus` switches windows without claiming cleanup ownership. `close-window -WindowIdentityJson <ownedWindow JSON>` closes only that window; `windows` accepts the same receipt to verify closure.

Filename entry with `type -PathKind SaveFile|OpenFile|Directory` now defaults to exact readback. Standard Windows Edit fields support readback and text selection even without UIA patterns (`read` reports `textSource: Win32Edit`). `PreDelete` can use that selection in Focused mode too. All text is still sent as keyboard input; no clipboard or direct text setter is used.

## Requirements

- Windows with an interactive desktop session.
- Windows 10 version 1607 or newer for thread-scoped DPI handling.
- Windows PowerShell 5.1 or later.
- The target application must be visible in the logged-in user session.
- Run from a normal or elevated PowerShell session depending on the target application. UI Automation is most reliable when the CLI and target application run at the same integrity level.

## Entry Point

```powershell
cd C:\diplomamunka\potato-cli
.\potato.ps1 <command> [parameters]
```

Example:

```powershell
.\potato.ps1 start -ProcessName winword -Maximize
.\potato.ps1 observe -Depth 2 -MaxElements 120
```

For agent discovery, use `observe -Format Compact -Depth 3 -MaxElements 80`: it returns a flat list with observed names/IDs, patterns, focus, live bounds and candidate selectors. `observe -Scope FocusedWindow` targets the owned foreground dialog; `select`, `read`, `click` and selector-based `type` support the same scope. It does not activate another application or rely on a dialog reporting UIA IsModal. Check selector uniqueness; avoid pinning a temporary opaque `Pane` role into generated code. Prefer click's default `Auto` method.

Read several needed topics in one call: `help -Topics start,observe,click,type,press-key`. For alternative discovery labels, use `select -SelectorJson '{"Name":["Save","Browse"]}' -TimeoutMs 0`. Use timed waits for expected transitions rather than repeated guesses. The framework's exploration Batch entrypoint records receipts and saves session configuration; its default compact output removes repeated envelope metadata while keeping full command envelopes on disk.

Click now requires one visible enabled match by default. `AmbiguousTarget` returns candidates before any input, so a navigation item and submit button with the same name cannot silently substitute for each other. Add an observed role, class, ID or parent scope. Existing scripts with intentionally ambiguous selectors can explicitly request `-RequireUnique false` for legacy first-match behavior. Compact candidates include class names and distinguish duplicate labels where the returned tree provides enough information.

For an observed opaque field already in focus, `type -TargetMode Focused -ExpectedFocusJson '{"AutomationId":"<observed-id>"}' -FocusTimeoutMs 2000` waits for that owned focus without clicking or changing its existing text selection. Fallback reason/evidence remain required. Prefer writable `type -PreDelete -Verify` for replacement when text patterns are available. `read` reports `data.textSource` so content assertions can distinguish actual text from an accessible name fallback.

For GUI filenames, add `-PathKind SaveFile`, `OpenFile`, or `Directory` to `type -Text <full-absolute-path>`. This checks the existing parent/file/directory before changing focus or sending input. Invalid paths return `PathValidationFailed` with `outcome: not-dispatched`; no output file or directory is created. The literal text is preserved, including spaces, Unicode and brackets. The check does not prove UI readback or a successful save: use `-Verify` when available and assert the resulting file after saving through the GUI. Framework exploration Begin now returns an existing `explorationEvidenceRoot`; generated execution uses `Context.ExecutionEvidenceRoot`.

Focused typing and `press-key` now corroborate the keyboard target using Windows' foreground thread. Custom canvases may return a UIA FocusedElement whose HasKeyboardFocus is false; that inconsistency alone no longer blocks input. Ownership, native focus, enabled state and focus changes remain checked. No writable selector is needed for `type -TargetMode Focused`. It waits up to `FocusTimeoutMs` (default 2000), without changing focus or selection, and returns `data.inputFocus`. Optional `ExpectedFocusJson` narrows the existing target to an observed identity. `observe.keyboardFocus` and focus-error diagnostics expose native readiness separately from UIA flags. Literal single-line and explicit read-only checks remain; input dispatch is not a content assertion.

Semantic clicks avoid implicit parent/element refocusing, preserving open popups. Mouse fallback activates an unrelated target window when needed. Click uniqueness and visibility are still checked locally when a provider's compound query is unreliable. Native `close-window` queues a normal window-close request and preserves context for confirmation prompts; verify actual exit separately. `read-pdf -TimeoutMs 5000` handles transient locks internally, and its built-in shared snapshot can read completed output while the producer retains a cooperating write handle.

Desktop commands now use physical screen pixels consistently for UIA bounds, mouse input and screenshots, restoring the embedding caller's thread DPI setting after each command. Screenshot dimensions do not depend on WinForms' cached scaled bounds. Old coordinates recorded under a virtualized process must be rediscovered; element-relative clicks remain preferable. Screenshot `region.x/y` gives the origin of its image pixels. Inspect the full-resolution image before choosing fallback points. A `depthBoundaryReached` observation is incomplete below that boundary; try targeted deeper discovery or a short label-fragment search before declaring a control inaccessible.

`wait-element -Scope FocusedWindow -ControlType Window -Name '<observed dialog>'` now matches the dialog itself while remaining restricted to the owned foreground scope.

## JSON Contract

Every command writes exactly one compact JSON object to stdout.

```json
{
  "ok": true,
  "command": "observe",
  "session": {
    "statePath": "C:\\diplomamunka\\potato-cli\\.state\\default.json",
    "runId": "...",
    "working": {}
  },
  "data": {},
  "error": null,
  "durationMs": 123,
  "logPath": "C:\\diplomamunka\\potato-cli\\runs\\...\\potato.log"
}
```

Agents and scripts should parse stdout as JSON and treat `ok: false` as a command failure. The script entrypoint now also exits 1 on these failures, including help errors. Combined help preserves valid requested topics when another is unknown, alongside `unknownTopics` and `availableTopics`. Human-readable logs are written separately.

## Runtime Files

The CLI creates runtime state and evidence below `potato-cli`:

- `.state\default.json` stores the current run ID and working window context.
- `runs\<runId>\potato.log` stores command logs as JSON lines.
- `runs\<runId>\metrics.jsonl` stores command timing metrics.
- `runs\<runId>\reports.jsonl` stores explicit `report` events.
- `runs\<runId>\screenshots\` stores screenshots.

These paths are runtime output and should not be committed.

## Commands

Run `potato.ps1 help` for JSON command guidance, or `potato.ps1 help -Topic type` for one command. Help needs no desktop and does not change session state. Consult it before reading implementation source.

| Command | Purpose |
| --- | --- |
| `help` | Read command usage, selector options, and result semantics. |
| `state` | Show current session state. Use `-Clear` to reset it. |
| `start` | Start a process and set its first window as the working window. |
| `focus` | Find and focus an existing top-level window. |
| `windows` | List top-level windows. |
| `observe` | Return working window, foreground element, top-level windows, likely blocking dialogs, and a bounded UI tree. |
| `select` | Find UI elements by selector. |
| `click` | Click or invoke a selected element. |
| `click-coordinate` | Click absolute screen coordinates. Use only as a documented fallback. |
| `type` | Type text into the currently focused control. |
| `hotkey` | Send one explicitly authorized chord; blocked by default. |
| `press-key` | Bounded, audited navigation with confirmed foreground focus. |
| `drag` | Press, move, and drop between live element selectors or coordinates. |
| `hover` | Move the mouse over an element or coordinate. |
| `wait-element` | Wait for an element selector to appear. |
| `wait-file` | Wait for a file to appear or disappear. |
| `read` | Read text/name/value from an element. |
| `read-pdf` | Read text from a local PDF without external dependencies. |
| `screenshot` | Save a full-screen, region, or element screenshot. |
| `close-window` | Close matching top-level windows, or the current working window. |
| `report` | Append a local JSONL report event, optionally with a screenshot. |

## Selectors

Most element commands accept the same selector flags:

```powershell
-Name <text-or-pattern>
-AutomationId <id>
-ClassName <class>
-Class <class>
-ControlType <type>
-ProcessName <process>
-WindowTitle <title>
-Regex
-Recurse <true|false>
-FindFirst
-TimeoutMs <milliseconds>
```

Matching is case-insensitive by default. `-Regex` switches string matching to regular expressions. Without `-Regex`, wildcard characters such as `*` and `?` are accepted through PowerShell wildcard matching.

Examples:

```powershell
.\potato.ps1 select -Name "Blank document" -ControlType Button -FindFirst
.\potato.ps1 click -AutomationId FileTabButton -ControlType Button -TimeoutMs 5000
.\potato.ps1 wait-element -Name "Save As" -ControlType Window -TimeoutMs 10000
```

## Nested Selectors

Use `-PathJson` or `-SelectorJson` when a target is easier to describe as a path through the UI tree. Each path item is resolved under the previous item, so this replaces old in-memory chained element workflows.

```powershell
$path = @(
    @{ Name = "File"; ControlType = "TabItem"; FindFirst = $true; TimeoutMs = 3000 },
    @{ Name = "Save As"; ControlType = "ListItem"; FindFirst = $true; TimeoutMs = 3000 }
) | ConvertTo-Json -Compress

.\potato.ps1 click -PathJson $path
```

`-SelectorJson` may also be a single selector object, a selector path array, or an object containing `path` and `target`.

## Common Workflows

Start Word, inspect the UI, create a blank document, type text, save evidence, and close:

```powershell
.\potato.ps1 state -Clear
.\potato.ps1 start -ProcessName winword -Maximize
.\potato.ps1 observe -Depth 2 -MaxElements 150
.\potato.ps1 click -Name "Blank document" -ControlType Button -TimeoutMs 10000
.\potato.ps1 type -Text "PoTATo smoke test"
.\potato.ps1 screenshot
.\potato.ps1 report -Step 1 -Status PASS -Description "Created and typed into a Word document." -Screenshot
.\potato.ps1 close-window
```

Focus an existing app:

```powershell
.\potato.ps1 focus -ProcessName WINWORD -WindowTitle "*Word*" -Maximize
```

Wait for a saved file:

```powershell
.\potato.ps1 wait-file -Path "C:\Temp\PoTAToSmoke.docx" -TimeoutMs 15000
```

## Reading PDF text

```powershell
.\potato.ps1 read-pdf -Path 'C:\Temp\ExcelTest.pdf'
# The command's JSON response contains data.path and data.text.

Import-Module .\PoTAToCli\PoTAToCli.psm1
Read-PotatoPdfText -Path 'C:\Temp\ExcelTest.pdf' # Returns a plain string.
```

This small reader uses only PowerShell and built-in .NET. It handles simple text
PDFs such as Microsoft Print to PDF and Edge output: ordinary PDF objects, direct
stream lengths, plain/FlateDecode streams, and fonts with one/two-byte ToUnicode
maps. Text follows drawing order; whitespace is approximate and tables/layout are
not reconstructed. It does not support scanned PDFs/OCR, encryption, object/xref
streams, incremental updates, or Form XObjects. Unsupported input or a PDF with
no extractable text fails clearly. `read-pdf` needs no desktop, takes no desktop
lock, and does not read or change CLI session state. PDF contents are returned as
data and never executed.

Run `tests\Pdf.Tests.ps1` for dependency-free regression checks; optionally pass
`-SampleDirectory 'C:\Users\you\Downloads'` to check the six supplied sample names.

## Agent Guidance

- Preserve the interaction requirements of the user/testcase. A fallback explanation does not authorize a prohibited shortcut, clipboard operation, or bypass of a required GUI route.
- Run commands against one desktop sequentially. A screenshot run concurrently with typing cannot prove the resulting state.
- `ok` means command execution succeeded. Check `exists`/`conditionMet` and assert the actual application result separately. `verified` is `null` unless verification was requested.
- `type` sends literal Unicode keyboard events, including text that resembles shortcut syntax. Use `hotkey` for explicitly permitted key expressions. With an explicit selector, `-FocusMethod Auto` tries UIA focus and falls back to a visible mouse click only when focus is unconfirmed; it verifies the target before typing. Use `-FocusMethod Mouse` to request visible click focus directly. `type -Verify` polls read-only UIA text for up to 3000 ms by default and never retypes. `-VerifyMode NormalizedExact|NormalizedContains` handles line-ending differences. `-TimeoutMs` bounds target discovery; `-VerifyTimeoutMs` bounds readback. `-PreDelete` defaults to TextPattern or standard Windows Edit selection plus keyboard Backspace; `-ClearMethod Shortcut` explicitly opts into Ctrl+A. Unsupported selection/verification fails clearly.
- Use the default `click -Method Auto` unless a method is required. Native push buttons use physical input; other controls use a supported UIA action, then mouse fallback. `-Method Mouse` uses live control geometry; explicit `-Method Invoke` requires InvokePattern but can cause input-synchronous call errors in native submit handlers. Capture/observe the postcondition before retrying a potentially completed action.
- Use `wait-file -Path <unique-execution-output> -MinBytes 1 -StableMs 500 -TimeoutMs 10000` for asynchronous files, then check required format/content. A stale file or a stable but invalid file is not a passing result.
- `TimeoutMs` is a retry deadline, not a hard cancellation of a blocked UIA provider call. Exact selector predicates are pushed to the provider, but provider hangs still require external process supervision.

- Prefer selector-based `click`, `select`, `wait-element`, and `read` over coordinates.
- Use bounded `observe` for unknown states; reuse discoveries and use targeted select/read/wait for known postconditions.
- VisibleControls blocks hotkey (including dialog Enter) and Shortcut clearing. Only an explicit user/testcase allowance permits AllowShortcuts, with FallbackReason and FallbackEvidence for every shortcut. Clipboard is unsupported.
- Use `click-coordinate` only as a fallback. Record a screenshot and explain why selector-based automation was not possible.
- Reset state with `state -Clear` at the start of repeatable test scripts.
- Close applications and delete created test files at the end of generated scripts so the test can run again after a VM checkpoint reset or normal rerun.
- Treat `ok: false` as a real failure and include the command JSON in generated test evidence.

## Troubleshooting

- If `start` succeeds but `windowFound` is false, increase `-WaitForWindowMs` or focus the app later with `focus`. A visible window does not mean its next control is ready. `wait-element -ControlType Window` includes the working window itself; check `data.exists`. `start -RequireNewProcess` briefly waits for a prior instance to exit (`-WaitForPreviousExitMs`, default 3000) and returns an owned PID for scoped cleanup.
- If selectors time out, first run a bounded `observe` and inspect `name`, `automationId`, `className`, and `controlType`.
- If a click does nothing, try `-Center true` or inspect `supportedPatterns` from `select`/`observe`.
- If UI Automation cannot see elevated windows, run PowerShell with the same elevation level as the target application.
- If output is not valid JSON, the command has been wrapped by something that writes extra stdout. Run `potato.ps1` directly and keep diagnostic output in logs, not stdout.

## Regression checks

Run `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\Regression.Tests.ps1`. The checks use temporary files and process mocks; they do not start or close user applications. Test both Windows PowerShell 5.1 and PowerShell 7 when changing argument binding or shared helpers.

## Policy, transport, and discovery

Every command defaults to `-InteractionPolicy GuiNavigation`. Preserve an explicitly requested `VisibleControls` policy, which also rejects navigation keys. Ordinary `type` is literal, never clipboard-based, and checks writability and actual focus in the working application or its owned dialog. For an observed opaque editor, use `-TargetMode Focused -FallbackReason <reason> -FallbackEvidence <reference>` after visibly focusing it. This explicit fallback cannot refocus, clear text, override reported read-only state, or embed Enter/Tab. It records the actual target and requires a separate expected-result assertion.

`press-key -Key Tab|ShiftTab|Enter|Escape|Left|Right|Up|Down` sends bounded navigation under GuiNavigation with reason/evidence. Enter/Escape are single actions, followed by observation. Required menu/button routes still apply. `hotkey` and Shortcut clearing remain blocked unless AllowShortcuts is explicitly authorized. Clipboard is unsupported. A failed selector never authorizes object models, direct expected-output creation, or bypassing the GUI.

For controls that update their value only on commit, type once, commit through an observed visible control or permitted Enter, then read/assert. Immediate `type -Verify` does not commit or retype.

### Relative clicks and drag-and-drop

```powershell
.\potato.ps1 click -Name 'Observed canvas' -RelativeX 0.25 -RelativeY 0.5
.\potato.ps1 drag -SourceSelectorJson '{"Name":"Observed source"}' -TargetSelectorJson '{"Name":"Observed destination"}' -DurationMs 350
# Coordinate endpoints remain available for screenshot-grounded fallbacks:
.\potato.ps1 drag -StartX 100 -StartY 100 -EndX 200 -EndY 200
```

Relative coordinates are fractions inside current element bounds. Drag endpoints also accept SourceRelativeX/Y and TargetRelativeX/Y (center by default), and nested selector paths. Both endpoints are resolved before pressing the mouse. Movement is smooth by default; the left button is released in a finally block even on failure. `dragged`/`released` report input delivery; assert the application's actual drop result separately.

The stream stops at the first failed command by default. Use `-ContinueOnError` only with an interactive caller that reads and reconciles each response before sending more actions.

For PDF layouts unsupported by the dependency-free reader, configure `POTATO_PDF_PYTHON` or pass `read-pdf -Reader Auto -PythonPath <python.exe>`. That installed Python must contain pypdf. The shipped helper only reads the file, avoids inline-code quoting, and records the chosen reader in the result. No dependency is downloaded automatically.

`select`/`observe` preserve identity and patterns when an element has empty/invalid bounds, returning `boundingRectangle:null`, `boundsStatus`, and `propertyErrors`. Physical input and element screenshots require valid geometry; UIA reads/Invoke do not. `-ProcessId` scopes selectors and `-ModalOnly` limits matches to modal descendants. `start` only accepts executable launches; `-RequireNewProcess` rejects instances still running after its bounded wait.

Commands acquire a desktop-session mutex before loading state and release it after recording results. `-LeaseTimeoutMs` defaults to 15000 so a bounded UIA query can finish before another command reports DesktopBusy; callers should still issue desktop actions sequentially. State is replaced atomically. Logging errors become structured command failures. `outcome:unknown` after a potentially dispatched failure requires observing state before retrying; UIA provider calls still need external supervision if they hang. The mutex serializes commands, not whole multi-command workflows.

For a reusable backend, import `PoTAToCli/PoTAToCli.psm1` once and call `Invoke-PotatoCliCommand -Command ... -Arguments @(...) -AsObject`. This executes the identical dispatcher and policy checks without subprocess startup or JSON parsing. Shell callers still receive one JSON object. `durationMs`, `leaseWaitMs`, and `totalDurationMs` separate backend work and lock/dispatch overhead.

For interactive exploration with a clean, non-echoing stdin/stdout session, launch `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\potato-stream.ps1` once. Send one JSON object per line, for example `{"requestId":"step-1","command":"select","arguments":["-Name","Open","-MaxResults","5"]}`. Each line returns one ordinary CLI JSON response with the matching `requestId`; `{"command":"quit"}` or EOF ends the stream. Send the next desktop command only after reading the prior response. A one-shot pipeline of several already-known sequential commands also works. This reuses the imported module and avoids a PowerShell startup for every query. Use `potato.ps1` when the shell only offers an echoing terminal or cannot keep clean pipes open.

Additional checks: `tests/Interaction.Tests.ps1` covers policy bypass attempts, partial UIA metadata, focus guards, and concurrency without typing into user applications.

Unicode keyboard input avoids keyboard-layout substitutions and sends text in bounded batches. Verification is read-only and never automatically retypes. `tests/Gui.Smoke.Tests.ps1` opens an isolated test form to verify literal Unicode input, TextPattern replacement, a visible Save action, output content, and scoped closure.

For dialogs, `windows -ProcessId` includes nested modal Window controls when UIA exposes them. `close-window -ProcessId` closes modal dialogs before the parent. A stale working window does not restrict `-ModalOnly` queries to its subtree.
