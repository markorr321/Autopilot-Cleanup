# Initialize module-scoped state variables
$script:MonitoringMode = $false
$script:NoLoggingMode = $false
$script:CustomClientId = $null
$script:CustomTenantId = $null

# Dot-source all private functions
$privatePath = Join-Path -Path $PSScriptRoot -ChildPath 'Private'
if (Test-Path $privatePath) {
    Get-ChildItem -Path $privatePath -Filter '*.ps1' -File | ForEach-Object {
        . $_.FullName
    }
}

# Dot-source all public functions
$publicPath = Join-Path -Path $PSScriptRoot -ChildPath 'Public'
if (Test-Path $publicPath) {
    Get-ChildItem -Path $publicPath -Filter '*.ps1' -File | ForEach-Object {
        . $_.FullName
    }
}
