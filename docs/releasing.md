---
title: Releasing
---

# Releasing

How to publish a new MicGuard version to Homebrew.

[Home](index.md) · [CLI Reference](cli.md) · [Debugging](debugging.md) · [Integrations](integrations.md) · [Notifications](notifications.md)

## Versioning

The app version is derived from the latest git tag at build time. `scripts/bundle.sh` runs `git describe --tags` and stamps the result into `Info.plist` via `PlistBuddy`. The source `Info.plist` contains a `0.0.0-dev` placeholder — do not hardcode a version there.

## Prerequisites

The release workflow needs these one-time-setup repo secrets:

- `BUILD_CERTIFICATE_BASE64` - base64 of the Developer ID Application `.p12`
- `P12_PASSWORD` - password protecting the `.p12`
- `KEYCHAIN_PASSWORD` - random string for the temporary runner keychain
- `SIGNING_IDENTITY` - `Developer ID Application: <Name> (<TEAMID>)`
- `APP_STORE_CONNECT_KEY_BASE64` - base64 of the `.p8` App Store Connect API key
- `APP_STORE_CONNECT_KEY_ID` - 10-char Key ID
- `APP_STORE_CONNECT_ISSUER` - issuer UUID

Plus a GitHub Environment named `release` with required reviewer set to the repo owner. The workflow binds the build job to this environment, so a tag push pauses for manual approval before any signing material is decrypted on the runner.

## 1. Tag and push

```bash
git tag v<version>
git push origin v<version>
```

The `Release` workflow starts and pauses on the `release` environment, waiting for approval.

## 2. Approve the deployment

Open the workflow run on GitHub. The `build` job will be in `Waiting` state with a `Review deployments` button. Click it, select `release`, and approve. The job then imports the certificate, builds, signs, notarizes, staples, verifies, and publishes the release with `MicGuard.zip`.

## 3. Get the SHA-256

Once the release is published, compute the checksum:

```bash
curl -sL https://github.com/pszypowicz/MicGuard/releases/download/v<version>/MicGuard.zip | shasum -a 256
```

## 4. Update the Homebrew cask

In the [`homebrew-tap`](https://github.com/pszypowicz/homebrew-tap) repo, edit `Casks/mic-guard.rb`:

```ruby
cask "mic-guard" do
  version "<version>"
  sha256 "<sha256 from step 3>"

  url "https://github.com/pszypowicz/MicGuard/releases/download/v#{version}/MicGuard.zip"
  # ...
end
```

Update both the `version` and `sha256` fields, then commit and push.

## 5. Verify

```bash
brew update
brew upgrade mic-guard
```

## Local release (fallback)

If the CI path is broken or you want to release from your Mac, use [`scripts/release-notarize.sh`](https://github.com/pszypowicz/MicGuard/blob/main/scripts/release-notarize.sh). One-time setup:

```bash
xcrun notarytool store-credentials MicGuard \
    --key /path/to/AuthKey_XXXXXXXXXX.p8 \
    --key-id XXXXXXXXXX \
    --issuer YYYYYYYY-YYYY-YYYY-YYYY-YYYYYYYYYYYY
```

Per-release:

```bash
SIGNING_IDENTITY='Developer ID Application: <Name> (<TEAMID>)' \
  ENTITLEMENTS=Resources/MicGuard.entitlements \
  make zip
scripts/release-notarize.sh --keychain-profile MicGuard
gh release create v<version> .build/MicGuard.zip --generate-notes
```
