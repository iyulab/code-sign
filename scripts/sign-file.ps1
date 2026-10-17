#!/usr/bin/env pwsh
# Authenticode-signs one Windows PE file with the certificate held in Azure Key Vault.
#
#   sign-file.ps1 <file>
#
# Called once per file: by the iyulab/code-sign action for each of its `files`, and by a build tool's
# sign hook (e.g. Tauri's `bundle.windows.signCommand`) in any later step of the same job. The action
# logs the job in to Azure, installs AzureSignTool and exports the settings read here:
#
#   CODE_SIGN_TOOL, CODE_SIGN_KEY_VAULT_URL, CODE_SIGN_CERTIFICATE,
#   CODE_SIGN_TIMESTAMP_URL                                                     required
#                   (CODE_SIGN_TOOL is the AzureSignTool the action installed at a fixed version)
#   CODE_SIGN_DESCRIPTION, CODE_SIGN_DESCRIPTION_URL                           optional
#   CODE_SIGN_LOG   optional; every call appends the file, its outcome and the tool output, because a
#                   sign hook usually keeps a failing command's output to itself
#
# The Key Vault access token is taken from `az` for each file instead of once per job, so a hook that
# runs late in the job uses whatever token `az` currently holds.
param(
    [Parameter(Position = 0)]
    [string] $File
)

$ErrorActionPreference = 'Stop'

function Write-SignLog([string[]] $Lines) {
    if ($env:CODE_SIGN_LOG) { Add-Content -LiteralPath $env:CODE_SIGN_LOG -Value $Lines }
}

$output = @()
try {
    if (-not $File) { throw 'no file path given' }
    if (-not (Test-Path -LiteralPath $File -PathType Leaf)) { throw "file not found: $File" }
    foreach ($name in 'CODE_SIGN_TOOL', 'CODE_SIGN_KEY_VAULT_URL', 'CODE_SIGN_CERTIFICATE', 'CODE_SIGN_TIMESTAMP_URL') {
        if (-not [Environment]::GetEnvironmentVariable($name)) {
            throw "$name is not set (run the iyulab/code-sign action earlier in this job)"
        }
    }

    $token = az account get-access-token --resource https://vault.azure.net --query accessToken -o tsv
    if ($LASTEXITCODE -ne 0 -or -not $token) { throw 'no Key Vault access token (is the job logged in to Azure?)' }

    $arguments = @(
        'sign'
        '--azure-key-vault-url', $env:CODE_SIGN_KEY_VAULT_URL
        '--azure-key-vault-accesstoken', $token
        '--azure-key-vault-certificate', $env:CODE_SIGN_CERTIFICATE
        '--timestamp-rfc3161', $env:CODE_SIGN_TIMESTAMP_URL
        '--timestamp-digest', 'sha256'
        '--file-digest', 'sha256'
        '--verbose'
    )
    if ($env:CODE_SIGN_DESCRIPTION) { $arguments += '--description', $env:CODE_SIGN_DESCRIPTION }
    if ($env:CODE_SIGN_DESCRIPTION_URL) { $arguments += '--description-url', $env:CODE_SIGN_DESCRIPTION_URL }
    $arguments += $File

    $output = @(& $env:CODE_SIGN_TOOL @arguments 2>&1 | ForEach-Object { "$_" })
    $code = $LASTEXITCODE
    $output
    if ($code -ne 0) { throw "AzureSignTool failed with exit code $code" }

    Write-SignLog (@("== ${File}: signed") + $output)
}
catch {
    Write-SignLog (@("== ${File}: FAILED: $_") + $output)
    throw "sign-file.ps1: $_"
}
