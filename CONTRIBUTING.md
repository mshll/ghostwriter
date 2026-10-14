# Contributing to Ghostwriter

Thank you for your help. This guide tells you how to build the app, run the tests and send a change.

## Before you start

- **Bugs:** open an issue with the bug form. Include your macOS version, chip, model and the app you typed in. Settings > About Ghostwriter > Diagnostics copies these for you. Do not paste text you wrote.
- **Small fixes** (a typo, a crash, a clear bug): open a pull request.
- **Features and large changes:** open an issue first, so we can agree on the approach before you write the code.

## Set up

You need:

- A Mac with Apple silicon and macOS 26 or later
- Xcode 27
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`
- [uv](https://docs.astral.sh/uv/), only for the Python scripts in `eval/scripts/`

`project.yml` is the source of truth for the Xcode project. `Ghostwriter.xcodeproj` is generated and is not in git. Run `xcodegen generate` after you clone and after every change to `project.yml`.

```sh
xcodegen generate
xcodebuild -project Ghostwriter.xcodeproj -scheme Ghostwriter -configuration Debug \
  CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= build
```

### Signing

Ghostwriter needs Accessibility permission. macOS ties that permission to the app's signature:

- **Ad hoc** (the command above): needs no Apple account. macOS asks for Accessibility again after each build. Remove the old entry in System Settings > Privacy & Security > Accessibility if the new build does not get the permission.
- **Your Developer ID:** set `DEVELOPMENT_TEAM` in `project.yml` to your team ID. The permission then survives rebuilds. Do not commit this change.

The app is not sandboxed. Accessibility and synthetic key events do not work in the sandbox.

### Package only

Most code is in the Swift package `Packages/GhostwriterKit`. You can build and test it without Xcode project files or signing:

```sh
swift build --package-path Packages/GhostwriterKit
swift test --package-path Packages/GhostwriterKit
```

## Project layout

| Path | Contents |
|---|---|
| `Ghostwriter/App` | App entry point, services, preferences, shortcuts |
| `Ghostwriter/Coordinator` | `CompletionCoordinator`: connects focus, prompt, engine, overlay and input |
| `Ghostwriter/MenuBar`, `Settings`, `Onboarding` | The menu bar item, the Settings window and the first-launch guide |
| `Ghostwriter/SelectionActions` | The panel for actions on selected text |
| `Ghostwriter/Stores` | App-side stores, such as per-app rules |
| `Packages/GhostwriterKit/Sources/GWCore` | Shared value types, paths, logging, `EventMarker` |
| `…/Inference` | llama.cpp wrapper, completion engine (beam search, KV cache reuse), model catalog, downloads |
| `…/Prompting` | Prompt builder, section budgets, language and field-kind detection |
| `…/Memory` | SQLite store (GRDB): recorded writing with full-text retrieval, statistics, snippets, app rules |
| `…/Capture` | Accessibility focus tracking, text around the caret, caret position and font |
| `…/Input` | Key monitoring, global shortcuts, text insertion |
| `…/Overlay` | The ghost-text panel, multi-line drafts, the picker |
| `…/ScreenContext` | Window text near the caret, text recognition from screenshots, clipboard |
| `…/Actions` | Actions on selected text, the proofread edit and undo, snippet expansion |
| `…/Proofing` | Typo detection with the system spell checker, the model judge that confirms fixes, sentence checks |
| `…/gw-eval` | Command-line quality and latency evaluation ([docs/EVALUATION.md](docs/EVALUATION.md)) |
| `…/gw-axprobe`, `gw-inputprobe`, `gw-ctxprobe` | Developer probes for Capture, Input and Overlay, and ScreenContext |
| `eval/` | The held-out evaluation set and the scripts that build and compare the others |
| `scripts/release.sh` | Archive, notarize, build the DMG, update the appcast ([docs/RELEASING.md](docs/RELEASING.md)) |
| `docs/` | How the engine works ([ENGINE.md](docs/ENGINE.md)), how the models were chosen ([MODELS.md](docs/MODELS.md)) |

## Rules

These rules protect the user's privacy and keep the app fast. Pull requests that break them are not merged.

**Privacy**

- Nothing leaves the Mac, except model downloads from Hugging Face and update checks. No cloud APIs, no telemetry, no analytics.
- Never record text from secure fields, password managers or apps the user excluded.
- Never log text the user wrote. This includes debug logs.

**Behavior**

- Autocomplete uses base (pretrained) models with a plain-text continuation prompt. Do not add chat templates or instruct models.
- Every synthetic event that Ghostwriter posts carries the `EventMarker` tag. Ghostwriter never acts on events that carry it.
- Claims about suggestion quality or speed come from `gw-eval` numbers, not from a few examples you read. Put the numbers before and after your change in the pull request.

**Code**

- Swift 6 with strict concurrency. The app target uses `MainActor` as its default isolation. Package targets state their isolation explicitly.
- Every `catch` handles, logs or rethrows the error.
- No force-unwraps on Accessibility (`AX…`) or Core Foundation results. Apps return unexpected values.
- Match the style of the code around your change. Prefer clear names to comments. Write a comment only to explain a decision that looks wrong, or a trap.
- Add tests for behavior you add or fix. Tests are in `Packages/GhostwriterKit/Tests` and use Swift Testing.

## Test in the running app

The app types into other apps, so test it with care:

- Test in TextEdit with a file in `/tmp`: `open -a TextEdit /tmp/test.txt`. Never test in messaging apps, Mail or your own documents.
- Ghostwriter records what you type as writing examples. Quit the app and copy `~/Library/Application Support/com.mshl.ghostwriter/ghostwriter.sqlite` before a test session, then put the copy back after it.
- Turn off other apps that use Tab or draw over text fields while you test.

## Send a pull request

1. Fork the repository and create a branch from `main`.
2. Make one logical change. Keep unrelated cleanup for a separate pull request.
3. Run `swift test --package-path Packages/GhostwriterKit` and build the app.
4. Write commit messages in the [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/) format, for example `fix(overlay): keep ghost text aligned in right-to-left fields`. Use the module or area as the scope.
5. Open the pull request and complete the template.

By contributing, you agree that your contributions are licensed under the [GPL-3.0](LICENSE).
