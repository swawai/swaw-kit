Set-StrictMode -Version 2.0

@{
    Name = 'uv'
    Install = {
        param($Context, $Definition, $Plan, $Dependencies)

        Install-XvenvArchiveDefinition -Context $Context -Definition $Definition
    }
}
