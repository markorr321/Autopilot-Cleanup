function Get-GraphPagedResults {
    param(
        [string]$Uri,

        [string]$ActivityName = "Fetching data"
    )

    $allResults = @()
    $currentUri = $Uri
    $page = 0

    do {
        $page++
        Write-Progress -Activity $ActivityName -Status "Page $page - $($allResults.Count) records so far"

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

    Write-Progress -Activity $ActivityName -Completed

    return $allResults
}
