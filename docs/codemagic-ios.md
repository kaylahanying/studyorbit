# Codemagic iOS build

The `ios-testflight` workflow builds the `main` branch on a macOS machine,
runs analysis and tests, obtains App Store signing resources, builds an IPA,
and uploads it for TestFlight. Start it manually after credentials are configured.
It does not submit the app for public App Store review.

Create an environment variable group named `studyorbit_apple` in Codemagic,
accessible to this app, with these values:

| Variable | Value |
| --- | --- |
| `APP_STORE_CONNECT_PRIVATE_KEY` | Full contents of the Apple API `.p8` key; secret |
| `APP_STORE_CONNECT_KEY_IDENTIFIER` | Apple API Key ID |
| `APP_STORE_CONNECT_ISSUER_ID` | Apple API Issuer ID |
| `CERTIFICATE_PRIVATE_KEY` | Persistent RSA private key in PEM format; secret |
| `APP_STORE_APP_ID` | Numeric Apple ID of the StudyOrbit app record in App Store Connect |

The certificate private key is separate from the Apple API key. Reuse it across
builds so signing does not create a new distribution certificate on each run.
Keep all private keys and Codemagic API tokens outside the repository.

Register bundle ID `si.studyorbit.studyorbit` with Apple and create its App Store
Connect app record before running the workflow. The Apple API key must have
permission to manage signing resources and upload builds (App Manager role).

In Codemagic, scan `main` for `codemagic.yaml` and select **StudyOrbit iOS
TestFlight**. This workflow uses CLI signing and environment variables, so a
separate Developer Portal integration in Codemagic is not required.

The native iOS build needs verification on Codemagic; Flutter and full Xcode
are unavailable in the local preparation environment.

References:
- https://docs.codemagic.io/yaml-code-signing/alternative-code-signing-methods/
- https://docs.codemagic.io/yaml-publishing/app-store-connect/
