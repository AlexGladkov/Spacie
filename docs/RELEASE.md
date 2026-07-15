# Spacie — Release, Signing & Auto-Update

Spacie is distributed as a **Developer ID–signed, notarized DMG** and updates
itself in-app via **Sparkle** (appcast on GitHub Pages).

- **Signing identity:** `Developer ID Application: Alex Gladkov (7N3PU42797)`
- **Team ID:** `7N3PU42797`
- **Appcast feed:** `https://alexgladkov.github.io/Spacie/appcast.xml`
- **Sparkle EdDSA public key:** in `Spacie/Info.plist` (`SUPublicEDKey`)
- **Sparkle EdDSA private key:** login Keychain, account **`Spacie`**

---

## Why the app no longer re-asks for folder access

macOS TCC (Full Disk / folder permissions) is keyed to the app's **code-signing
designated requirement**. Previously Spacie was ad-hoc signed
(`CODE_SIGN_IDENTITY = "-"`), so every rebuild produced a *different* signature →
macOS treated it as a new app and reset the granted permissions.

Now every build (Debug and Release) is signed with the stable **Developer ID**
identity + **Hardened Runtime**, so the designated requirement is constant and
TCC keeps the grant across rebuilds.

> Requires the `Developer ID Application: Alex Gladkov (7N3PU42797)` certificate
> in the login Keychain. Other developers must either install that cert or set
> `CODE_SIGN_IDENTITY` to their own stable identity in `project.yml`.

---

## Cutting a release (automated — recommended)

1. Bump the version in `project.yml` (`MARKETING_VERSION`) and run `xcodegen generate`.
2. Commit, then tag and push:
   ```bash
   git tag v1.4.0
   git push origin v1.4.0
   ```
3. The **Release** workflow (`.github/workflows/release.yml`) then:
   builds the KMP XCFramework → archives → Developer ID signs (Sparkle-aware) →
   notarizes + staples → builds the DMG → generates the Sparkle appcast →
   publishes a **GitHub Release** with the DMG and deploys `appcast.xml` to the
   **gh-pages** branch.

### Required GitHub Secrets

| Secret | What it is |
|--------|------------|
| `APPLE_CERT_P12_BASE64`   | Developer ID Application cert + private key, exported as `.p12`, base64-encoded |
| `APPLE_CERT_PASSWORD`     | Password for that `.p12` |
| `APPLE_SIGN_IDENTITY`     | `Developer ID Application: Alex Gladkov (7N3PU42797)` |
| `APPLE_API_KEY_ID`        | App Store Connect API **Key ID** |
| `APPLE_API_ISSUER`        | App Store Connect API **Issuer UUID** |
| `APPLE_API_KEY_P8_BASE64` | The `AuthKey_XXXX.p8` file, base64-encoded |
| `SPARKLE_ED_PRIVATE_KEY`  | Spacie's Sparkle EdDSA private key (see below) |

Create each with `gh secret set NAME` or in *Settings ▸ Secrets ▸ Actions*.

#### Exporting the certificate (`.p12`)
Keychain Access ▸ right-click *Developer ID Application: Alex Gladkov* ▸ Export ▸
`.p12` with a password, then:
```bash
base64 -i DeveloperID.p12 | pbcopy      # → APPLE_CERT_P12_BASE64
```

#### App Store Connect API key (for notarization)
App Store Connect ▸ *Users and Access ▸ Integrations ▸ App Store Connect API* ▸
generate a key with **Developer** access. Download `AuthKey_XXXX.p8` (once).
```bash
base64 -i AuthKey_XXXX.p8 | pbcopy       # → APPLE_API_KEY_P8_BASE64
```
Copy the **Key ID** and **Issuer ID** from the same page.

#### Sparkle private key
```bash
# Export the private key for account "Spacie" from the login Keychain:
"$(find ~/Library/Developer/Xcode/DerivedData -name generate_keys -path '*parkle*' | head -1)" \
    --account Spacie -x spacie_sparkle_priv.pem
pbcopy < spacie_sparkle_priv.pem          # → SPARKLE_ED_PRIVATE_KEY
rm spacie_sparkle_priv.pem
```

### One-time GitHub setup
- **Settings ▸ Pages** → set source to the **`gh-pages`** branch (created on first
  release run). The appcast is served from
  `https://alexgladkov.github.io/Spacie/appcast.xml` (matches `SUFeedURL`).

---

## Cutting a release (local)

Requires the Developer ID cert in the login Keychain and (for notarization) the
notary credentials in your environment.

```bash
# Signed + DMG + appcast; notarizes only if notary creds are set in env.
./scripts/release.sh 1.4.0

# To also notarize locally, first set one credential set, e.g.:
export NOTARY_API_KEY_PATH=~/keys/AuthKey_XXXX.p8
export NOTARY_API_KEY_ID=XXXXXXXXXX
export NOTARY_API_ISSUER=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
./scripts/release.sh 1.4.0
```

Individual steps also work standalone: `scripts/codesign-app.sh`,
`scripts/create-dmg.sh`, `scripts/notarize.sh`, `scripts/generate-appcast.sh`.

---

## How auto-update works at runtime

- Sparkle config lives in `Spacie/Info.plist` (`SUFeedURL`, `SUPublicEDKey`,
  `SUEnableAutomaticChecks`, `SUScheduledCheckInterval`).
- The updater is wired in `Spacie/Core/Update/` (`UpdateService` wraps
  `SPUUpdater`); it's gated behind `#if DIRECT`, so **App Store builds
  (`APPSTORE`) use a no-op** and never bundle self-update logic.
- Users update via **Spacie ▸ Check for Updates…** (app menu) or the button in
  **Settings ▸ About**; background checks run daily.
- Each DMG is signed with the Sparkle EdDSA key; the app verifies the signature
  against `SUPublicEDKey` before installing — a hijacked download can't update.

> **App Store note:** Sparkle is currently linked unconditionally. Before an
> actual App Store submission, exclude the Sparkle package from the `APPSTORE`
> configuration (Sparkle self-update violates App Store rules).
