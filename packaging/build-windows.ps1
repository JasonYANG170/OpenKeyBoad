param(
    [Parameter(Mandatory = $true)][string]$HidApi,
    [Parameter(Mandatory = $true)][string]$HidApiLicense,
    [string]$OutputDirectory = "dist/windows-x64"
)

$ErrorActionPreference = 'Stop'
$library = (Resolve-Path -LiteralPath $HidApi).Path
$license = (Resolve-Path -LiteralPath $HidApiLicense).Path
$project = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$stage = Join-Path $project $OutputDirectory
$windowsFeature = $env:FLUTTER_WINDOWS
$linuxFeature = $env:FLUTTER_LINUX
$macosFeature = $env:FLUTTER_MACOS
Push-Location $project
try {
    $env:FLUTTER_WINDOWS = 'false'
    $env:FLUTTER_LINUX = 'false'
    $env:FLUTTER_MACOS = 'false'
    flutter build web --release --no-web-resources-cdn
    if ($LASTEXITCODE) { throw 'Flutter web build failed' }
    New-Item -ItemType Directory -Force $stage, "$stage/web" | Out-Null
    Push-Location bridge
    try {
        dart pub get
        if ($LASTEXITCODE) { throw 'Dart bridge dependencies failed' }
        dart compile exe bin/main.dart -o "$stage/KeyboardControl.exe"
        if ($LASTEXITCODE) { throw 'Dart bridge build failed' }
    } finally { Pop-Location }
    Copy-Item -Recurse -Force 'build/web/*' "$stage/web"
    Copy-Item 'packaging/Start.cmd', 'packaging/Connect-Phone.cmd', 'README.md', 'README.en.md', 'LICENSE' $stage
    if(Test-Path 'firmware') { Copy-Item -Recurse -Force 'firmware' $stage }
    Copy-Item -LiteralPath $library -Destination "$stage/hidapi.dll"
    Copy-Item -LiteralPath $license -Destination "$stage/HIDAPI-LICENSE.txt"
    Compress-Archive -Path "$stage/*" -DestinationPath 'dist/OpenKeyBoad-Windows-x64.zip' -Force
} finally {
    $env:FLUTTER_WINDOWS = $windowsFeature
    $env:FLUTTER_LINUX = $linuxFeature
    $env:FLUTTER_MACOS = $macosFeature
    Pop-Location
}
