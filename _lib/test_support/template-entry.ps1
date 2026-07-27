function New-SwawKitTestTemplateEntry {
    param(
        [Parameter(Mandatory = $true)] [string]$RepoRoot,
        [Parameter(Mandatory = $true)] [string]$TemplateName,
        [Parameter(Mandatory = $true)] [string]$EntryName
    )

    if ([IO.Path]::GetFileName($TemplateName) -cne $TemplateName) {
        throw "TemplateName must be a file name below Favorites: $TemplateName"
    }
    if (
        [IO.Path]::GetFileName($EntryName) -cne $EntryName -or
        $EntryName -notmatch '^test\.template\.[A-Za-z0-9._-]+\.cmd$'
    ) {
        throw "EntryName must use the reserved test.template.*.cmd form: $EntryName"
    }

    $root = [IO.Path]::GetFullPath($RepoRoot)
    $template = Join-Path (Join-Path $root "Favorites") $TemplateName
    $entry = Join-Path $root $EntryName
    if (-not (Test-Path -LiteralPath $template -PathType Leaf)) {
        throw "Favorites template not found: $template"
    }

    Copy-Item -LiteralPath $template -Destination $entry -Force
    return $entry
}

function Remove-SwawKitTestTemplateEntry {
    param(
        [Parameter(Mandatory = $true)] [string]$RepoRoot,
        [AllowNull()] [string]$EntryPath
    )

    if ([string]::IsNullOrWhiteSpace($EntryPath)) {
        return
    }

    $root = [IO.Path]::GetFullPath($RepoRoot).TrimEnd('\')
    $entry = [IO.Path]::GetFullPath($EntryPath)
    if (
        (Split-Path -Parent $entry).TrimEnd('\') -ine $root -or
        [IO.Path]::GetFileName($entry) -notmatch '^test\.template\.[A-Za-z0-9._-]+\.cmd$'
    ) {
        throw "Refusing to remove a non-test root entry: $entry"
    }

    Remove-Item -LiteralPath $entry -Force -ErrorAction SilentlyContinue
}
