Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$usage = @'
Usage: lykta COMMAND

  setup URL TOKEN   Save the gateway URL and agent token, check them, install lykta and print the skill
  install DIR       Install the skill as DIR/lykta, such as ~/.claude/skills, and keep it current
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
$cli = [IO.Path]::Combine($HOME, '.local', 'share', 'lykta', 'lykta.ps1')
$url = $null
$token = $null
$served = $null

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
$handler = [System.Net.Http.HttpClientHandler]::new()
$handler.AllowAutoRedirect = $false
$client = [System.Net.Http.HttpClient]::new($handler)
$client.Timeout = [TimeSpan]::FromSeconds(90)

function Get-Served($Response) {
    $values = $null
    if ($Response.Headers.TryGetValues('lykta-skill', [ref]$values)) {
        $value = @($values)[0]
        if ($value -match '^[0-9a-f]{64}$') { return $value }
    }
    $null
}

function Test-Link([string]$Path) {
    [bool]((Get-Item -LiteralPath $Path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)
}

function Get-Stamp([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf) -or (Test-Link $Path)) { return $null }
    $last = Get-Content -LiteralPath $Path -Tail 1
    if ($last -match 'lykta-skill ([0-9a-f]{64})') { return $Matches[1] }
    $null
}

function Set-SkillFile([string]$Name, [string]$Path, [string]$Format) {
    $temp = Join-Path (Split-Path -Parent $Path) ".$(Split-Path -Leaf $Path).$([IO.Path]::GetRandomFileName())"
    $cancel = [Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds(10))
    try {
        $response = $client.GetAsync("$url/skill/$Name", $cancel.Token).GetAwaiter().GetResult()
        $digest = Get-Served $response
        if (-not $response.IsSuccessStatusCode -or -not $digest) { return $false }
        $script:served = $digest
        $bytes = $response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
        $stamped = [byte[]]($bytes + [Text.Encoding]::UTF8.GetBytes("`n$($Format -f $digest)`n"))
        $file = [IO.FileStream]::new($temp, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write)
        try { $file.Write($stamped, 0, $stamped.Length) } finally { $file.Dispose() }
        if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($temp, $Path, [NullString]::Value) } else { [IO.File]::Move($temp, $Path) }
        $true
    } catch {
        if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force }
        $false
    } finally {
        $cancel.Dispose()
    }
}

function Test-Saved {
    $path = Join-Path $config 'url'
    (Test-Path -LiteralPath $path) -and $url -ceq ([string](Get-Content -LiteralPath $path -Raw)).Trim()
}

function Update-File([string]$Name, [string]$Path, [string]$Format) {
    if (Set-SkillFile $Name $Path $Format) {
        [Console]::Error.WriteLine("lykta: updated $Path to the gateway's version")
        return $true
    }
    [Console]::Error.WriteLine("lykta: could not update $Path from $url; the next lykta command tries again")
    $false
}

function Update-Installs {
    $want = $served
    try {
        if (-not $want -or -not (Test-Saved)) { return }
        $stamp = Get-Stamp $cli
        if ($stamp -and $stamp -ne $want -and -not (Update-File 'scripts/lykta.ps1' $cli '# lykta-skill {0}')) { return }
        $registry = Join-Path $config 'skills'
        if (-not (Test-Path -LiteralPath $registry)) { return }
        foreach ($dir in @(Get-Content -LiteralPath $registry)) {
            if (-not $dir -or -not (Test-Path -LiteralPath $dir -PathType Container) -or (Test-Link $dir)) { continue }
            $skill = Join-Path $dir 'SKILL.md'
            $stamp = Get-Stamp $skill
            if ($stamp -and $stamp -ne $want -and -not (Update-File 'SKILL.md' $skill '<!-- lykta-skill {0} -->')) { return }
        }
    } catch {
        [Console]::Error.WriteLine("lykta: could not check the installed copies: $($_.Exception.Message); the next lykta command tries again")
    }
}

function Test-Refused($Exception) {
    for ($cause = $Exception; $cause; $cause = $cause.InnerException) {
        if ($cause -is [System.Net.Sockets.SocketException] -and $cause.SocketErrorCode -eq 'ConnectionRefused') { return $true }
        if ($cause -is [System.Net.WebException] -and $cause.Status -eq 'ConnectFailure') { return $true }
    }
    $false
}

function Invoke-Gateway([string]$Method, [string]$Target, [scriptblock]$Content) {
    $again = if ($Method -eq 'PUT') { 'it may have been applied, so read it with lykta get before sending it again' } else { 'retry in a few seconds' }
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
            if (Test-Refused $cause) { Fail "could not connect to $url, so nothing was sent; it may be restarting, so retry in a few seconds" 3 }
            Fail "$Method $Target got no answer from ${url}: $($cause.GetBaseException().Message); $again" 3
        }
    }
    $script:served = Get-Served $response
    $text = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    $status = [int]$response.StatusCode
    if ($status -ge 200 -and $status -lt 300) { return $text }
    if ($status -ge 400 -and $status -lt 500) {
        [Console]::Error.WriteLine("lykta: $Method $Target was refused with HTTP ${status}:`n$text")
        exit 1
    }
    [Console]::Error.WriteLine("lykta: $Method $Target failed with HTTP ${status}; ${again}:`n$text")
    exit 3
}

function Get-ApiPath([string]$Path) {
    $trimmed = $Path.TrimStart('/')
    if ($trimmed.StartsWith('v1/')) { $trimmed = $trimmed.Substring(3) }
    "/v1/$trimmed"
}

function Invoke-Setup([string[]]$Arguments) {
    if ($Arguments.Count -ne 2) { Fail 'usage: lykta setup URL TOKEN' 2 }
    $script:url = $Arguments[0].TrimEnd('/')
    $script:token = $Arguments[1]
    if (-not ($url.StartsWith('https://') -or $url.StartsWith('http://'))) { Fail 'the URL must start with https:// or http://' 2 }
    $null = Invoke-Gateway 'GET' '/v1/activities'
    try {
        $null = New-Item -ItemType Directory -Force -Path $config
        if ($onWindows) {
            $owner = [Security.AccessControl.DirectorySecurity]::new()
            $owner.SetAccessRuleProtection($true, $false)
            $owner.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.WindowsIdentity]::GetCurrent().User,
                'FullControl', 'ContainerInherit, ObjectInherit', 'None', 'Allow'))
            Set-Acl -LiteralPath $config -AclObject $owner
        } else {
            [IO.File]::SetUnixFileMode($config, 'UserRead, UserWrite, UserExecute')
        }
        $utf8 = [Text.UTF8Encoding]::new($false)
        $saved = Join-Path $config 'token'
        if (Test-Path -LiteralPath $saved) { Remove-Item -LiteralPath $saved -Force }
        [IO.File]::WriteAllText((Join-Path $config 'url'), "$url`n", $utf8)
        [IO.File]::WriteAllText($saved, "$token`n", $utf8)
        if (-not $onWindows) { [IO.File]::SetUnixFileMode($saved, 'UserRead, UserWrite') }
    } catch {
        Fail "could not save the setup in ${config}: $($_.Exception.Message)" 2
    }
    $share = Split-Path -Parent $cli
    try { $null = New-Item -ItemType Directory -Force -Path $share } catch { Fail "could not create ${share}: $($_.Exception.Message)" 2 }
    if (-not (Set-SkillFile 'scripts/lykta.ps1' $cli '# lykta-skill {0}')) {
        Fail "could not install lykta in $share from $url; a gateway older than 0.15.0 cannot, so run the setup the Lykta app copies, which downloads that gateway's own lykta" 3
    }
    $run = $cli
    if ($onWindows) {
        try {
            $bin = Join-Path $HOME '.local\bin'
            $null = New-Item -ItemType Directory -Force -Path $bin
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
    Write-Output "Lykta is set up for $url. Run it as $run.`n"
    Write-Output "Install this skill so later sessions have it: run $run install DIR with the folder your agent reads personal skills from, such as ~/.claude/skills for Claude Code or ~/.agents/skills for Codex, OpenCode and OpenClaw. Ask the user if you are unsure where your skills live.`n"
    Write-Output (Invoke-Gateway 'GET' '/skill/SKILL.md')
}

function Invoke-Install([string[]]$Arguments) {
    if ($Arguments.Count -ne 1) { Fail 'usage: lykta install DIR, with the folder your agent reads personal skills from, such as ~/.claude/skills' 2 }
    if (-not (Test-Saved)) { Fail 'install keeps the skill in step with the gateway saved by lykta setup URL TOKEN, so run that first' 2 }
    try { $parent = (New-Item -ItemType Directory -Force -Path $Arguments[0]).FullName } catch { Fail "could not create $($Arguments[0])" 2 }
    $dir = Join-Path $parent 'lykta'
    $skill = Join-Path $dir 'SKILL.md'
    $foreign = "$dir exists and lykta did not install it, so it was left alone; remove it or choose another folder"
    if (Test-Path -LiteralPath $dir) {
        if (Test-Link $dir) { Fail $foreign 2 }
        Get-ChildItem -LiteralPath $dir -Filter '.SKILL.md.*' -Force | Remove-Item -Force
        if (-not (Get-ChildItem -LiteralPath $dir -Force)) { Remove-Item -LiteralPath $dir -Force }
        elseif (-not (Get-Stamp $skill)) { Fail $foreign 2 }
    }
    try { $null = New-Item -ItemType Directory -Force -Path $dir } catch { Fail "could not create $dir" 2 }
    if (-not (Set-SkillFile 'SKILL.md' $skill '<!-- lykta-skill {0} -->')) {
        if (-not (Get-ChildItem -LiteralPath $dir -Force)) { Remove-Item -LiteralPath $dir -Force }
        Fail "could not download the skill from $url, or the gateway is older than 0.15.0 and cannot keep installed copies current" 3
    }
    $registry = Join-Path $config 'skills'
    try {
        if (-not ((Test-Path -LiteralPath $registry) -and @(Get-Content -LiteralPath $registry) -ccontains $dir)) {
            [IO.File]::AppendAllText($registry, "$dir`n", [Text.UTF8Encoding]::new($false))
        }
    } catch { Fail "could not record $dir in ${registry}: $($_.Exception.Message)" 2 }
    Write-Output "Installed the Lykta skill in $dir; lykta keeps it in step with the gateway."
}

function Invoke-Docs([string[]]$Names) {
    if ($Names.Count -eq 0) { Fail 'usage: lykta docs FILE..., such as lykta docs references/layout.md' 2 }
    foreach ($name in $Names) {
        if ($Names.Count -gt 1) { Write-Output "==> $name <==" }
        Write-Output (Invoke-Gateway 'GET' "/skill/$($name.TrimStart('/'))")
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
    Write-Output (Invoke-Gateway 'PUT' $path { [System.Net.Http.StringContent]::new($body, [Text.UTF8Encoding]::new($false), 'application/json') })
}

function Invoke-Media([string[]]$Arguments) {
    if ($Arguments.Count -ne 1) { Fail 'usage: lykta media FILE' 2 }
    try { $bytes = [IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $Arguments[0]).ProviderPath) }
    catch { Fail "could not read $($Arguments[0])" 2 }
    $answer = Invoke-Gateway 'POST' '/v1/media' { [System.Net.Http.ByteArrayContent]::new($bytes) }
    $id = ($answer | ConvertFrom-Json).id
    if (-not $id) { Fail "the gateway answered without a media id: $answer" 3 }
    Write-Output $id
}

$piped = @($input)
$verb = if ($args.Count -gt 0) { [string]$args[0] } else { '' }
$rest = [string[]]@($args | Select-Object -Skip 1)
switch ($verb) {
    'setup' { Invoke-Setup $rest }
    'install' { Import-Setup; Invoke-Install $rest }
    'docs' { Import-Setup; Invoke-Docs $rest }
    'put' { Import-Setup; Invoke-Put $rest $piped }
    'get' { if ($rest.Count -ne 1) { Fail 'usage: lykta get PATH' 2 }; Import-Setup; Write-Output (Invoke-Gateway 'GET' (Get-ApiPath $rest[0])) }
    'delete' { if ($rest.Count -ne 1) { Fail 'usage: lykta delete PATH' 2 }; Import-Setup; Write-Output (Invoke-Gateway 'DELETE' (Get-ApiPath $rest[0])) }
    'media' { Import-Setup; Invoke-Media $rest }
    { $_ -in 'help', '-h', '--help' } { Write-Output $usage }
    '' { [Console]::Error.WriteLine($usage); exit 2 }
    default { [Console]::Error.WriteLine($usage); Fail "unknown command $verb" 2 }
}
Update-Installs
