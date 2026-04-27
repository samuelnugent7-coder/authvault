# AuthVault — Windows installer (PowerShell)
# Usage (run as Administrator, or it installs to user profile):
#   irm https://raw.githubusercontent.com/Nugent-Brothers-Enterprises/authvault/main/install.ps1 | iex
# Or:
#   .\install.ps1 [-InstallDir "C:\AuthVault"] [-Port 8443] [-NoService]

param(
    [string]$InstallDir = "$env:ProgramFiles\AuthVault",
    [int]$Port = 8443,
    [switch]$NoService
)

$REPO = "Nugent-Brothers-Enterprises/authvault"
$ErrorActionPreference = "Stop"

function Write-Info  { Write-Host "[authvault] $args" -ForegroundColor Cyan }
function Write-Ok    { Write-Host "[authvault] $args" -ForegroundColor Green }
function Write-Fail  { Write-Host "[authvault] $args" -ForegroundColor Red; exit 1 }

# ── Fetch latest release ─────────────────────────────────────────────────────
Write-Info "Fetching latest release from GitHub..."
$release = Invoke-RestMethod "https://api.github.com/repos/$REPO/releases/latest"
$asset = $release.assets | Where-Object { $_.name -like "authvault-api*.exe" } | Select-Object -First 1
if (-not $asset) { Write-Fail "No .exe found in latest release. Check https://github.com/$REPO/releases" }

# ── Install ───────────────────────────────────────────────────────────────────
Write-Info "Installing to $InstallDir ..."
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
$exePath = Join-Path $InstallDir "authvault-api.exe"
Invoke-WebRequest $asset.browser_download_url -OutFile $exePath
Write-Ok "Binary installed: $exePath"

# ── Windows Service (NSSM or SC) ─────────────────────────────────────────────
if (-not $NoService) {
    $nssmPath = (Get-Command nssm -ErrorAction SilentlyContinue)?.Source
    if ($nssmPath) {
        Write-Info "Installing Windows service via NSSM..."
        & nssm install AuthVaultAPI $exePath
        & nssm set AuthVaultAPI AppDirectory $InstallDir
        & nssm set AuthVaultAPI DisplayName "AuthVault API"
        & nssm set AuthVaultAPI Description "Self-hosted password manager API"
        & nssm set AuthVaultAPI Start SERVICE_AUTO_START
        Write-Ok "Service installed. Run: nssm start AuthVaultAPI"
    } else {
        Write-Info "NSSM not found — creating basic SC service..."
        sc.exe create AuthVaultAPI binPath= "`"$exePath`"" start= auto DisplayName= "AuthVault API"
        sc.exe description AuthVaultAPI "Self-hosted password manager API"
        Write-Ok "Service created. Run: sc start AuthVaultAPI"
    }
} else {
    Write-Info "Skipping service setup (--NoService)."
}

# ── Add to PATH ───────────────────────────────────────────────────────────────
$currentPath = [Environment]::GetEnvironmentVariable("PATH", "Machine")
if ($currentPath -notlike "*$InstallDir*") {
    [Environment]::SetEnvironmentVariable("PATH", "$currentPath;$InstallDir", "Machine")
    Write-Ok "Added $InstallDir to system PATH"
}

Write-Host ""
Write-Host "┌─────────────────────────────────────────────────────────────┐" -ForegroundColor Yellow
Write-Host "│  AuthVault installed!                                       │" -ForegroundColor Yellow
Write-Host "│                                                             │" -ForegroundColor Yellow
Write-Host "│  First run (do this ONCE to get your client secret):       │" -ForegroundColor Yellow
Write-Host "│    cd `"$InstallDir`"" -ForegroundColor Yellow
Write-Host "│    .\authvault-api.exe                                      │" -ForegroundColor Yellow
Write-Host "│                                                             │" -ForegroundColor Yellow
Write-Host "│  It will print your CLIENT SECRET — save it.               │" -ForegroundColor Yellow
Write-Host "│  Then start the service: sc start AuthVaultAPI             │" -ForegroundColor Yellow
Write-Host "└─────────────────────────────────────────────────────────────┘" -ForegroundColor Yellow
