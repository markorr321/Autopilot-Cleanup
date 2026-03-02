function Get-GraphPagedResults {
    param([string]$Uri)

    $allResults = @()
    $currentUri = $Uri

    do {
        try {
            $response = Invoke-MgGraphRequest -Uri $currentUri -Method GET
            if ($response.value) {
                $allResults += $response.value
            }
            $currentUri = $response.'@odata.nextLink'
        }
        catch {
            Write-ColorOutput "Error getting paged results: $($_.Exception.Message)" "Red"
            break
        }
    } while ($currentUri)

    return $allResults
}
