## Problem

<!-- What is wrong or missing? Link the issue, if there is one: Fixes #123 -->

## Solution

<!-- What does this change do, and why this way? -->

## Checks

- [ ] `swift test --package-path Packages/GhostwriterKit` passes
- [ ] The app builds (`xcodegen generate`, then `xcodebuild`)
- [ ] I tested the change in the running app, in TextEdit with a file in `/tmp`
- [ ] For changes to suggestion quality or speed: `gw-eval` numbers before and after are below
- [ ] No text that a user wrote is logged, recorded from secure fields or sent off the Mac
