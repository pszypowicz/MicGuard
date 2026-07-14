---
title: Releasing
---

# Releasing

How to publish a new MicGuard version to Homebrew.

[Home](index.md) · [CLI Reference](cli.md) · [Debugging](debugging.md) · [Integrations](integrations.md) · [Notifications](notifications.md)

## Versioning

The app version is derived from the latest git tag at build time. `scripts/bundle.sh` runs `git describe --tags` and stamps the result into `Info.plist` via `PlistBuddy`. The source `Info.plist` contains a `0.0.0-dev` placeholder - do not hardcode a version there.

## Signing

Release builds are ad-hoc signed (`codesign --sign -` in `scripts/bundle.sh`) by design. Distribution happens through the Homebrew cask, whose postflight clears the quarantine flag on install, so users never hit the Gatekeeper block that ad-hoc signatures would otherwise trigger.

## 1. Tag and push

```bash
git tag v<version>
git push origin v<version>
```

GitHub Actions builds the app and creates a release with `MicGuard.zip`. The tag determines the version embedded in the built app.

## 2. Get the SHA-256

Once the release is published, compute the checksum:

```bash
curl -sL https://github.com/pszypowicz/MicGuard/releases/download/v<version>/MicGuard.zip | shasum -a 256
```

## 3. Update the Homebrew cask

In the [`homebrew-tap`](https://github.com/pszypowicz/homebrew-tap) repo, edit `Casks/mic-guard.rb`:

```ruby
cask "mic-guard" do
  version "<version>"
  sha256 "<sha256 from step 2>"

  url "https://github.com/pszypowicz/MicGuard/releases/download/v#{version}/MicGuard.zip"
  # ...
end
```

Update both the `version` and `sha256` fields, then commit and push.

## 4. Verify

```bash
brew update
brew upgrade mic-guard
```
