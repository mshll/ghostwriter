# Releasing

For maintainers. A release is a notarized DMG on GitHub Releases, an entry in the Sparkle appcast and a new version of the Homebrew cask.

| What | Where |
|---|---|
| Appcast and DMGs for Sparkle | `gh-pages` branch, served at `https://mshll.github.io/ghostwriter/` |
| DMG for people | GitHub Releases, tag `v<version>` |
| Homebrew cask | [`mshll/homebrew-tap`](https://github.com/mshll/homebrew-tap), `Casks/ghostwriter.rb` |

## Once per Mac

- A "Developer ID Application" certificate in the login keychain
- A notarytool profile: `xcrun notarytool store-credentials ghostwriter-notary`
- The Sparkle EdDSA private key in the login keychain, account `ghostwriter`. Its public key is `SUPublicEDKey` in `Ghostwriter/Info.plist`. Without this key, existing installs reject every update, so keep a backup of it outside the Mac.

## Steps

1. Pick the version, for example `0.2.0`. Write the release notes in Markdown to `build/updates/Ghostwriter-0.2.0.md`.
2. Build, notarize and update the appcast:

   ```sh
   scripts/release.sh 0.2.0
   ```

   The script archives the app, signs it with Developer ID, notarizes and staples the app and the DMG, and runs Sparkle's `generate_appcast` over `build/updates/`. It stops if any step fails.

3. Publish `build/updates/` on `gh-pages`. Copy all of it: the appcast can point to delta files and release notes next to the DMGs.

   ```sh
   git worktree add /tmp/ghostwriter-pages gh-pages
   rsync -a build/updates/ /tmp/ghostwriter-pages/
   git -C /tmp/ghostwriter-pages add -A
   git -C /tmp/ghostwriter-pages commit -m "release 0.2.0"
   git -C /tmp/ghostwriter-pages push
   git worktree remove /tmp/ghostwriter-pages
   ```

4. Create the GitHub release:

   ```sh
   gh release create v0.2.0 build/updates/Ghostwriter-0.2.0.dmg \
     --title "Ghostwriter 0.2.0" --notes-file build/updates/Ghostwriter-0.2.0.md
   ```

5. Update the cask in `mshll/homebrew-tap`: set `version` and `sha256` (`shasum -a 256 build/updates/Ghostwriter-0.2.0.dmg`), then commit and push.
6. Check: an older install finds the update (Settings > Updates > Check Now), and `brew upgrade --cask ghostwriter` installs it.

Keep `build/updates/`. `generate_appcast` reads every DMG there to write delta updates and the full appcast.
