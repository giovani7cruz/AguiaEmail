param(
  [string]$Lazarus = 'C:\lazarus',
  [string]$ACBr = (Join-Path $PSScriptRoot '..\..\Delphi\Componentes\ACBr'),
  [string]$CaBundle = 'C:\Program Files\Git\mingw64\etc\ssl\certs\ca-bundle.crt',
  [string]$FbClient = 'C:\Program Files\Firebird\Firebird_5_0\fbclient.dll'
)
$ErrorActionPreference = 'Stop'
$bin = Join-Path $PSScriptRoot 'bin'
$lib = Join-Path $PSScriptRoot 'lib'
New-Item -ItemType Directory -Force $bin, $lib | Out-Null
$project = Join-Path $PSScriptRoot 'source\AguiaEmail.lpi'
[xml]$options = Get-Content -LiteralPath $project
$baseUri = [Uri]((Split-Path $project).TrimEnd('\')+'\')
$synapseUri = [Uri](Resolve-Path (Join-Path $ACBr 'Fontes\Terceiros\synalist')).Path
$options.CONFIG.CompilerOptions.SearchPaths.OtherUnitFiles.Value = [Uri]::UnescapeDataString($baseUri.MakeRelativeUri($synapseUri).ToString())
$options.Save($project)
$log = Join-Path $lib 'build-windows.log'
& (Join-Path $Lazarus 'lazbuild.exe') --pcp="$(Join-Path $PSScriptRoot '.lazcfg')" --ws=nogui $project *> $log
if ($LASTEXITCODE -ne 0) { Get-Content $log -Tail 30; throw 'Falha ao compilar AguiaEmail.' }
Copy-Item (Join-Path $ACBr 'DLLs\OpenSSL\3.1.3\x64\*.dll') $bin -Force
if (-not (Test-Path -LiteralPath $FbClient)) { throw 'Informe -FbClient com a biblioteca Firebird x64.' }
Copy-Item -LiteralPath $FbClient -Destination (Join-Path $bin 'fbclient.dll') -Force
if (-not (Test-Path -LiteralPath $CaBundle)) { throw 'Informe -CaBundle com um pacote PEM confiavel de autoridades certificadoras.' }
Copy-Item -LiteralPath $CaBundle -Destination (Join-Path $bin 'cacert.pem') -Force
Get-Item (Join-Path $bin 'AguiaEmail.exe') | Select-Object Name,Length,LastWriteTime

