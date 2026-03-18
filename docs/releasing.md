---
title: Releasing
---

# Releasing

How to publish a new MicGuard version to Homebrew.

[Home](index.md) · [CLI Reference](cli.md) · [Integrations](integrations.md) · [Notifications](notifications.md)

## 1. Tag and push

```bash
git tag v<version>
git push origin v<version>
```

GitHub Actions builds the app and creates a release with `MicGuard.zip`.

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
