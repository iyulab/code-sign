# iyulab/code-sign

Centralized code signing service for iyulab artifacts: Authenticode for Windows, and an entry to the organization's signing Mac for macOS.

This repository provides **three ways** to sign Windows binaries with the iyulab GlobalSign EV code signing certificate, and a reusable entry for macOS bundles (see "macOS entry" below). Whichever you use, pin it to a commit (`iyulab/code-sign@<sha> # <tag>`), not `@main`: the job that runs it holds the signing credential.

### 1. Composite Action (`iyulab/code-sign@main`) — Recommended for mid-build signing

Call the composite action directly from any iyulab repo's workflow. Signs files in place on the caller's runner:

```yaml
jobs:
  build:
    runs-on: windows-latest
    environment: production   # Required for OIDC federated credential subject match
    permissions:
      id-token: write         # Required for OIDC
      contents: read
    steps:
      - run: dotnet publish ... -o out
      - uses: iyulab/code-sign@<sha>
        with:
          files: |
            out/MyApp.exe
            out/MyApp.dll
```

The example above signs inside the build job, so the build's own steps and every action it uses run next to the OIDC token. When the build pulls third-party code (package managers, toolchain actions), prefer the reusable workflow below, which keeps the credential in a job that runs nothing but signing.

**Prerequisites for this path:**
- Caller repo must be granted an Azure AD federated credential whose subject matches the caller's OIDC `sub` claim for the `production` environment — `repo:iyulab/<caller>:environment:production`, or for repositories that use immutable subject claims `repo:iyulab@<org-id>/<caller>@<repo-id>:environment:production`. Check which form a repo emits with `gh api repos/iyulab/<caller>/actions/oidc/customization/sub` before creating the credential.
- Caller repo must have a `production` environment
- `id-token: write` permission on the calling job
- The `production` environment must be declared on the job

**Action inputs:**

| Input | Default | Purpose |
|---|---|---|
| `files` | *(empty)* | Newline-separated paths or glob patterns to sign. Empty = only prepare the job (see below). |
| `description` | *(empty)* | Description shown in the signature, e.g. the product name |
| `description-url` | *(empty)* | URL shown in the signature |
| `client-id`, `tenant-id`, `key-vault-url`, `certificate-name`, `timestamp-url` | iyulab values | Signing identity — leave at the defaults |

### Signing from a build tool's sign hook

Some files only exist halfway through a build step — an installer bundler signs the app, its uninstaller and the installer itself as it creates them, running a sign command once per file. The action covers this too: besides signing `files`, it always prepares the rest of the job so that any later step can sign a single file with the same certificate:

- `code-sign-file.cmd <file>` — signs one file; its folder is put on `PATH` (also exported as `CODE_SIGN_FILE`, the absolute path, and as the action output `sign-command`)
- `CODE_SIGN_LOG` — a log file each call appends to: `== <file>: signed` or `== <file>: FAILED: <reason>`, followed by the AzureSignTool output (also the action output `log`)

Run the action before the build step — with `files` for anything that must be signed before bundling, or with no `files` to only prepare. Example with Tauri, whose `bundle.windows.signCommand` is run for every file the bundler signs:

```yaml
    steps:
      # ... build the app and any sidecar binaries ...
      - uses: iyulab/code-sign@<sha>
        with:
          files: src-host/publish/MyApp.Host.exe   # bundled as a resource: the bundler does not sign it
          description: MyApp
      - run: npx tauri build --config src-tauri/tauri.sign.conf.json
      - name: Show sign log
        if: failure()
        shell: pwsh
        run: if (Test-Path $env:CODE_SIGN_LOG) { Get-Content $env:CODE_SIGN_LOG }
```

with `src-tauri/tauri.sign.conf.json`:

```json
{ "bundle": { "windows": { "signCommand": "code-sign-file.cmd %1" } } }
```

Notes:
- **The hook mode widens the signing boundary to the rest of the job.** Once the action has run, every later step of that job can sign any file (`code-sign-file.cmd` is on `PATH` and the Azure session is live). That is the point when a bundler has to sign as it goes, but it means the bundler and everything it runs are trusted with the certificate. In a job that exists only to sign, call the action with `files` and nothing after it — or use the reusable workflow below.
- A sign hook usually keeps a failing command's output to itself, and some do not fail the build at all (an NSIS uninstaller is signed by `makensis`, which ignores the command's exit code). Always verify the signatures of what you ship, e.g. `Get-AuthenticodeSignature` on the installed files, and print `CODE_SIGN_LOG` when a step fails.
- The Key Vault token is taken from `az` for every file, so signing works in any later step of the job as long as the Azure CLI session from the action's login is still valid. That session cannot be renewed once its access token expires (roughly an hour after the action runs), so run the action shortly before the steps that sign, not at the start of a long job.
- Calling the action again in the same job is fine: the settings are exported again and the log keeps growing.

### 2. Reusable signing workflow (`sign.yml`) — signing in a job that runs nothing else

The caller builds without any credential and uploads the files to sign as an artifact. `sign.yml` runs in its own job: it downloads that artifact, refuses it unless it holds **exactly** the listed files, signs them with this repository's action (checked out at the same commit as the workflow, `job.workflow_sha`), verifies the signatures and uploads the signed copies as a new artifact. Nothing of the caller's code runs in the job that holds the credential.

```yaml
jobs:
  build:                       # no id-token here
    runs-on: windows-latest
    permissions:
      contents: read
    steps:
      # ... build, then put exactly the files to sign into one folder ...
      - uses: actions/upload-artifact@<sha> # <tag>
        with:
          name: unsigned-binaries
          path: to-sign

  sign:
    needs: build
    uses: iyulab/code-sign/.github/workflows/sign.yml@<sha> # <tag>
    permissions:
      id-token: write
      contents: read
    with:
      artifact: unsigned-binaries
      files: |                 # relative to the artifact root; must match its contents exactly
        MyApp.exe
        runtime/MyApp.Host.exe
      signed-artifact: signed-binaries
      description: MyApp

  package:
    needs: sign                # downloads signed-binaries and continues without the credential
```

| Input | Required | Purpose |
|---|---|---|
| `artifact` | yes | Artifact of the calling run holding the files to sign |
| `files` | yes | Newline-separated paths relative to the artifact root — the artifact must hold exactly these (no more, no fewer) |
| `signed-artifact` | yes | Name of the artifact the signed files are uploaded as, in the same layout |
| `description`, `description-url` | no | Shown in the signature |
| `retention-days` | no (1) | Retention of the signed artifact |

Prerequisites are the same as for the action (federated credential for the caller's `production` environment, the environment itself); the job declares `environment: production`, and the calling job must grant `id-token: write` and `contents: read`. An installer that a bundler builds from the signed files is signed by calling the workflow a second time on the installer.

**Narrowing the credential to this workflow.** A caller's federated credential normally matches `repo:iyulab/<caller>:environment:production`, which any job of that repository with the `production` environment satisfies. The OIDC token of a job run through this workflow also carries `job_workflow_ref` (`iyulab/code-sign/.github/workflows/sign.yml@<ref>`). To accept only those jobs, match that claim in Azure. With an exact match the credential names one pinned commit and has to be updated on every bump, so use a pattern match on `iyulab/code-sign/.github/workflows/sign.yml@*`. There are two ways to do it:

1. **As its own claim (preferred).** A [flexible federated identity credential](https://learn.microsoft.com/entra/workload-id/workload-identities-flexible-federated-identity-credentials) (preview) can match `job_workflow_ref` next to `sub`, so the caller's OIDC subject template stays as it is and none of its other jobs is affected:

   ```
   claims['sub'] eq '<the caller's current environment:production subject>'
     and claims['job_workflow_ref'] matches 'iyulab/code-sign/.github/workflows/sign.yml@*'
     and claims['repository_id'] eq '<repository id>'
     and claims['repository_owner_id'] eq '<owner id>'
   ```

   For GitHub-issued tokens the platform requires `sub` plus at least one of `repository_id` and `repository_owner_id`; matching both is the stricter form. To switch over without a gap, add the new credential first, delete the old exact-subject credential, then run a signing job — recreating the old credential is the rollback.

2. **Inside the subject.** Include the claim in the caller's subject (`gh api -X PUT repos/iyulab/<caller>/actions/oidc/customization/sub -f use_default=false -f 'include_claim_keys[]=repo' -f 'include_claim_keys[]=context' -f 'include_claim_keys[]=job_workflow_ref'`) and match `…:job_workflow_ref:iyulab/code-sign/.github/workflows/sign.yml@*` in `sub` with a flexible credential that also carries a `repository_id` and/or `repository_owner_id` clause. Changing the subject breaks that repository's other `production` jobs that sign directly, so move them to the workflow first, and mind the ordering of the two changes.

Whichever form a credential uses, check that it still carries an id clause: a flexible credential for GitHub without `repository_id` / `repository_owner_id` does not meet the current rules.

### macOS entry (`sign-macos.yml`) — signing on the organization's Mac

The macOS counterpart of `sign.yml`, with the same shape: the caller builds the bundle without any credential and uploads it as an artifact (`<App>.app.tar` plus an `entitlements/` folder), then calls the workflow. It signs nothing itself and holds no signing credential. It starts a signing workflow in a private repository (the Mac runner is self-hosted, which GitHub allows only for private repositories), waits for it and fails unless that run concluded `success`. The Mac signs the bundle with a Developer ID, notarizes it, builds the disk image and the update archive, checks them and attaches them to the draft release `v<version>` of the calling repository.

```yaml
jobs:
  macos-build:                 # the caller's own: build the bundle, no credential
    # ... uploads artifact `macos-bundle`
  macos-sign:
    needs: [release, macos-build]   # after the draft release exists
    uses: iyulab/code-sign/.github/workflows/sign-macos.yml@<sha> # <tag>
    secrets: inherit           # RELEASE_BOT_PRIVATE_KEY
    with:
      version: ${{ needs.macos-build.outputs.version }}
```

| Input | Required | Purpose |
|---|---|---|
| `version` | yes | Release version without the `v`; the draft release is `v<version>` |
| `artifact` | no (`macos-bundle`) | Artifact of the calling run holding `<App>.app.tar` and `entitlements/` |

Organization settings, once for all apps: the variables `RELEASE_BOT_CLIENT_ID` and `MACOS_SIGN_REPO` (the private signing repository, `owner/name`), the secret `RELEASE_BOT_PRIVATE_KEY`, and the release bot's GitHub App installed on the signing repository (Actions: write) and on every calling repository (Contents: write, Actions: read). The token the workflow mints is limited to Actions and metadata on the signing repository. Admitting a new app is a one-line allow-list entry in the signing repository; nothing changes here.

### 3. Dispatch Service (`sign-on-dispatch.yml`) — For batch post-build signing

Send a `repository_dispatch` event with asset names already attached to a draft GitHub Release. The service downloads, signs, and replaces the assets. Useful when the caller doesn't want to modify its build jobs (only its publish step).

The Azure Key Vault credentials never leave this repository. Caller repos do not need their own Azure AD configuration for path (3).

---

## Trust model

- **Azure AD federated credentials** (one per caller repo):
  - `repo:iyulab/code-sign:environment:production` — for the dispatch service path
  - `repo:iyulab/Filer-releases:environment:production` — for the composite action path
  - Additional credentials added per caller repo as needed
- Every federated credential requires the caller to declare `environment: production` on the signing job — this is the OIDC claim gate
- **Composite action and reusable workflow paths**: no secrets needed on caller side, only the federated credential
- **Pinned third-party code**: every job here that holds the OIDC token runs `azure/login` pinned to a commit and AzureSignTool pinned to an exact version, installed into the job's own folder (a copy already on the runner is never used). Bump them deliberately, in `action.yml` and `sign-on-dispatch.yml` together.
- **Dispatch service path**: explicit allowlist in `.github/workflows/sign-on-dispatch.yml` + iyulab org-level `RELEASE_TOKEN` for cross-repo asset access
- **Payload validation** (dispatch path only): tag format, asset name whitelist, path traversal prevention

---

## Dispatch payload contract

Caller sends a `repository_dispatch` event with `event_type: sign-request` and the following payload:

```json
{
  "event_type": "sign-request",
  "client_payload": {
    "caller_repo": "iyulab/Filer-releases",
    "release_tag": "v0.1.95",
    "assets": ["Filer-setup.exe", "MyApp.exe"],
    "request_id": "filer-releases-12345"
  }
}
```

| Field | Type | Validation |
|---|---|---|
| `caller_repo` | string | Must be in allowlist |
| `release_tag` | string | Must match `^v\d+\.\d+\.\d+(-[a-zA-Z0-9.]+)?$` |
| `assets` | string[] | Each must match `^[A-Za-z0-9._-]+\.(exe\|dll\|msi)$` |
| `request_id` | string | Alphanumeric + `_-`, max 64 chars (used for tracing) |

Each asset must already exist on the caller's release (typically a draft) before the dispatch is sent.

---

## Marker file protocol

For each signed asset, the service uploads a companion marker file named `<asset>.signed` to the same release. Callers should poll for the marker to know when signing is complete.

Marker contents (small JSON):

```json
{"asset":"Filer-setup.exe","signedAt":"2026-04-07T03:40:12.1234567+00:00","requestId":"filer-releases-12345"}
```

Example: signing `Filer-setup.exe` → after completion, the release contains both `Filer-setup.exe` (now signed, with new SHA256) and `Filer-setup.exe.signed`.

> **Important:** The signed asset's SHA256 differs from the unsigned original. Callers that publish hash manifests (e.g. `latest.json`) must compute hashes AFTER the marker appears.

---

## Onboarding a new caller repo

### Step 1: Add the repo to the allowlist

Open a PR to `.github/workflows/sign-on-dispatch.yml`, adding the new repo:

```bash
ALLOWED=("iyulab/Filer-releases" "iyulab/your-new-repo")
```

### Step 2: Verify `RELEASE_TOKEN` org secret access

The iyulab org secret `RELEASE_TOKEN` is used for both directions:
- `code-sign` uses it to download/upload release assets on the caller repo
- Caller repo uses it to send `repository_dispatch` to `code-sign`

Confirm the new caller repo has access to the org secret (check `Settings → Secrets → Organization secrets` in the new caller).

### Step 3: Caller adds the 4 release jobs

Copy the canonical implementation from [`iyulab/Filer-releases`](https://github.com/iyulab/Filer-releases/blob/main/.github/workflows/release.yml) — specifically these four jobs in `release.yml`:

- **`draft-release`** — creates a draft GitHub release with unsigned artifacts attached
- **`request-sign`** — sends `repository_dispatch` to this service
- **`wait-for-signed`** — polls for `.signed` markers on the draft release
- **`finalize-release`** — re-computes hashes from signed binaries, regenerates manifests, promotes draft → published

Minimal example of the dispatch step in the caller's `request-sign` job:

```yaml
- uses: peter-evans/repository-dispatch@v4
  with:
    token: ${{ secrets.RELEASE_TOKEN }}
    repository: iyulab/code-sign
    event-type: sign-request
    client-payload: >-
      {
        "caller_repo": "iyulab/your-repo",
        "release_tag": "${{ needs.version.outputs.tag }}",
        "assets": ["MyApp-setup.exe"],
        "request_id": "your-repo-${{ github.run_id }}"
      }
```

And the polling loop in `wait-for-signed`:

```yaml
- env:
    GH_TOKEN: ${{ secrets.RELEASE_TOKEN }}
    TAG: ${{ needs.version.outputs.tag }}
  run: |
    for i in $(seq 1 60); do
      if gh release view "$TAG" --repo iyulab/your-repo --json assets \
         | jq -e '.assets[] | select(.name == "MyApp-setup.exe.signed")' > /dev/null; then
        echo "Signed marker detected"; exit 0
      fi
      sleep 15
    done
    echo "::error::Timeout waiting for signature"; exit 1
```

---

## Supported artifact types

- `.exe` — Windows executables (signed by AzureSignTool / signtool compatible)
- `.dll` — Native and managed DLLs
- `.msi` — Windows Installer packages

For artifacts nested inside zip files, use the **composite action** path to sign binaries in place on the build runner BEFORE packaging. The dispatch service path only operates on top-level release assets.

---

## Troubleshooting

### `Caller '<repo>' not in allowlist`
The dispatching repo is not in `ALLOWED` array. See onboarding Step 1.

### `Invalid tag format`
The release tag must follow strict semver: `v1.2.3` or `v1.2.3-prerelease`. Numeric segments only, optional pre-release suffix with alphanumerics and dots.

### `Invalid asset name`
Asset names must be alphanumeric + `._-` with extension `.exe`, `.dll`, or `.msi`. No path separators, no `..`, no spaces.

### `Download failed: work/<asset> not present`
The asset does not exist on the caller's release at the time of dispatch. Confirm the caller's `draft-release` job completed before `request-sign` runs.

### `AADSTS70021` / OIDC token rejected
Federated credential subject mismatch. Verify the credential's subject matches what the caller's job emits (`gh api repos/iyulab/<repo>/actions/oidc/customization/sub` tells whether the repo uses the `repo:iyulab/<repo>:...` or the immutable `repo:iyulab@<org-id>/<repo>@<repo-id>:...` form) and that the workflow job declares `environment: production`.

### `sign-file.ps1: CODE_SIGN_... is not set` / `code-sign-file.cmd` not recognized
The step that signs runs before the action, or in a different job. Run `iyulab/code-sign` earlier in the same job; its settings and `PATH` entry only reach later steps of that job.

### `sign-file.ps1: no Key Vault access token`
The Azure CLI session from the action's login is gone or expired. Run the action closer to the step that signs (see the notes under "Signing from a build tool's sign hook").

### `Forbidden` from Key Vault
The Azure AD service principal lacks `Key Vault Certificate User` role on `kv-codesign-iyulab`.

### `HTTP 400: Bad Content-Length` during asset upload
GitHub rejects 0-byte uploads. The service workflow ensures markers contain JSON metadata; caller-side uploads must also be non-empty.

### Marker never appears (caller polling timeout)
Inspect the most recent `sign-on-dispatch.yml` run in this repo for the actual error. Common causes: `RELEASE_TOKEN` access issue on the new caller repo, transient Azure timestamp server issue (re-run), AzureSignTool installation failure.

---

## Reference implementation

[`iyulab/Filer-releases`](https://github.com/iyulab/Filer-releases) is the first and canonical caller. See its `.github/workflows/release.yml` for the full integration pattern.

---

## Repository contents

| File | Purpose |
|---|---|
| `action.yml` | **Composite action** for in-build signing (`uses: iyulab/code-sign@main`) |
| `scripts/sign-file.ps1` | Signs one file with the AzureSignTool the action installed; used by the action for each of its `files` and by `code-sign-file.cmd` |
| `.github/workflows/sign.yml` | Reusable signing workflow (`workflow_call`) — signs a fixed list of files from an artifact in a job that runs nothing else |
| `.github/workflows/sign-macos.yml` | macOS entry (`workflow_call`) — hands a credential-free bundle to the private signing repository and waits for it; holds no signing credential |
| `.github/workflows/sign-on-dispatch.yml` | Dispatch service workflow (repository_dispatch handler) |
| `.github/workflows/_sign-test.yml` | Signing smoke test of the action and the reusable workflow (workflow_dispatch) |
| `.github/workflows/_self-test.yml` | E2E self-test of the dispatch handler (workflow_dispatch) |

The two `_*.yml` workflows are diagnostic tools and are not triggered automatically. They are safe to run manually to validate the signing infrastructure or debug issues.
