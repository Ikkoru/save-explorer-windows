# Run with fault.ps1
#
# Proves a check fails: copies the module into the temp folder with one
# piece of text replaced (the fault), runs "Run tests.ps1" against the copy
# (-ModulePath), prints the checks that failed, and deletes the copy. The
# real module is never touched.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File "Tests\Run with fault.ps1" -Find '<text>' -Replace '<text>'
#
# -Find must occur exactly -Count times (default 1), or nothing runs: a
# fault that misses its target proves nothing. -Last replaces only the last
# occurrence, for text the module holds twice (the restore template's copy
# comes first).

param(
    [Parameter(Mandatory)][string]$Find,
    [string]$Replace = '',
    [int]$Count = 1,
    [switch]$Last
)

$ErrorActionPreference = 'Stop'
$module = Join-Path (Split-Path -Parent $PSScriptRoot) 'Explorer Windows Shared.psm1'
$text = [IO.File]::ReadAllText($module)
$found = ([regex]::Matches($text, [regex]::Escape($Find))).Count
if ($found -ne $Count) { throw "The text to replace occurs $found time(s), not $Count." }
if ($Last) {
    $i = $text.LastIndexOf($Find)
    $text = $text.Substring(0, $i) + $Replace + $text.Substring($i + $Find.Length)
} else {
    $text = $text.Replace($Find, $Replace)
}
$copy = Join-Path ([IO.Path]::GetTempPath()) ('fault-{0}.psm1' -f [guid]::NewGuid().ToString('N'))
try {
    [IO.File]::WriteAllText($copy, $text)
    $out = 'q' | powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'Run tests.ps1') -ModulePath $copy 2>&1
    $failed = @($out | Where-Object { "$_" -match '^FAIL' })
    $out | Where-Object { "$_" -match '^FAIL|checks passed|checks FAILED' } | ForEach-Object { "$_" }
    if ($failed.Count -eq 0) { Write-Warning 'No check failed: nothing guards the text that was replaced.' }
} finally {
    Remove-Item -LiteralPath $copy -ErrorAction SilentlyContinue
}
