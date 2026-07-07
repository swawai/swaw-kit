$ErrorActionPreference = "Stop"

$script:SmokeRepoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
$script:KitRoot = Join-Path $script:SmokeRepoRoot "_lib\ssh_remote_kit"

. (Join-Path $script:KitRoot "ssh_config.ps1")

function Assert-True {
    param(
        [Parameter(Mandatory=$true)] [bool]$Condition,
        [Parameter(Mandatory=$true)] [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Assert-Contains {
    param(
        [Parameter(Mandatory=$true)] [string]$Text,
        [Parameter(Mandatory=$true)] [string]$Expected,
        [Parameter(Mandatory=$true)] [string]$Message
    )

    Assert-True ($Text.Contains($Expected)) $Message
}

function Assert-NotContains {
    param(
        [Parameter(Mandatory=$true)] [string]$Text,
        [Parameter(Mandatory=$true)] [string]$Unexpected,
        [Parameter(Mandatory=$true)] [string]$Message
    )

    Assert-True (-not $Text.Contains($Unexpected)) $Message
}

function New-SmokeEntryFile {
    param([Parameter(Mandatory=$true)] [string]$Root)

    $entry = Join-Path $Root "vps1.cmd"
    $content = @'
@echo off
set "HOST=vps1"

goto :REMOTE_KIT_AFTER_SSH_CONFIG
# remote-kit ssh-config begin
Host %HOST%
  HostName A.example.invalid
  User userA
  Port 2222
  IdentityFile ~/.ssh/id_vps1
  ProxyCommand ssh -W %h:%p bastion
# remote-kit ssh-config end
:REMOTE_KIT_AFTER_SSH_CONFIG
'@

    [System.IO.File]::WriteAllText($entry, $content, [System.Text.UTF8Encoding]::new($false))
    return $entry
}

function New-SmokeMarkerlessEntryFile {
    param([Parameter(Mandatory=$true)] [string]$Root)

    $entry = Join-Path $Root "vps1.cmd"
    $content = @'
@echo off
set "HOST=vps1"

goto :REMOTE_KIT_AFTER_SSH_CONFIG
Host %HOST%
  HostName A.example.invalid
  User userA
  Port 2222
  IdentityFile ~/.ssh/id_vps1
  ProxyCommand ssh -W %h:%p bastion
:REMOTE_KIT_AFTER_SSH_CONFIG
'@

    [System.IO.File]::WriteAllText($entry, $content, [System.Text.UTF8Encoding]::new($false))
    return $entry
}

function Test-ExtractEmbeddedConfigExpandsEntryVariables {
    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("remote-kit-sshcfg-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

    try {
        $entry = New-SmokeEntryFile $tempRoot
        $oldHost = $env:HOST
        $oldUserProfile = $env:USERPROFILE
        $env:HOST = "vps1"
        $env:USERPROFILE = "C:\Users\Smoke User"

        $text = Get-RemoteKitEmbeddedSshConfigText -EntryFile $entry

        Assert-Contains $text "Host vps1" "embedded config should expand %HOST%."
        Assert-Contains $text "IdentityFile ~/.ssh/id_vps1" "embedded config should preserve native ssh_config home syntax."
        Assert-Contains $text "ProxyCommand ssh -W %h:%p bastion" "embedded config should preserve OpenSSH percent tokens."
        Assert-True (-not $text.Contains("remote-kit ssh-config begin")) "embedded config output should not include markers."
    } finally {
        $env:HOST = $oldHost
        $env:USERPROFILE = $oldUserProfile
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Test-ExtractMarkerlessGotoHereDocConfig {
    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("remote-kit-sshcfg-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

    try {
        $entry = New-SmokeMarkerlessEntryFile $tempRoot
        $oldHost = $env:HOST
        $env:HOST = "vps1"

        $text = Get-RemoteKitEmbeddedSshConfigText -EntryFile $entry

        Assert-Contains $text "Host vps1" "markerless goto here-doc should expand %HOST%."
        Assert-Contains $text "IdentityFile ~/.ssh/id_vps1" "markerless goto here-doc should preserve IdentityFile."
        Assert-Contains $text "ProxyCommand ssh -W %h:%p bastion" "markerless goto here-doc should preserve OpenSSH percent tokens."
        Assert-True (-not $text.Contains("goto :REMOTE_KIT_AFTER_SSH_CONFIG")) "markerless output should not include the goto line."
        Assert-True (-not $text.Contains(":REMOTE_KIT_AFTER_SSH_CONFIG")) "markerless output should not include the label line."
    } finally {
        if ($null -eq $oldHost) {
            Remove-Item Env:HOST -ErrorAction SilentlyContinue
        } else {
            $env:HOST = $oldHost
        }
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Test-RepoTemplateUsesHostOnlyPublicConfig {
    $entry = Join-Path $script:SmokeRepoRoot "vps1.cmd"
    $text = [System.IO.File]::ReadAllText($entry)

    Assert-Contains $text 'set "HOST=vps1"' "vps1 template should keep HOST as the public entry knob."
    Assert-True (-not $text.Contains("REMOTE_SSH_HOST")) "vps1 template should not require REMOTE_SSH_HOST."
    Assert-True (-not $text.Contains("REMOTE_SSH_CONFIG")) "vps1 template should not require REMOTE_SSH_CONFIG."
    Assert-True (-not $text.Contains("REMOTE_KEY")) "vps1 template should not require REMOTE_KEY."
    Assert-Contains $text "IdentityFile ~/.ssh/id_rsa" "vps1 template should keep IdentityFile inside ssh_config."
    Assert-True (-not $text.Contains("remote-kit ssh-config begin")) "vps1 template should not need a begin marker."
    Assert-True (-not $text.Contains("remote-kit ssh-config end")) "vps1 template should not need an end marker."
}

function Test-WriteEmbeddedConfigDoesNotInstallManagedInclude {
    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("remote-kit-sshcfg-" + [guid]::NewGuid().ToString("N"))
    $fakeProfile = Join-Path $tempRoot "profile"
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $fakeProfile -Force | Out-Null

    try {
        $entry = New-SmokeEntryFile $tempRoot
        $oldHost = $env:HOST
        $oldUserProfile = $env:USERPROFILE
        Remove-Item Env:HOST -ErrorAction SilentlyContinue
        $env:USERPROFILE = $fakeProfile

        $first = Write-RemoteKitEmbeddedSshConfig `
            -EntryFile $entry `
            -HostAlias "vps1" `
            -RepoRoot $tempRoot `
            -UserProfile $fakeProfile

        $second = Write-RemoteKitEmbeddedSshConfig `
            -EntryFile $entry `
            -HostAlias "vps1" `
            -RepoRoot $tempRoot `
            -UserProfile $fakeProfile

        Assert-True (Test-Path -LiteralPath $first.ConfigPath -PathType Leaf) "generated config should exist."
        Assert-True ($first.ConfigPath -eq $second.ConfigPath) "ensure should be idempotent for config path."

        $generated = [System.IO.File]::ReadAllText($first.ConfigPath)
        Assert-Contains $generated "Host vps1" "generated config should contain host alias."
        Assert-Contains $generated "HostName A.example.invalid" "generated config should contain HostName."
        Assert-True (-not (Test-Path -LiteralPath $first.UserConfigPath -PathType Leaf)) "write should not create user ssh config."
    } finally {
        if ($null -eq $oldHost) {
            Remove-Item Env:HOST -ErrorAction SilentlyContinue
        } else {
            $env:HOST = $oldHost
        }
        $env:USERPROFILE = $oldUserProfile
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Test-InstallEmbeddedConfigWritesGeneratedConfigAndManagedInclude {
    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("remote-kit-sshcfg-" + [guid]::NewGuid().ToString("N"))
    $fakeProfile = Join-Path $tempRoot "profile"
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $fakeProfile -Force | Out-Null

    try {
        $entry = New-SmokeEntryFile $tempRoot
        $oldHost = $env:HOST
        $oldUserProfile = $env:USERPROFILE
        Remove-Item Env:HOST -ErrorAction SilentlyContinue
        $env:USERPROFILE = $fakeProfile

        $first = Install-RemoteKitEmbeddedSshConfig `
            -EntryFile $entry `
            -HostAlias "vps1" `
            -RepoRoot $tempRoot `
            -UserProfile $fakeProfile

        $second = Install-RemoteKitEmbeddedSshConfig `
            -EntryFile $entry `
            -HostAlias "vps1" `
            -RepoRoot $tempRoot `
            -UserProfile $fakeProfile

        Assert-True (Test-Path -LiteralPath $first.ConfigPath -PathType Leaf) "generated config should exist."
        Assert-True ($first.ConfigPath -eq $second.ConfigPath) "install should be idempotent for config path."

        $userConfig = [System.IO.File]::ReadAllText($first.UserConfigPath)
        $markerCount = ([regex]::Matches($userConfig, [regex]::Escape($script:RemoteKitSshConfigIncludeId))).Count
        Assert-True ($markerCount -eq 1) "managed Include marker should be written once."
        Assert-Contains $userConfig 'Include "' "managed Include should quote the generated config path."
        Assert-Contains $userConfig "host=vps1" "managed Include should record the host alias."
    } finally {
        if ($null -eq $oldHost) {
            Remove-Item Env:HOST -ErrorAction SilentlyContinue
        } else {
            $env:HOST = $oldHost
        }
        $env:USERPROFILE = $oldUserProfile
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Test-ManagedIncludeIsPrependedAndHostMatchIsExact {
    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("remote-kit-sshcfg-" + [guid]::NewGuid().ToString("N"))
    $fakeProfile = Join-Path $tempRoot "profile"
    $sshDir = Join-Path $fakeProfile ".ssh"
    New-Item -ItemType Directory -Path $sshDir -Force | Out-Null

    try {
        $entry = New-SmokeEntryFile $tempRoot
        $oldUserProfile = $env:USERPROFILE
        $env:USERPROFILE = $fakeProfile

        $existingConfig = @"
Include "D:/old/vps10.config" # win-run-toolbox host=vps10 id=$script:RemoteKitSshConfigIncludeId
Host github.com
  User git
"@
        [System.IO.File]::WriteAllText((Join-Path $sshDir "config"), $existingConfig, [System.Text.UTF8Encoding]::new($false))

        $result = Install-RemoteKitEmbeddedSshConfig `
            -EntryFile $entry `
            -HostAlias "vps1" `
            -RepoRoot $tempRoot `
            -UserProfile $fakeProfile

        $userConfig = [System.IO.File]::ReadAllText($result.UserConfigPath)
        $includeIndex = $userConfig.IndexOf("host=vps1")
        $hostBlockIndex = $userConfig.IndexOf("Host github.com")

        Assert-True ($includeIndex -ge 0) "managed Include for vps1 should be present."
        Assert-True ($includeIndex -lt $hostBlockIndex) "managed Include should be before existing Host blocks."
        Assert-Contains $userConfig "host=vps10" "managed Include removal should not treat vps1 as matching vps10."
    } finally {
        $env:USERPROFILE = $oldUserProfile
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Test-RemoveEmbeddedConfigRemovesManagedIncludeAndGeneratedFile {
    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("remote-kit-sshcfg-" + [guid]::NewGuid().ToString("N"))
    $fakeProfile = Join-Path $tempRoot "profile"
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $fakeProfile -Force | Out-Null

    try {
        $entry = New-SmokeEntryFile $tempRoot
        $oldUserProfile = $env:USERPROFILE
        $env:USERPROFILE = $fakeProfile

        $installed = Install-RemoteKitEmbeddedSshConfig `
            -EntryFile $entry `
            -HostAlias "vps1" `
            -RepoRoot $tempRoot `
            -UserProfile $fakeProfile

        Remove-RemoteKitEmbeddedSshConfig `
            -HostAlias "vps1" `
            -RepoRoot $tempRoot `
            -UserProfile $fakeProfile

        Assert-True (-not (Test-Path -LiteralPath $installed.ConfigPath -PathType Leaf)) "remove should delete generated config file."
        $userConfig = [System.IO.File]::ReadAllText($installed.UserConfigPath)
        Assert-NotContains $userConfig "host=vps1" "remove should delete the managed Include for vps1."
    } finally {
        $env:USERPROFILE = $oldUserProfile
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

try {
    Test-ExtractEmbeddedConfigExpandsEntryVariables
    Test-ExtractMarkerlessGotoHereDocConfig
    Test-WriteEmbeddedConfigDoesNotInstallManagedInclude
    Test-InstallEmbeddedConfigWritesGeneratedConfigAndManagedInclude
    Test-ManagedIncludeIsPrependedAndHostMatchIsExact
    Test-RemoveEmbeddedConfigRemovesManagedIncludeAndGeneratedFile
    Test-RepoTemplateUsesHostOnlyPublicConfig
    Write-Host "ssh remote kit ssh-config smoke ok" -ForegroundColor Green
} finally {
}
