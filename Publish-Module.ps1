# Publish-Module.ps1
# Creates .nupkg for GitHub releases

param([string]$OutputPath = ".\release")

if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

$modulePath = Join-Path $PSScriptRoot "AutopilotCleanup"
$manifest = Import-PowerShellDataFile "$modulePath\AutopilotCleanup.psd1"
$version = $manifest.ModuleVersion

Write-Host "Packaging AutopilotCleanup v$version..." -ForegroundColor Cyan

# Create temp local repo
$tempRepo = Join-Path $env:TEMP "AutopilotCleanupRepo"
if (Test-Path $tempRepo) { Remove-Item $tempRepo -Recurse -Force }
New-Item -ItemType Directory -Path $tempRepo -Force | Out-Null

$repoName = "AutopilotCleanupTemp"
Unregister-PSResourceRepository -Name $repoName -ErrorAction SilentlyContinue
Register-PSResourceRepository -Name $repoName -Uri $tempRepo -Trusted

Publish-PSResource -Path $modulePath -Repository $repoName

$nupkg = Get-ChildItem $tempRepo -Filter "*.nupkg" | Select-Object -First 1
if ($nupkg) {
    Copy-Item $nupkg.FullName -Destination $OutputPath
    Write-Host "Created: $OutputPath\$($nupkg.Name)" -ForegroundColor Green
    Write-Host "Upload this file to your GitHub release." -ForegroundColor Yellow
}

Unregister-PSResourceRepository -Name $repoName -ErrorAction SilentlyContinue
Remove-Item $tempRepo -Recurse -Force -ErrorAction SilentlyContinue
