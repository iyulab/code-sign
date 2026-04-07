# iyulab/code-sign

Centralized Authenticode signing service for iyulab Windows artifacts.

This repository hosts a single GitHub Actions workflow that:
1. Receives `repository_dispatch` events from caller repos
2. Authenticates to Azure Key Vault via OIDC (federated credential)
3. Downloads the unsigned artifact from the caller's draft GitHub Release
4. Signs it with AzureSignTool using a GlobalSign EV code signing certificate
5. Replaces the asset on the caller's release and uploads a `<asset>.signed` marker

The Azure Key Vault credentials never leave this repository. Caller repos do not need their own Azure AD configuration.

---

## Trust model

- **Azure AD federated credential** subject: `repo:iyulab/code-sign:environment:production`
  - Only this repo's `production` environment can mint OIDC tokens for the Key Vault service principal
- **Caller authorization**: explicit allowlist in `.github/workflows/sign-on-dispatch.yml`
- **Cross-repo asset access**: iyulab org-level `RELEASE_TOKEN` secret (shared across iyulab release pipelines)
- **Payload validation**: tag format, asset name whitelist, path traversal prevention

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

For artifacts nested inside zip files, see the Phase 2 plan (not yet implemented). Current workaround: sign executables before packaging them into zips.

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
Federated credential subject mismatch. Verify the credential in Azure AD has subject `repo:iyulab/code-sign:environment:production` and that the workflow job declares `environment: production`.

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
| `.github/workflows/sign-on-dispatch.yml` | Production service workflow (repository_dispatch handler) |
| `.github/workflows/_sign-test.yml` | Standalone signing smoke test (workflow_dispatch) |
| `.github/workflows/_self-test.yml` | E2E self-test of the dispatch handler (workflow_dispatch) |

The two `_*.yml` workflows are diagnostic tools and are not triggered automatically. They are safe to run manually to validate the signing infrastructure or debug issues.
