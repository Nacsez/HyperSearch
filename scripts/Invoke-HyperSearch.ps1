param(
    [ValidateSet(
        "ready",
        "health",
        "search",
        "research",
        "providers",
        "provider-models",
        "set-provider",
        "default-provider",
        "history",
        "history-export",
        "retention"
    )]
    [string]$Action = "search",

    [string]$BaseUrl = "http://127.0.0.1:8090",
    [string]$PairingToken = "",

    [string]$Query = "",
    [int]$Results = 10,
    [int]$ResearchSources = 5,
    [string]$Engines = "",
    [string]$Categories = "",
    [string]$Language = "",
    [string]$DateRange = "",
    [ValidateSet(0, 1, 2)]
    [int]$SafeSearch = 1,
    [switch]$FetchPages,
    [switch]$ExtractText,
    [switch]$Summarize,
    [switch]$NoDedupe,
    [ValidateSet("use", "bypass", "refresh", "only-if-cached")]
    [string]$CachePolicy = "use",
    [int]$TimeoutMs = 30000,

    [string]$ProviderName = "",
    [string]$DisplayName = "",
    [string]$BaseProviderUrl = "",
    [string]$Model = "",
    [switch]$DisableProvider,
    [switch]$MakeDefault,
    [int]$RetentionDays = 90
)

$ErrorActionPreference = "Stop"

function Convert-CsvList([string]$Value) {
    $items = $Value -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    if ($items.Count -eq 0) {
        return $null
    }
    return @($items)
}

function Get-Paging([int]$Total) {
    $bounded = [Math]::Min(250, [Math]::Max(1, $Total))
    $perPage = [Math]::Min(50, $bounded)
    return @{
        page = 1
        results_per_page = $perPage
        max_pages = [Math]::Ceiling($bounded / $perPage)
    }
}

function Invoke-HyperSearchRequest([string]$Method, [string]$Path, $Body = $null) {
    $headers = @{}
    if ($PairingToken) {
        $headers["X-HyperSearch-Token"] = $PairingToken
    }
    $uri = "$($BaseUrl.TrimEnd('/'))$Path"
    if ($null -eq $Body) {
        return Invoke-RestMethod -Method $Method -Uri $uri -Headers $headers
    }
    return Invoke-RestMethod -Method $Method -Uri $uri -Headers $headers -ContentType "application/json" -Body ($Body | ConvertTo-Json -Depth 20)
}

function New-SearchBody {
    if (-not $Query.Trim()) {
        throw "Query is required for $Action."
    }
    $paging = Get-Paging $Results
    return @{
        query = $Query
        engines = Convert-CsvList $Engines
        categories = Convert-CsvList $Categories
        language = if ($Language) { $Language } else { $null }
        time_range = if ($DateRange) { $DateRange } else { $null }
        page = $paging.page
        results_per_page = $paging.results_per_page
        max_pages = $paging.max_pages
        safe_search = $SafeSearch
        dedupe = -not $NoDedupe
        fetch_pages = [bool]$FetchPages
        extract_text = [bool]$ExtractText
        summarize = [bool]$Summarize
        timeout_ms = $TimeoutMs
        cache_policy = $CachePolicy
    }
}

switch ($Action) {
    "ready" {
        $result = Invoke-HyperSearchRequest "GET" "/v1/ready"
    }
    "health" {
        $result = Invoke-HyperSearchRequest "GET" "/v1/health"
    }
    "search" {
        $result = Invoke-HyperSearchRequest "POST" "/v1/search" (New-SearchBody)
    }
    "research" {
        $body = New-SearchBody
        $body.top_n = [Math]::Min(250, [Math]::Max(1, $ResearchSources))
        $body.provider = if ($ProviderName) { $ProviderName } else { $null }
        $result = Invoke-HyperSearchRequest "POST" "/v1/research" $body
    }
    "providers" {
        $result = Invoke-HyperSearchRequest "GET" "/v1/providers"
    }
    "provider-models" {
        if (-not $ProviderName.Trim()) {
            throw "ProviderName is required for provider-models."
        }
        $result = Invoke-HyperSearchRequest "GET" "/v1/providers/$ProviderName/models"
    }
    "set-provider" {
        if (-not $ProviderName.Trim()) {
            throw "ProviderName is required for set-provider."
        }
        $result = Invoke-HyperSearchRequest "PATCH" "/v1/providers/$ProviderName" @{
            display_name = if ($DisplayName) { $DisplayName } else { $ProviderName }
            provider_type = "openai-compatible"
            base_url = if ($BaseProviderUrl) { $BaseProviderUrl } else { $null }
            model = if ($Model) { $Model } else { $null }
            enabled = -not $DisableProvider
            is_default = [bool]$MakeDefault
        }
    }
    "default-provider" {
        if (-not $ProviderName.Trim()) {
            throw "ProviderName is required for default-provider."
        }
        $result = Invoke-HyperSearchRequest "POST" "/v1/providers/default" @{ name = $ProviderName }
    }
    "history" {
        $result = Invoke-HyperSearchRequest "GET" "/v1/history"
    }
    "history-export" {
        $result = Invoke-HyperSearchRequest "GET" "/v1/history/export"
    }
    "retention" {
        $result = Invoke-HyperSearchRequest "POST" "/v1/history/retention" @{ days = $RetentionDays }
    }
}

$result | ConvertTo-Json -Depth 30
