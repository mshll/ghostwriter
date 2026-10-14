# Releasing

A release is a notarized DMG on GitHub Releases, an appcast entry on `gh-pages` (served at `https://mshll.github.io/ghostwriter/`) and a cask update in [`mshll/homebrew-tap`](https://github.com/mshll/homebrew-tap).

## Once per Mac

- A "Developer ID Application" certificate in the login keychain
- A notarytool profile: `xcrun notarytool store-credentials ghostwriter-notary`
- The Sparkle EdDSA key in the login keychain, account `ghostwriter`. Back it up: without it, installs reject every update.
- [uv](https://docs.astral.sh/uv/), to run `dmgbuild`

## Steps

1. Write the release notes to `build/updates/Ghostwriter-<version>.md`.
2. Run `scripts/release.sh <version>`. It writes `build/release/<version>/Ghostwriter.dmg` and updates `build/updates/appcast.xml`.
3. Publish `build/updates/` on `gh-pages`:

   ```sh
   git worktree add /tmp/ghostwriter-pages gh-pages
   rsync -a build/updates/ /tmp/ghostwriter-pages/
   git -C /tmp/ghostwriter-pages add -A
   git -C /tmp/ghostwriter-pages commit -m "release <version>"
   git -C /tmp/ghostwriter-pages push
   git worktree remove /tmp/ghostwriter-pages
   ```

4. Create the release. Keep the asset named `Ghostwriter.dmg`: the website links to `releases/latest/download/Ghostwriter.dmg`.

   ```sh
   gh release create v<version> build/release/<version>/Ghostwriter.dmg \
     --title "Ghostwriter <version>" --notes-file build/updates/Ghostwriter-<version>.md
   ```

5. In the tap, set `version` and `sha256` in `Casks/ghostwriter.rb`.

Keep `build/updates/`: `generate_appcast` reads every DMG in it.

## Rebuilding a version nobody has installed

Delete `build/updates/Ghostwriter-<version>.dmg`, redo steps 2 and 3, run `gh release upload v<version> build/release/<version>/Ghostwriter.dmg --clobber`, and update the cask `sha256`.
