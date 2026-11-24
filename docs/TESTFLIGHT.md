# TestFlight (internal testing)

`.github/workflows/testflight.yml` archives a signed App Store build and uploads it to App Store Connect. The upload is marked internal-only (`testFlightInternalTestingOnly`), so:

- the build skips App Review and is available to your App Store Connect team (up to 100 internal testers);
- it **cannot** be sent to external testers or submitted to the App Store. Doing either needs a licence-clean protocol layer; see the README.

The sideload releases and AltStore source (`build.yml`) keep working alongside it.

## One-time setup

You need an active **Apple Developer Program** membership. Everything below works from a browser plus a terminal with `openssl` (macOS, Linux or WSL), so no Mac is required.

### 1. App ID and App Store Connect record

1. Open <https://developer.apple.com/account/resources/identifiers> and click **+**. Choose App IDs, then App.
   - Bundle ID (explicit): `io.github.westernpluto.shiro`.
   - If that ID is already taken by someone else, use your own, e.g. `com.yourname.shiro`. Then set a repository **variable** `BUNDLE_ID` to it (Settings › Secrets and variables › Actions › Variables).
   - No extra capabilities are required.
2. Open <https://appstoreconnect.apple.com/apps>, click **+ › New App**, choose platform iOS, name it "Shiro" (or any free name), and select the bundle ID from step 1. Any SKU works.

### 2. Distribution certificate (`.p12`)

```bash
openssl genrsa -out shiro_dist.key 2048
openssl req -new -key shiro_dist.key -out shiro_dist.csr -subj "/emailAddress=you@example.com/CN=Shiro Distribution/C=US"
```

1. Open <https://developer.apple.com/account/resources/certificates> and click **+**. Choose **Apple Distribution** and upload `shiro_dist.csr`.
2. Download `distribution.cer`, then:

```bash
openssl x509 -inform der -in distribution.cer -out distribution.pem
openssl pkcs12 -export -legacy -inkey shiro_dist.key -in distribution.pem -out shiro_dist.p12 -name "Apple Distribution"
# choose a password; you'll store it as P12_PASSWORD
base64 -i shiro_dist.p12 | tr -d '\n' > shiro_dist.p12.b64      # macOS
# base64 -w0 shiro_dist.p12 > shiro_dist.p12.b64               # Linux
```

If your `openssl` doesn't know `-legacy` (OpenSSL 1.x), drop that flag.

### 3. App Store provisioning profile

1. Open <https://developer.apple.com/account/resources/profiles> and click **+**. Under Distribution choose **App Store Connect**.
2. Select the App ID from step 1 and the certificate from step 2. Name it e.g. `Shiro App Store`.
3. Download it and encode it:

```bash
base64 -i Shiro_App_Store.mobileprovision | tr -d '\n' > profile.b64
```

### 4. App Store Connect API key

1. Open <https://appstoreconnect.apple.com/access/integrations/api> and generate a **Team Key** with the **App Manager** role.
2. Note the **Key ID** and the **Issuer ID** shown on that page, then download `AuthKey_XXXXXXXXXX.p8`. Apple only lets you download it once.

### 5. Team ID

Your Team ID is the 10-character ID at <https://developer.apple.com/account> under Membership details.

### 6. Repository secrets

In GitHub go to Settings › Secrets and variables › Actions, and add these under **Secrets**:

| Secret | Value |
|---|---|
| `BUILD_CERTIFICATE_BASE64` | contents of `shiro_dist.p12.b64` |
| `P12_PASSWORD` | the password you chose for the `.p12` |
| `BUILD_PROVISION_PROFILE_BASE64` | contents of `profile.b64` |
| `DEVELOPMENT_TEAM` | your 10-character Team ID |
| `APPSTORE_API_KEY_ID` | the Key ID |
| `APPSTORE_API_ISSUER_ID` | the Issuer ID |
| `APPSTORE_API_PRIVATE_KEY` | full text of the `.p8` file, including the `BEGIN`/`END` lines |

Delete the local key, `.p12` and `.p8` files afterwards, or store them in a password manager.

## Uploading a build

- **Actions › TestFlight (internal) › Run workflow.** Optionally set the marketing version; the default is `<VERSION>.0`, e.g. `1.0.0`.
- Or push a tag: `git tag testflight-1 && git push origin testflight-1`.

The build number is the workflow run number, so it always increases. Processing on Apple's side takes about 5–30 minutes. After that the build appears under App Store Connect › TestFlight, and members of an internal testing group get it in the TestFlight app.

## Export compliance

`Info.plist` sets `ITSAppUsesNonExemptEncryption = NO`, so builds don't wait on the export-compliance question. Shiro uses only standard algorithms: AES, ECDH, HMAC/SHA and TLS. They protect the Remote Play stream to the user's own console and authenticate with PSN. That is generally treated as exempt mass-market use. This is **your** declaration as the publisher, so review Apple's [export compliance guidance](https://developer.apple.com/documentation/security/complying-with-encryption-export-regulations) and change the key to `YES` if your situation differs.

## Privacy

`Shiro/PrivacyInfo.xcprivacy` declares no tracking and no collected data. Tokens, registrations and settings stay on the device. It also gives the required-reason APIs the app uses: UserDefaults, system boot time for frame and latency timing, and file timestamps inside the app container. In App Store Connect, answer the App Privacy questionnaire with **Data Not Collected**.
