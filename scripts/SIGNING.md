# One-time signing setup (needed so Accessibility permission survives rebuilds)

Ad-hoc signatures change on every build, so macOS forgets the Accessibility grant each time. A self-signed certificate keeps the app's identity stable.

1. Open **Keychain Access** and choose **Certificate Assistant ▸ Create a Certificate…**
2. Fill in the form:
   - **Name:** `Atrium Local Signing`
   - **Identity Type:** Self Signed Root
   - **Certificate Type:** Code Signing
3. Click **Create**.
4. In Keychain Access, double-click the new certificate. Under **Trust**, set **Code Signing: Always Trust**, then close the window and enter your password.
5. Run `./scripts/build.sh`. When macOS asks whether `codesign` may use the key, click **Always Allow**.

## Verify
`codesign -d -r- ~/Applications/Atrium.app` must print the **same** `designated =>` line after two rebuilds. Never change the bundle id (`com.alif.atrium`), and never sign with `--deep`.

During development, `tccutil reset Accessibility com.alif.atrium` resets the permission.
