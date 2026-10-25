Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$usage = @'
Usage: lykta COMMAND

  setup URL TOKEN   Save the gateway URL and agent token, check them and print the skill
  docs FILE...      Print skill files, such as references/layout.md examples/printer.json
  put PATH [FILE]   PUT the JSON in FILE, or piped in, to /v1/PATH and wait for Apple's answer
  get PATH          GET /v1/PATH, such as activities/deploy or actions?wait=25
  delete PATH       DELETE /v1/PATH, such as activities/deploy?dismissAfter=0
  media FILE        Upload an image or sound and print its id

LYKTA_URL and LYKTA_TOKEN take precedence over the setup saved in ~/.config/lykta.
Exit status: 0 done, 1 the gateway refused the request, 2 usage or setup error,
3 the gateway was unreachable or failed.
'@

function Fail([string]$Message, [int]$Code) {
    [Console]::Error.WriteLine("lykta: $Message")
    exit $Code
}

$onWindows = [Environment]::OSVersion.Platform -eq 'Win32NT'
$configHome = if ($env:XDG_CONFIG_HOME) { $env:XDG_CONFIG_HOME } else { Join-Path $HOME '.config' }
$config = Join-Path $configHome 'lykta'
$url = $null
$token = $null

function Read-Setting([string]$Variable, [string]$File) {
    $value = [Environment]::GetEnvironmentVariable($Variable)
    $path = Join-Path $config $File
    if (-not $value -and (Test-Path -LiteralPath $path)) { $value = ([string](Get-Content -LiteralPath $path -Raw)).Trim() }
    $value
}

function Import-Setup {
    $script:url = Read-Setting 'LYKTA_URL' 'url'
    $script:token = Read-Setting 'LYKTA_TOKEN' 'token'
    if (-not $script:url -or -not $script:token) {
        Fail 'not set up; run lykta setup URL TOKEN with the setup the user copied from the Lykta app, or set LYKTA_URL and LYKTA_TOKEN' 2
    }
    $script:url = $script:url.TrimEnd('/')
}

Add-Type -AssemblyName System.Net.Http
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$client = [System.Net.Http.HttpClient]::new()
$client.Timeout = [TimeSpan]::FromSeconds(90)

function Test-Refused($Exception) {
    for ($cause = $Exception; $cause; $cause = $cause.InnerException) {
        if ($cause -is [System.Net.Sockets.SocketException] -and $cause.SocketErrorCode -eq 'ConnectionRefused') { return $true }
        if ($cause -is [System.Net.WebException] -and $cause.Status -eq 'ConnectFailure') { return $true }
    }
    $false
}

function Invoke-Gateway([string]$Method, [string]$Target, [scriptblock]$Content) {
    for ($attempt = 1; ; $attempt++) {
        $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::new($Method), "$url$Target")
        $request.Headers.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $token)
        if ($Content) { $request.Content = & $Content }
        try {
            $response = $client.SendAsync($request).GetAwaiter().GetResult()
            break
        } catch {
            $cause = $_.Exception
            if ($attempt -lt 5 -and (Test-Refused $cause)) {
                [Console]::Error.WriteLine("lykta: $url refused the connection; retrying")
                Start-Sleep -Seconds 2
                continue
            }
            if ($cause.GetBaseException() -is [System.TimeoutException] -or $cause.GetBaseException() -is [System.Threading.Tasks.TaskCanceledException]) {
                Fail "$url did not answer within 90 seconds; read the result with lykta get before sending again" 3
            }
            Fail "could not reach ${url}: $($cause.GetBaseException().Message); it may be restarting, so retry in a few seconds" 3
        }
    }
    $text = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    $status = [int]$response.StatusCode
    if ($status -ge 200 -and $status -lt 300) { return $text }
    if ($status -lt 500) {
        [Console]::Error.WriteLine("lykta: $Method $Target was refused with HTTP ${status}:`n$text")
        exit 1
    }
    [Console]::Error.WriteLine("lykta: $Method $Target failed with HTTP ${status}:`n$text")
    exit 3
}

function Get-ApiPath([string]$Path) {
    $trimmed = $Path.TrimStart('/')
    if ($trimmed.StartsWith('v1/')) { $trimmed = $trimmed.Substring(3) }
    "/v1/$trimmed"
}

function Write-Text([string]$Text) {
    Write-Output $Text
}

function Invoke-Setup([string[]]$Arguments) {
    if ($Arguments.Count -ne 2) { Fail 'usage: lykta setup URL TOKEN' 2 }
    $script:url = $Arguments[0].TrimEnd('/')
    $script:token = $Arguments[1]
    if (-not ($url.StartsWith('https://') -or $url.StartsWith('http://'))) { Fail 'the URL must start with https:// or http://' 2 }
    $null = Invoke-Gateway 'GET' '/v1/activities'
    try {
        $null = New-Item -ItemType Directory -Force -Path $config
        $utf8 = [Text.UTF8Encoding]::new($false)
        [IO.File]::WriteAllText((Join-Path $config 'url'), "$url`n", $utf8)
        [IO.File]::WriteAllText((Join-Path $config 'token'), "$token`n", $utf8)
        if (-not $onWindows) { chmod 700 $config; chmod 600 (Join-Path $config 'token') }
    } catch {
        Fail "could not save the setup in ${config}: $($_.Exception.Message)" 2
    }
    $run = $PSCommandPath
    if ($onWindows) {
        try {
            $share = Join-Path $HOME '.local\share\lykta'
            $bin = Join-Path $HOME '.local\bin'
            $null = New-Item -ItemType Directory -Force -Path $share, $bin
            if ($PSCommandPath -ne (Join-Path $share 'lykta.ps1')) { Copy-Item -LiteralPath $PSCommandPath -Destination (Join-Path $share 'lykta.ps1') -Force }
            $launcher = '@powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\share\lykta\lykta.ps1" %*'
            [IO.File]::WriteAllText((Join-Path $bin 'lykta.cmd'), "$launcher`r`n", [Text.Encoding]::ASCII)
            $run = Join-Path $bin 'lykta.cmd'
        } catch {
            Fail "could not install lykta in ~\.local: $($_.Exception.Message)" 2
        }
    }
    $found = Get-Command lykta -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($found -and $found.Source -eq $run) { $run = 'lykta' }
    elseif ($run.StartsWith($HOME)) { $run = '~' + $run.Substring($HOME.Length) }
    Write-Text "Lykta is set up for $url. Run it as $run.`n"
    Write-Text (Invoke-Gateway 'GET' '/skill/SKILL.md')
}

function Invoke-Docs([string[]]$Names) {
    if ($Names.Count -eq 0) { Fail 'usage: lykta docs FILE..., such as lykta docs references/layout.md' 2 }
    foreach ($name in $Names) {
        if ($Names.Count -gt 1) { Write-Text "==> $name <==" }
        Write-Text (Invoke-Gateway 'GET' "/skill/$($name.TrimStart('/'))")
    }
}

function Invoke-Put([string[]]$Arguments, $Piped) {
    if ($Arguments.Count -lt 1 -or $Arguments.Count -gt 2) { Fail 'usage: lykta put PATH [FILE], with the JSON body in FILE or piped in' 2 }
    if ($Arguments.Count -eq 2) {
        try { $body = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $Arguments[1]).ProviderPath) }
        catch { Fail "could not read $($Arguments[1])" 2 }
    } elseif ($Piped.Count -gt 0) {
        $body = $Piped -join "`n"
    } elseif ([Console]::IsInputRedirected) {
        [Console]::InputEncoding = [Text.UTF8Encoding]::new($false)
        $body = [Console]::In.ReadToEnd()
    } else {
        Fail 'pipe the JSON body in, such as from a here-string, or name a file' 2
    }
    $path = Get-ApiPath $Arguments[0]
    $path += if ($path.Contains('?')) { '&wait=10' } else { '?wait=10' }
    Write-Text (Invoke-Gateway 'PUT' $path { [System.Net.Http.StringContent]::new($body, [Text.UTF8Encoding]::new($false), 'application/json') })
}

function Invoke-Media([string[]]$Arguments) {
    if ($Arguments.Count -ne 1) { Fail 'usage: lykta media FILE' 2 }
    try { $bytes = [IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $Arguments[0]).ProviderPath) }
    catch { Fail "could not read $($Arguments[0])" 2 }
    $answer = Invoke-Gateway 'POST' '/v1/media' { [System.Net.Http.ByteArrayContent]::new($bytes) }
    $id = ($answer | ConvertFrom-Json).id
    if (-not $id) { Fail "the gateway answered without a media id: $answer" 3 }
    Write-Text $id
}

$piped = @($input)
$verb = if ($args.Count -gt 0) { [string]$args[0] } else { '' }
$rest = [string[]]@($args | Select-Object -Skip 1)
switch ($verb) {
    'setup' { Invoke-Setup $rest }
    'docs' { Import-Setup; Invoke-Docs $rest }
    'put' { Import-Setup; Invoke-Put $rest $piped }
    'get' { if ($rest.Count -ne 1) { Fail 'usage: lykta get PATH' 2 }; Import-Setup; Write-Text (Invoke-Gateway 'GET' (Get-ApiPath $rest[0])) }
    'delete' { if ($rest.Count -ne 1) { Fail 'usage: lykta delete PATH' 2 }; Import-Setup; Write-Text (Invoke-Gateway 'DELETE' (Get-ApiPath $rest[0])) }
    'media' { Import-Setup; Invoke-Media $rest }
    { $_ -in 'help', '-h', '--help' } { Write-Text $usage }
    '' { [Console]::Error.WriteLine($usage); exit 2 }
    default { [Console]::Error.WriteLine($usage); Fail "unknown command $verb" 2 }
}
