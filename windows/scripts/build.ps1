param([switch]$Test)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$msbuild = Get-Command msbuild.exe -ErrorAction SilentlyContinue
if ($msbuild) {
    $builder = $msbuild.Source
} else {
    $locator = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (Test-Path $locator) {
        $builder = & $locator -latest -products '*' -requires Microsoft.Component.MSBuild -find 'MSBuild\**\Bin\MSBuild.exe' | Select-Object -First 1
    }
}
if (!$builder) { throw 'Install Visual Studio Build Tools with MSBuild and the .NET Framework 4.8 targeting pack.' }
& $builder (Join-Path $root 'Perch.Windows.csproj') /p:Configuration=Release /nologo
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
if ($Test) {
    & $builder (Join-Path $root 'tests\Checks.csproj') /nologo
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    & (Join-Path $root 'tests\bin\DeskToys.Checks.exe')
    exit $LASTEXITCODE
}
