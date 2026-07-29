Set-StrictMode -Version 2.0

function Show-SshAccessHelp {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Context,

        [ValidateSet('zh', 'en')]
        [string]$Language = 'zh'
    )

    $FileName = if ($Language -eq 'en') { 'en-US.txt' } else { 'zh-CN.txt' }
    $HelpPath = Join-Path $Context.HelpRoot $FileName
    if (-not (Test-Path -LiteralPath $HelpPath -PathType Leaf)) {
        throw "Help template not found: $HelpPath"
    }

    $Text = [IO.File]::ReadAllText($HelpPath, [Text.Encoding]::UTF8)
    $Text = $Text.Replace('{{COMMAND}}', $Context.CommandName)
    $Text = $Text.Replace('{{ENTRY_FILE}}', $Context.EntryFileName)
    Write-Host $Text
}
