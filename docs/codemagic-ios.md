# Codemagic iOS build

The `ios-testflight` workflow builds the selected branch on a macOS machine,
runs analysis and tests, obtains App Store signing resources, builds an IPA,
and uploads it for TestFlight. Start it manually after credentials and the hosted API are configured.
The existing **Internal** TestFlight group automatically receives every build
through its App Store Connect settings. Do not list this internal group under
`publishing.app_store_connect.beta_groups`: Apple's API rejects manual build
assignment to internal groups. The workflow does not submit the app for
external beta review or public App Store review.

Create an environment variable group named `studyorbit_apple` in Codemagic,
accessible to this app, with these values:

| Variable | Value |
| --- | --- |
| `APP_STORE_CONNECT_PRIVATE_KEY` | Full contents of the Apple API `.p8` key; secret |
| `APP_STORE_CONNECT_KEY_IDENTIFIER` | Apple API Key ID |
| `APP_STORE_CONNECT_ISSUER_ID` | Apple API Issuer ID |
| `CERTIFICATE_PRIVATE_KEY` | Persistent RSA private key in PEM format; secret |
| `APP_STORE_APP_ID` | Numeric Apple ID of the StudyOrbit app record in App Store Connect |
| `STUDYORBIT_API_ORIGIN` | Public HTTPS origin serving the hosted AI API; not a provider URL or secret |

The certificate private key is separate from the Apple API key. Reuse it across
builds so signing does not create a new distribution certificate on each run.
Keep all private keys and Codemagic API tokens outside the repository.

Register bundle ID `si.studyorbit.studyorbit` with Apple and create its App Store
Connect app record before running the workflow. The Apple API key must have
permission to manage signing resources and upload builds (App Manager role).

In Codemagic, select the branch containing these changes (currently
`analysis/code-review`), scan it for `codemagic.yaml`, and select **StudyOrbit iOS
TestFlight**. The workflow passes `STUDYORBIT_API_ORIGIN` with `--dart-define`
and refuses an unset/non-HTTPS value rather than producing a disconnected pilot.
Provider keys belong only on the Node server and must never enter Codemagic's
Flutter build defines. Deploy that server separately with HTTPS, invitations
and persistent quota storage as described in the main README.

This workflow uses CLI signing and environment variables, so a separate
Developer Portal integration in Codemagic is not required. The migration version
still needs signed-build and physical-device verification; the local workstation
does not have full compatible Xcode or an Android SDK.

App-layer AES encryption has been added. The previous automatic
`ITSAppUsesNonExemptEncryption=false` declaration was removed: the owner must
answer Apple's export-compliance questionnaire for the new binary. This change
does not accept legal terms or determine an encryption exemption on the owner's behalf.

References:
- https://docs.codemagic.io/yaml-code-signing/alternative-code-signing-methods/
- https://docs.codemagic.io/yaml-publishing/app-store-connect/
