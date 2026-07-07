$ErrorActionPreference = "Stop"

$script:RepoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
$script:KitRoot = Join-Path $script:RepoRoot "_lib\ssh_remote_kit"

. (Join-Path $script:KitRoot "ps_common.ps1")
. (Join-Path $script:KitRoot "script_runner.openssh.ps1")

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

function Initialize-DummyContext {
    param(
        [string]$SshConfigPath = "",
        [string]$SshHostAlias = ""
    )

    $params = @{
        Port = 2222
        RemoteHost = "example.invalid"
        RemoteUser = "root"
        SshKeyPath = "C:\keys with spaces\id_rsa"
        ModuleRoot = $script:KitRoot
        UploadSubdir = "smoke_script_runner"
    }

    if (-not [string]::IsNullOrWhiteSpace($SshConfigPath)) {
        $params.SshConfigPath = $SshConfigPath
    }

    if (-not [string]::IsNullOrWhiteSpace($SshHostAlias)) {
        $params.SshHostAlias = $SshHostAlias
    }

    [void](Initialize-RemoteKitContext @params)
}

function Test-PayloadEmbedsScriptAndArgsForSingleSshConnection {
    $content = "#!/usr/bin/env bash`r`necho script-ok`r`n"
    $payload = New-RemoteKitScriptRunnerOpenSshPayload `
        -ScriptContent $content `
        -ScriptArgs @("alpha", "two words", "quote'value") `
        -Token "SMOKE_TOKEN"

    Assert-Contains $payload "cat > `"`$script_path`" <<'REMOTE_KIT_SMOKE_TOKEN_SCRIPT'" "payload should write script via heredoc."
    Assert-Contains $payload "echo script-ok" "payload should contain local script content."
    $expectedRun = @'
bash "$script_path" 'alpha' 'two words' 'quote'"'"'value'
'@.Trim()
    Assert-Contains $payload $expectedRun "payload should shell-quote forwarded script args."
    Assert-Contains $payload "trap cleanup EXIT" "payload should clean remote temp files."
    Assert-True (-not $payload.Contains("`r")) "payload should use LF line endings."
}

function Test-ScriptRunnerArgsAllowOneConnectionPasswordFallback {
    Initialize-DummyContext

    $args = @(New-RemoteKitScriptRunnerOpenSshArgs)
    $joined = $args -join " "

    Assert-Contains $joined "-o BatchMode=no" "script runner should allow one OpenSSH password prompt path."
    Assert-Contains $joined "-o PreferredAuthentications=publickey,password,keyboard-interactive" "script runner should try public key then password-compatible auth."
    Assert-Contains $joined "-p 2222" "script runner should include direct host port."
    Assert-Contains $joined "root@example.invalid" "script runner should include direct remote target."
    Assert-True ($args[-1] -eq "bash -s") "script runner should execute one remote bash stdin command."
    Assert-True (-not ($args -contains "-n")) "script runner must not close stdin."
}

function Test-ConfigHostArgsUseConfigAliasWithoutDirectOverrides {
    Initialize-DummyContext -SshConfigPath "D:\repo data\vps1.config" -SshHostAlias "vps1"

    $args = @(New-RemoteKitScriptRunnerOpenSshArgs)
    $joined = $args -join " "

    Assert-Contains $joined "-F D:\repo data\vps1.config" "config host mode should pass generated ssh config."
    Assert-Contains $joined "vps1 bash -s" "config host mode should use the Host alias as target."
    Assert-True (-not ($args -contains "-i")) "config host mode should not override IdentityFile with -i."
    Assert-True (-not ($args -contains "-p")) "config host mode should not override Port with -p."
    Assert-True (-not $joined.Contains("root@example.invalid")) "config host mode should not build user@host target."
}

function Test-PuttyFallbackCodeIsRemoved {
    $scriptRunner = [System.IO.File]::ReadAllText((Join-Path $script:KitRoot "script_runner.ps1"))
    $common = [System.IO.File]::ReadAllText((Join-Path $script:KitRoot "ps_common.ps1"))

    foreach ($needle in @("PuTTY", "plink", "pscp", "pwfile")) {
        Assert-True (-not $scriptRunner.Contains($needle)) "script_runner should not keep $needle fallback code."
        Assert-True (-not $common.Contains($needle)) "ps_common should not keep $needle helper code."
    }
}

try {
    Test-PayloadEmbedsScriptAndArgsForSingleSshConnection
    Test-ScriptRunnerArgsAllowOneConnectionPasswordFallback
    Test-ConfigHostArgsUseConfigAliasWithoutDirectOverrides
    Test-PuttyFallbackCodeIsRemoved
    Write-Host "ssh remote kit script-runner smoke ok" -ForegroundColor Green
} finally {
    $ctx = $null
    try { $ctx = Get-RemoteKitContext } catch { }
    if ($ctx -and (Test-Path -LiteralPath $ctx.TempWorkspaceRoot)) {
        Remove-Item -LiteralPath $ctx.TempWorkspaceRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
