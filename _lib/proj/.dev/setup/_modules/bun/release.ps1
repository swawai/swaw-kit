Set-StrictMode -Version 2.0

function Get-ProjDevBunReleaseProperty {
    param(
        [Parameter(Mandatory = $true)][object]$Value,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $Property = $Value.PSObject.Properties[$Name]
    if ($null -eq $Property) {
        return $null
    }
    return $Property.Value
}

function Request-ProjDevBunGitHubRelease {
    param([Parameter(Mandatory = $true)][object]$Definition)

    $Repository = [string]$Definition.Release.Repository
    $Tag = ([string]$Definition.Release.TagTemplate).Replace(
        '{version}',
        [string]$Definition.Version
    )
    $Endpoint = 'https://api.github.com/repos/{0}/releases/tags/{1}' -f
        $Repository,
        [Uri]::EscapeDataString($Tag)
    try {
        return Invoke-RestMethod `
            -Uri $Endpoint `
            -Headers @{
                Accept = 'application/vnd.github+json'
                'X-GitHub-Api-Version' = [string]$Definition.Release.ApiVersion
                'User-Agent' = 'swawkit-proj-v0'
            } `
            -UseBasicParsing `
            -TimeoutSec 30 `
            -ErrorAction Stop
    } catch {
        throw (
            "Cannot resolve Bun $($Definition.Version) from GitHub Releases: " +
            $_.Exception.Message
        )
    }
}

function Resolve-ProjDevBunRelease {
    param(
        [Parameter(Mandatory = $true)][object]$Definition,
        [AllowNull()][object]$Release = $null
    )

    if ($null -eq $Release) {
        $Release = Request-ProjDevBunGitHubRelease -Definition $Definition
    }
    $ExpectedTag = ([string]$Definition.Release.TagTemplate).Replace(
        '{version}',
        [string]$Definition.Version
    )
    $ActualTag = [string](Get-ProjDevBunReleaseProperty `
        -Value $Release `
        -Name 'tag_name')
    if ($ActualTag -cne $ExpectedTag) {
        throw (
            "GitHub returned Bun release tag '$ActualTag'; expected " +
            "'$ExpectedTag'."
        )
    }

    $ExpectedAsset = [string]$Definition.Release.Asset
    $Assets = @(Get-ProjDevBunReleaseProperty `
        -Value $Release `
        -Name 'assets')
    $Matches = @($Assets | Where-Object {
        [string](Get-ProjDevBunReleaseProperty `
            -Value $_ `
            -Name 'name') -ceq $ExpectedAsset
    })
    if ($Matches.Count -ne 1) {
        throw (
            "GitHub release '$ExpectedTag' must contain exactly one " +
            "'$ExpectedAsset' asset; found $($Matches.Count)."
        )
    }

    $Asset = $Matches[0]
    $UrlText = [string](Get-ProjDevBunReleaseProperty `
        -Value $Asset `
        -Name 'browser_download_url')
    $Url = $null
    if (-not [Uri]::TryCreate(
        $UrlText,
        [UriKind]::Absolute,
        [ref]$Url
    ) -or
        $Url.Scheme -cne 'https' -or
        $Url.Host -cne 'github.com') {
        throw "GitHub returned an invalid Bun asset URL: $UrlText"
    }

    $Digest = [string](Get-ProjDevBunReleaseProperty `
        -Value $Asset `
        -Name 'digest')
    $GitHubSha256 = ''
    if (-not [string]::IsNullOrWhiteSpace($Digest)) {
        $DigestMatch = [regex]::Match(
            $Digest.Trim(),
            '^sha256:([a-fA-F0-9]{64})$'
        )
        if ($DigestMatch.Success) {
            $GitHubSha256 = $DigestMatch.Groups[1].Value.ToLowerInvariant()
        }
    }

    $ProjectSha256 = Get-ProjDevProjectSha256 -Definition $Definition
    if (-not [string]::IsNullOrWhiteSpace($ProjectSha256) -and
        -not [string]::IsNullOrWhiteSpace($GitHubSha256) -and
        $ProjectSha256 -cne $GitHubSha256) {
        throw (
            "SWAWKIT_PROJ_BUN_SHA256 does not match the GitHub Release " +
            "digest for Bun $($Definition.Version)."
        )
    }

    $Definition.Url = $Url.AbsoluteUri
    if (-not [string]::IsNullOrWhiteSpace($ProjectSha256)) {
        $Definition.Sha256 = $ProjectSha256
        $Definition.Verification = 'project'
    } elseif (-not [string]::IsNullOrWhiteSpace($GitHubSha256)) {
        $Definition.Sha256 = $GitHubSha256
        $Definition.Verification = 'github'
    } else {
        $Definition.Sha256 = ''
        $Definition.Verification = 'unverified'
    }
    return $Definition
}
