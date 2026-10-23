# Uploading to TestFlight from GitHub Actions

The **TestFlight** workflow (`.github/workflows/testflight.yml`) archives the iPhone app on a GitHub macOS runner, signs it with Apple's cloud-managed distribution certificate and uploads it to App Store Connect. No certificates or provisioning profiles are stored in GitHub; only an App Store Connect API key is.

## One-time setup

### 1. Create an App Store Connect API key

1. In App Store Connect, go to **Users and Access › Integrations › App Store Connect API › Team Keys**.
2. Click **+**, name it `GitHub Actions` and give it the **Admin** role.
   - Admin is required: signing with cloud-managed certificates needs it.
3. Note the **Issuer ID**, shown above the key list, and the key's **Key ID**.
4. Click **Download** to get `AuthKey_<KeyID>.p8`. Apple lets you download it only once, so keep it somewhere safe.

### 2. Add three repository secrets

Under **GitHub › petervanmanen/fitmovie › Settings › Secrets and variables › Actions**, add:

| Secret | Value |
|---|---|
| `ASC_KEY_ID` | the Key ID, e.g. `ABC123DEFG` |
| `ASC_ISSUER_ID` | the Issuer ID (a UUID) |
| `ASC_API_KEY_P8` | the full contents of the `.p8` file, including the `BEGIN`/`END` lines |

Or use the GitHub CLI from the folder that holds the key:

```bash
gh secret set ASC_KEY_ID --repo petervanmanen/fitmovie
gh secret set ASC_ISSUER_ID --repo petervanmanen/fitmovie
gh secret set ASC_API_KEY_P8 --repo petervanmanen/fitmovie < AuthKey_ABC123DEFG.p8
```

The first two commands prompt for the value.

## Running it

- **By hand:** GitHub › Actions › **TestFlight** › **Run workflow**. This uploads the current `main` with the version from the Xcode project (1.0).
- **For a release:** push a tag. The tag sets the version (`v1.0.1` becomes version 1.0.1):

  ```bash
  git tag v1.0.1 && git push origin v1.0.1
  ```

The **Build** workflow also creates a GitHub release with the Mac app when a tag is pushed.

## Build numbers

Each run uploads build number `100 + run number` (101, 102, …), so it can never clash with build 1, which was uploaded from Xcode. If you upload from Xcode again, use a build number below 100 or above the latest CI build.

## After the upload

Apple processes the build for about 10–30 minutes and then emails you. It then appears under **TestFlight**:
- Internal testers can install it right away.
- External testers need a short beta review the first time.
- To release a build on the App Store, select it under **Build** on the app version page and submit it for review.

## Troubleshooting

- **"Missing secrets":** one of the three secrets isn't set, or is misspelled.
- **Authentication or "not allowed" errors:** the key needs the **Admin** role, and its Issuer ID has to belong to the same team (`9XCZUWMGXB`).
- **"The bundle version must be higher":** a build with that number already exists. Re-run the workflow; each run uses a new number.
- **"App record not found":** the app record for `nl.petervanmanen.fitmovie` must exist in App Store Connect. It already does.
