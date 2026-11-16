param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('load', 'protect')]
    [string]$Action,

    [Parameter(Mandatory = $true)]
    [string]$SessionPath
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

try {
    Add-Type -AssemblyName System.Security
    $inputPayload = [Console]::In.ReadLine()
    if ($null -eq $inputPayload) {
        throw 'INPUT'
    }
    $entropy = [Text.Encoding]::UTF8.GetBytes('AARPG-Gesture/session-v1')
    $directory = [IO.Path]::GetDirectoryName($SessionPath)

    if ($Action -eq 'load') {
        if (-not [IO.File]::Exists($SessionPath)) {
            [Console]::Out.WriteLine('Tk9ORQ==')
            exit 0
        }
        $protected = [Convert]::FromBase64String([IO.File]::ReadAllText($SessionPath))
        $clear = [Security.Cryptography.ProtectedData]::Unprotect(
            $protected, $entropy, [Security.Cryptography.DataProtectionScope]::CurrentUser)
        [Console]::Out.WriteLine([Convert]::ToBase64String($clear))
        exit 0
    }

    $clear = [Convert]::FromBase64String($inputPayload)
    $protected = [Security.Cryptography.ProtectedData]::Protect(
        $clear, $entropy, [Security.Cryptography.DataProtectionScope]::CurrentUser)
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $temporaryPath = $SessionPath + '.tmp'
    [IO.File]::WriteAllText($temporaryPath, [Convert]::ToBase64String($protected), [Text.Encoding]::ASCII)
    if ([IO.File]::Exists($SessionPath)) {
        [IO.File]::Replace($temporaryPath, $SessionPath, [System.Management.Automation.Language.NullString]::Value)
    } else {
        [IO.File]::Move($temporaryPath, $SessionPath)
    }
    [Console]::Out.WriteLine([Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes('OK')))
    exit 0
}
catch {
    [Console]::Error.WriteLine('DPAPI')
    exit 1
}
