[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\..\.."))
. (Join-Path $repoRoot "_lib\test_support\template-entry.ps1")
$entryFile = New-SwawKitTestTemplateEntry `
    -RepoRoot $repoRoot `
    -TemplateName "template.git1.cmd" `
    -EntryName "test.template.git1.cmd"
$tempBase = Join-Path $repoRoot "temp_workspace"

function Assert-True {
    param([bool]$Condition, [string]$Message)

    if (-not $Condition) {
        throw $Message
    }
}

function Assert-ExitCode {
    param([int]$Actual, [int]$Expected, [string]$Label)

    if ($Actual -ne $Expected) {
        throw "$Label failed: expected exit code $Expected, got $Actual."
    }
}

function Remove-TestDirectory {
    param([string]$Path)

    for ($attempt = 0; $attempt -lt 10; $attempt++) {
        try {
            if (Test-Path -LiteralPath $Path) {
                Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
            }
            return
        } catch {
            if ($attempt -eq 9) { throw }
            Start-Sleep -Milliseconds 100
        }
    }
}

function Invoke-Captured {
    param(
        [string]$File,
        [string[]]$CommandArgs,
        [int]$ExpectedExitCode,
        [string]$Label
    )

    $oldErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $output = (& $File @CommandArgs 2>&1 | Out-String -Width 4096)
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $oldErrorActionPreference
    }

    Assert-ExitCode $exitCode $ExpectedExitCode $Label
    return $output
}

function New-TestRepository {
    param([string]$TempRoot, [string]$OriginUrl)

    $path = Join-Path $TempRoot ([guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $path | Out-Null
    Push-Location $path
    try {
        git init -q
        Assert-ExitCode $LASTEXITCODE 0 "git init"
        if ($OriginUrl) {
            git remote add origin $OriginUrl
            Assert-ExitCode $LASTEXITCODE 0 "git remote add origin"
        }
    } finally {
        Pop-Location
    }

    return $path
}

function Invoke-InRepository {
    param([string]$Path, [scriptblock]$Script)

    Push-Location $Path
    try {
        & $Script
    } finally {
        Pop-Location
    }
}

function Get-OriginUrls {
    param([string]$Path)

    Push-Location $Path
    try {
        return @(& git config --local --get-all remote.origin.url)
    } finally {
        Pop-Location
    }
}

function Test-GitHubRoundTrip {
    param([string]$TempRoot)

    $path = New-TestRepository $TempRoot "https://github.com/acme/widget"
    Invoke-InRepository $path {
        $output = Invoke-Captured $entryFile @(".origin", "ssh") 0 "GitHub HTTPS to SSH"
        Assert-True ($output.Contains("https://github.com/acme/widget")) "GitHub conversion should show the original URL."
        Assert-True ($output.Contains("git@github.com:acme/widget.git")) "GitHub conversion should show the new URL."
        Assert-True (@(Get-OriginUrls $path)[0] -eq "git@github.com:acme/widget.git") "GitHub SSH conversion should update origin."

        $unchanged = Invoke-Captured $entryFile @(".origin", "ssh") 0 "GitHub SSH idempotence"
        Assert-True ($unchanged.Contains("already uses SSH")) "GitHub SSH conversion should be idempotent."

        $null = Invoke-Captured $entryFile @(".origin", "https") 0 "GitHub SSH to HTTPS"
        Assert-True (@(Get-OriginUrls $path)[0] -eq "https://github.com/acme/widget.git") "GitHub HTTPS conversion should update origin."
    }
}

function Test-GitLabNestedGroupRoundTrip {
    param([string]$TempRoot)

    $path = New-TestRepository $TempRoot "https://gitlab.com/group/subgroup/widget.git"
    Invoke-InRepository $path {
        $null = Invoke-Captured $entryFile @(".origin", "ssh") 0 "GitLab HTTPS to SSH"
        Assert-True (@(Get-OriginUrls $path)[0] -eq "git@gitlab.com:group/subgroup/widget.git") "GitLab SSH conversion should preserve nested groups."

        $null = Invoke-Captured $entryFile @(".origin", "https") 0 "GitLab SSH to HTTPS"
        Assert-True (@(Get-OriginUrls $path)[0] -eq "https://gitlab.com/group/subgroup/widget.git") "GitLab HTTPS conversion should preserve nested groups."
    }
}

function Test-EnterpriseHostRoundTrip {
    param([string]$TempRoot)

    $path = New-TestRepository $TempRoot "https://code.example.com/group/subgroup/widget.git"
    Invoke-InRepository $path {
        $null = Invoke-Captured $entryFile @(".origin", "ssh") 0 "enterprise host HTTPS to SSH"
        Assert-True (@(Get-OriginUrls $path)[0] -eq "git@code.example.com:group/subgroup/widget.git") "origin URL rewriting should preserve an enterprise host without provider detection."

        $null = Invoke-Captured $entryFile @(".origin", "https") 0 "enterprise host SSH to HTTPS"
        Assert-True (@(Get-OriginUrls $path)[0] -eq "https://code.example.com/group/subgroup/widget.git") "enterprise origin URL rewriting should round-trip."
    }
}

function Test-OriginRewriteDoesNotPersistIdentityOrCredentials {
    param([string]$TempRoot)

    $path = New-TestRepository $TempRoot "https://code.example.com/acme/widget.git"
    Invoke-InRepository $path {
        git config --local user.name "Repository User"
        Assert-ExitCode $LASTEXITCODE 0 "set repository user.name"
        git config --local credential.namespace "repository-namespace"
        Assert-ExitCode $LASTEXITCODE 0 "set repository credential namespace"

        $null = Invoke-Captured $entryFile @(".origin", "ssh") 0 "origin rewrite without identity persistence"

        $name = (& git config --local --get user.name | Out-String).Trim()
        $namespace = (& git config --local --get credential.namespace | Out-String).Trim()
        Assert-True ($name -eq "Repository User") "origin URL rewriting must not persist or replace the repository identity."
        Assert-True ($namespace -eq "repository-namespace") "origin URL rewriting must not persist or replace repository credentials."
        Assert-True (@(Get-OriginUrls $path)[0] -eq "git@code.example.com:acme/widget.git") "origin URL rewriting should still update the single origin URL."
    }
}

function Test-SshUriConvertsToHttps {
    param([string]$TempRoot)

    $path = New-TestRepository $TempRoot "ssh://git@github.com/acme/widget.git"
    Invoke-InRepository $path {
        $null = Invoke-Captured $entryFile @(".origin", "https") 0 "GitHub SSH URI to HTTPS"
        Assert-True (@(Get-OriginUrls $path)[0] -eq "https://github.com/acme/widget.git") "SSH URI input should convert to standard HTTPS."
    }
}

function Test-UnsupportedHttpsDoesNotMutate {
    param([string]$TempRoot)

    $original = "https://alice@github.com/acme/widget.git"
    $path = New-TestRepository $TempRoot $original
    Invoke-InRepository $path {
        $null = Invoke-Captured $entryFile @(".origin", "ssh") 1 "credential-bearing HTTPS URL"
        Assert-True (@(Get-OriginUrls $path)[0] -eq $original) "unsupported HTTPS URL should not mutate origin."
    }
}

function Test-UnsupportedRemoteShapesDoNotMutate {
    param([string]$TempRoot)

    $cases = @(
        "https://github.com//acme/widget.git",
        "https://github.com/acme/widget.git/",
        "git@github.com:/acme/widget.git",
        "https://github.com/acme/widget.git?ref=main",
        "https://github.com/acme/widget.git#fragment",
        "https://github.com:8443/acme/widget.git",
        "ssh://git@github.com:2222/acme/widget.git",
        "git@github.com:widget.git",
        "https://github.com/acme/../widget.git",
        "https://github.com/acme\widget.git"
    )

    foreach ($original in $cases) {
        $path = New-TestRepository $TempRoot $original
        Invoke-InRepository $path {
            $null = Invoke-Captured $entryFile @(".origin", "ssh") 1 "unsupported origin URL shape"
            Assert-True (@(Get-OriginUrls $path)[0] -eq $original) "unsupported URL shape should not mutate origin: $original"
        }
    }
}

function Test-MultipleFetchUrlsAreRejected {
    param([string]$TempRoot)

    $first = "https://github.com/acme/widget.git"
    $path = New-TestRepository $TempRoot $first
    Invoke-InRepository $path {
        git config --local --add remote.origin.url "https://github.com/acme/widget-mirror.git"
        Assert-ExitCode $LASTEXITCODE 0 "add second fetch URL"
        $null = Invoke-Captured $entryFile @(".origin", "ssh") 1 "multiple fetch URLs"
        $urls = @(Get-OriginUrls $path)
        Assert-True ($urls.Count -eq 2) "multiple fetch URL rejection should preserve all URLs."
        Assert-True ($urls[0] -eq $first) "multiple fetch URL rejection should preserve the first URL."
    }
}

function Test-EmptyAdditionalFetchUrlIsRejected {
    param([string]$TempRoot)

    $original = "https://github.com/acme/widget.git"
    $path = New-TestRepository $TempRoot $original
    Invoke-InRepository $path {
        git config --local --add remote.origin.url " "
        Assert-ExitCode $LASTEXITCODE 0 "add blank fetch URL"
        $null = Invoke-Captured $entryFile @(".origin", "ssh") 1 "blank additional fetch URL"
        Assert-True (@(Get-OriginUrls $path)[0] -eq $original) "blank additional fetch URL rejection should not mutate origin."
    }
}

function Test-ExplicitPushUrlIsRejected {
    param([string]$TempRoot)

    $original = "https://github.com/acme/widget.git"
    $path = New-TestRepository $TempRoot $original
    Invoke-InRepository $path {
        git config --local remote.origin.pushurl "git@github.com:acme/widget.git"
        Assert-ExitCode $LASTEXITCODE 0 "set explicit push URL"
        $null = Invoke-Captured $entryFile @(".origin", "ssh") 1 "explicit push URL"
        Assert-True (@(Get-OriginUrls $path)[0] -eq $original) "push URL rejection should not mutate origin."
    }
}

function Test-EmptyExplicitPushUrlIsRejected {
    param([string]$TempRoot)

    $original = "https://github.com/acme/widget.git"
    $path = New-TestRepository $TempRoot $original
    Invoke-InRepository $path {
        git config --local remote.origin.pushurl " "
        Assert-ExitCode $LASTEXITCODE 0 "set blank explicit push URL"
        $null = Invoke-Captured $entryFile @(".origin", "ssh") 1 "blank explicit push URL"
        Assert-True (@(Get-OriginUrls $path)[0] -eq $original) "blank explicit push URL rejection should not mutate origin."
    }
}

function Test-MissingOriginIsRejected {
    param([string]$TempRoot)

    $path = New-TestRepository $TempRoot ""
    Invoke-InRepository $path {
        $null = Invoke-Captured $entryFile @(".origin", "ssh") 1 "missing origin"
        Assert-True (@(Get-OriginUrls $path).Count -eq 0) "missing origin rejection should not create origin."
    }
}

function Test-InvalidOriginCommandDoesNotMutate {
    param([string]$TempRoot)

    $original = "https://code.example.com/acme/widget.git"
    $path = New-TestRepository $TempRoot $original
    Invoke-InRepository $path {
        $output = Invoke-Captured $entryFile @(".origin", "unexpected") 1 "invalid origin command"
        Assert-True ($output.Contains(".origin ssh")) "invalid origin syntax should show the declarative command."
        Assert-True (@(Get-OriginUrls $path)[0] -eq $original) "invalid origin syntax should not mutate origin."
    }
}

function Test-NonRepositoryIsRejected {
    # A directory below temp_workspace is still part of the source repository.
    # Use a short-lived sibling for a genuine no-repository boundary test.
    $path = Join-Path (Split-Path $repoRoot -Parent) ("swaw-kit-remote-non-repo-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $path | Out-Null
    try {
        Invoke-InRepository $path {
            $null = Invoke-Captured $entryFile @(".origin", "https") 1 "non-repository"
        }
    } finally {
        Remove-TestDirectory $path
    }
}

$tempRoot = Join-Path $tempBase ("git-remote-protocol-smoke-" + [guid]::NewGuid().ToString("N"))
try {
    New-Item -ItemType Directory -Path $tempRoot | Out-Null
    Test-GitHubRoundTrip $tempRoot
    Test-GitLabNestedGroupRoundTrip $tempRoot
    Test-EnterpriseHostRoundTrip $tempRoot
    Test-OriginRewriteDoesNotPersistIdentityOrCredentials $tempRoot
    Test-SshUriConvertsToHttps $tempRoot
    Test-UnsupportedHttpsDoesNotMutate $tempRoot
    Test-UnsupportedRemoteShapesDoNotMutate $tempRoot
    Test-MultipleFetchUrlsAreRejected $tempRoot
    Test-EmptyAdditionalFetchUrlIsRejected $tempRoot
    Test-ExplicitPushUrlIsRejected $tempRoot
    Test-EmptyExplicitPushUrlIsRejected $tempRoot
    Test-MissingOriginIsRejected $tempRoot
    Test-InvalidOriginCommandDoesNotMutate $tempRoot
    Test-NonRepositoryIsRejected
} finally {
    Remove-TestDirectory $tempRoot
    Remove-SwawKitTestTemplateEntry -RepoRoot $repoRoot -EntryPath $entryFile
}
