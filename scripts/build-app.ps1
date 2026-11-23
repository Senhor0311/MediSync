param(
  [Parameter(Mandatory=$true)][ValidateSet('live','emulator')][string]$Environment,
  [ValidateSet('all','web','android')][string]$Target='all'
)
$ErrorActionPreference='Stop'
$repoRoot=[IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent))
Set-Location -LiteralPath $repoRoot
& node scripts/web-security-policy.mjs $Environment | Out-Null
if($LASTEXITCODE -ne 0){throw 'CSP SDK verification failed'}
if($Environment -eq 'live' -and ($env:FIRESTORE_EMULATOR_HOST -or $env:FIREBASE_AUTH_EMULATOR_HOST -or $env:GCLOUD_PROJECT -like 'demo-*')) {throw 'Use a clean terminal for live builds. No emulator environment variables are allowed.'}
$mode=if($Environment -eq 'live'){'--release'}else{'--debug'}
$destination=Join-Path $repoRoot "build\$Environment"
New-Item -ItemType Directory -Force -Path $destination | Out-Null
if($Target -in @('all','android')){
  & flutter build apk $mode "--dart-define=FIREBASE_ENV=$Environment"
  if($LASTEXITCODE -ne 0){throw 'Android build failed'}
  $suffix=if($Environment -eq 'live'){'release'}else{'debug'}
  Copy-Item -LiteralPath "build\app\outputs\flutter-apk\app-$suffix.apk" -Destination (Join-Path $destination "medisync-$Environment.apk") -Force
}
if($Target -in @('all','web')){
  & flutter build web $mode --no-web-resources-cdn "--dart-define=FIREBASE_ENV=$Environment"
  if($LASTEXITCODE -ne 0){throw 'Web build failed'}
  $webDestination=[IO.Path]::GetFullPath((Join-Path $destination 'web'))
  if(!$webDestination.StartsWith($repoRoot+'\build\',[StringComparison]::OrdinalIgnoreCase)){throw 'Invalid build output path'}
  if(Test-Path -LiteralPath $webDestination){Remove-Item -LiteralPath $webDestination -Recurse -Force}
  Copy-Item -LiteralPath (Join-Path $repoRoot 'build\web') -Destination $webDestination -Recurse
  if($Environment -eq 'live'){
    $indexPath=Join-Path $webDestination 'index.html'
    $index=[IO.File]::ReadAllText($indexPath)
    $policy=(& node scripts/web-security-policy.mjs live)
    if($LASTEXITCODE -ne 0){throw 'CSP SDK verification failed'}
    $index=[regex]::Replace($index,'(<meta http-equiv="Content-Security-Policy" content=")[^"]*(">)','$1'+$policy+'$2')
    $index=[regex]::Replace($index,'<!-- This application is emulator-only[\s\S]*?-->','<!-- Explicit live Firebase connection policy. -->')
    $index=[regex]::Replace($index,'<!-- The app renders a persistent[\s\S]*?\.firebase-emulator-warning[\s\S]*?</style>','')
    [IO.File]::WriteAllText($indexPath,$index,[Text.UTF8Encoding]::new($false))
    $bundle=[IO.File]::ReadAllText((Join-Path $webDestination 'main.dart.js'))
    foreach($forbidden in @('demo-medisync-v3','10.0.2.2','fake-api-key','127.0.0.1:8080','127.0.0.1:9099')){
      if($bundle.Contains($forbidden) -or $index.Contains($forbidden)){throw "Live output contains forbidden emulator configuration: $forbidden"}
    }
  }
}
Write-Output "Builds prepared in $destination. Emulator APKs use debug signing; production Android releases require owner signing. Nothing was deployed."
