param(
    [string]$PrinterIP
)

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$configPath = Join-Path $scriptRoot 'config\ndd-global-endpoints.json'
$outputPath = Join-Path $scriptRoot 'output'
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$computerName = if ($env:COMPUTERNAME) { $env:COMPUTERNAME } else { 'UNKNOWN' }
$baseName = "NDD-Validation-$computerName-$timestamp"
$jsonFile = Join-Path $outputPath "$baseName.json"
$txtFile = Join-Path $outputPath "$baseName.txt"
$errorFile = Join-Path $outputPath "$baseName-error.txt"

try {
    if (-not (Test-Path $outputPath)) {
        New-Item -ItemType Directory -Path $outputPath -Force -ErrorAction Stop | Out-Null
    }

    # Confirm write access before doing any tests.
    $writeTest = Join-Path $outputPath '.write-test.tmp'
    'write-test' | Set-Content -Path $writeTest -Encoding UTF8 -ErrorAction Stop
    Remove-Item $writeTest -Force -ErrorAction SilentlyContinue
}
catch {
    Write-Host ''
    Write-Host 'ERROR: Unable to create or write to the output folder.' -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host "Expected output folder: $outputPath"
    exit 2
}

function Get-StatusLabel {
    param([bool]$Value)
    if ($Value) { return 'PASS' }
    return 'FAIL'
}

function Test-TcpPort {
    param(
        [string]$HostName,
        [int]$Port,
        [int]$TimeoutMs = 4000
    )

    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $async = $client.BeginConnect($HostName, $Port, $null, $null)
        $success = $async.AsyncWaitHandle.WaitOne($TimeoutMs, $false)
        if (-not $success) {
            $client.Close()
            return $false
        }
        $client.EndConnect($async)
        $client.Close()
        return $true
    }
    catch {
        return $false
    }
}

function Test-HttpsEndpoint {
    param([string]$HostName)

    try {
        $request = [System.Net.HttpWebRequest]::Create("https://$HostName/")
        $request.Method = 'HEAD'
        $request.Timeout = 7000
        $request.AllowAutoRedirect = $true
        $response = $request.GetResponse()
        $statusCode = [int]$response.StatusCode
        $response.Close()
        return [pscustomobject]@{
            Success = $true
            StatusCode = $statusCode
            Message = 'HTTPS request completed'
        }
    }
    catch [System.Net.WebException] {
        $response = $_.Exception.Response
        if ($response) {
            $statusCode = [int]$response.StatusCode
            $response.Close()
            return [pscustomobject]@{
                Success = $true
                StatusCode = $statusCode
                Message = 'Endpoint responded over HTTPS'
            }
        }

        return [pscustomobject]@{
            Success = $false
            StatusCode = $null
            Message = $_.Exception.Message
        }
    }
    catch {
        return [pscustomobject]@{
            Success = $false
            StatusCode = $null
            Message = $_.Exception.Message
        }
    }
}

function Test-DnsResolution {
    param([string]$HostName)

    try {
        $addresses = [System.Net.Dns]::GetHostAddresses($HostName)
        return [pscustomobject]@{
            Success = ($addresses.Count -gt 0)
            Addresses = @($addresses | ForEach-Object { $_.IPAddressToString })
        }
    }
    catch {
        return [pscustomobject]@{
            Success = $false
            Addresses = @()
        }
    }
}

function Get-DotNetRelease {
    try {
        $release = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -ErrorAction Stop).Release
        return $release
    }
    catch {
        return $null
    }
}

function Get-WinHttpProxy {
    try {
        return (netsh winhttp show proxy | Out-String).Trim()
    }
    catch {
        return 'Unable to read WinHTTP proxy configuration'
    }
}

function Test-PrinterTarget {
    param([string]$Address)

    if ([string]::IsNullOrWhiteSpace($Address)) {
        return $null
    }

    $ping = $false
    try { $ping = Test-Connection -ComputerName $Address -Count 1 -Quiet -ErrorAction SilentlyContinue } catch {}

    $tcp80 = Test-TcpPort -HostName $Address -Port 80
    $tcp443 = Test-TcpPort -HostName $Address -Port 443
    $tcp9100 = Test-TcpPort -HostName $Address -Port 9100

    return [pscustomobject]@{
        Address = $Address
        Ping = [bool]$ping
        Tcp80 = [bool]$tcp80
        Tcp443 = [bool]$tcp443
        Tcp9100 = [bool]$tcp9100
        SnmpUdp161Informational = [bool]$ping
    }
}

function Write-FatalReport {
    param(
        [string]$Stage,
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    $message = @(
        '============================================================'
        ' NDD PRINT DEPLOYMENT VALIDATOR - EXECUTION ERROR'
        '============================================================'
        "Timestamp: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        "Computer: $computerName"
        "Stage: $Stage"
        ''
        'ERROR'
        '------------------------------------------------------------'
        $ErrorRecord.Exception.Message
        ''
        'DETAIL'
        '------------------------------------------------------------'
        ($ErrorRecord | Out-String).Trim()
        ''
        "Script path: $scriptRoot"
        "Output path: $outputPath"
    )

    try {
        $message | Set-Content -Path $errorFile -Encoding UTF8 -ErrorAction Stop
    }
    catch {}

    Write-Host ''
    Write-Host "Execution failed during: $Stage" -ForegroundColor Red
    Write-Host $ErrorRecord.Exception.Message -ForegroundColor Red
    Write-Host "Error report: $errorFile" -ForegroundColor Yellow
}

Write-Host ''
Write-Host 'NDD Print Deployment Validator v0.1.1' -ForegroundColor Cyan
Write-Host '-------------------------------------' -ForegroundColor Cyan
Write-Host "Output folder: $outputPath" -ForegroundColor DarkGray

try {
    if (-not (Test-Path $configPath)) {
        throw "Configuration file not found: $configPath"
    }

    $config = Get-Content $configPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop

    if ([string]::IsNullOrWhiteSpace($PrinterIP)) {
        $PrinterIP = Read-Host 'Printer IP for optional connectivity test (press Enter to skip)'
    }

    Write-Host 'Collecting server information...'

    $computerSystem = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
    $operatingSystem = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    $systemDrive = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$($env:SystemDrive)'" -ErrorAction SilentlyContinue

    $serverInfo = [pscustomobject]@{
        ComputerName = $computerName
        User = "$env:USERDOMAIN\$env:USERNAME"
        Domain = $computerSystem.Domain
        Manufacturer = $computerSystem.Manufacturer
        Model = $computerSystem.Model
        OperatingSystem = $operatingSystem.Caption
        OSVersion = $operatingSystem.Version
        TotalMemoryGB = [math]::Round([double]$computerSystem.TotalPhysicalMemory / 1GB, 2)
        FreeDiskGB = if ($systemDrive) { [math]::Round([double]$systemDrive.FreeSpace / 1GB, 2) } else { $null }
        DotNetRelease = Get-DotNetRelease
        WinHttpProxy = Get-WinHttpProxy
    }

    $endpointResults = @()

    foreach ($endpoint in $config.endpoints) {
        Write-Host ("Testing {0} ({1})..." -f $endpoint.name, $endpoint.host)

        $dns = Test-DnsResolution -HostName $endpoint.host
        $ping = $false
        try { $ping = Test-Connection -ComputerName $endpoint.host -Count 1 -Quiet -ErrorAction SilentlyContinue } catch {}
        $tcp443 = Test-TcpPort -HostName $endpoint.host -Port ([int]$endpoint.port)

        if ($tcp443) {
            $https = Test-HttpsEndpoint -HostName $endpoint.host
        }
        else {
            $https = [pscustomobject]@{
                Success = $false
                StatusCode = $null
                Message = 'HTTPS test skipped because TCP connection failed'
            }
        }

        $overall = [bool]($dns.Success -and $tcp443 -and $https.Success)

        $endpointResults += [pscustomobject]@{
            Name = $endpoint.name
            Host = $endpoint.host
            Purpose = $endpoint.purpose
            Required = [bool]$endpoint.required
            DNS = [pscustomobject]@{
                Status = Get-StatusLabel -Value ([bool]$dns.Success)
                Addresses = $dns.Addresses
            }
            Ping = if ($ping) { 'PASS' } else { 'BLOCKED_OR_UNREACHABLE' }
            Tcp443 = Get-StatusLabel -Value ([bool]$tcp443)
            HTTPS = if ($https.Success) { 'PASS' } else { 'FAIL' }
            HttpStatusCode = $https.StatusCode
            Message = $https.Message
            Overall = Get-StatusLabel -Value $overall
        }
    }

    $printerResult = Test-PrinterTarget -Address $PrinterIP

    $requiredFailures = @($endpointResults | Where-Object { $_.Required -and $_.Overall -eq 'FAIL' })
    $overallStatus = if ($requiredFailures.Count -eq 0) { 'READY' } else { 'NOT_READY' }

    $report = [pscustomobject]@{
        Tool = 'NDD Print Deployment Validator'
        Version = '0.1.1'
        Timestamp = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssK')
        Datacenter = $config.datacenter
        OverallStatus = $overallStatus
        RequiredEndpointFailures = $requiredFailures.Count
        Server = $serverInfo
        Printer = $printerResult
        NddEndpoints = $endpointResults
    }

    Write-Host 'Writing JSON report...'
    $report | ConvertTo-Json -Depth 8 | Set-Content -Path $jsonFile -Encoding UTF8 -ErrorAction Stop

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('============================================================')
    $lines.Add('             NDD PRINT DEPLOYMENT VALIDATOR')
    $lines.Add('============================================================')
    $lines.Add("Computer ............. $($serverInfo.ComputerName)")
    $lines.Add("Domain ............... $($serverInfo.Domain)")
    $lines.Add("Operating System ..... $($serverInfo.OperatingSystem)")
    $lines.Add("Memory ............... $($serverInfo.TotalMemoryGB) GB")
    $lines.Add("Free Disk ............ $($serverInfo.FreeDiskGB) GB")
    $lines.Add(".NET Release ......... $($serverInfo.DotNetRelease)")
    $lines.Add("Datacenter ........... $($config.datacenter)")
    $lines.Add('')
    $lines.Add('WINHTTP PROXY')
    $lines.Add('------------------------------------------------------------')
    $lines.Add([string]$serverInfo.WinHttpProxy)
    $lines.Add('')
    $lines.Add('NDD GLOBAL WEB SERVICES')
    $lines.Add('------------------------------------------------------------')

    foreach ($result in $endpointResults) {
        $requiredText = if ($result.Required) { 'REQUIRED' } else { 'OPTIONAL' }
        $lines.Add("[$($result.Overall)] $($result.Name) [$requiredText]")
        $lines.Add("       Host: $($result.Host)")
        $lines.Add("       DNS: $($result.DNS.Status)")
        $lines.Add("       Ping: $($result.Ping)")
        $lines.Add("       TCP 443: $($result.Tcp443)")
        $lines.Add("       HTTPS: $($result.HTTPS)")
        if ($null -ne $result.HttpStatusCode) {
            $lines.Add("       HTTP Status: $($result.HttpStatusCode)")
        }
        if ($result.Message) {
            $lines.Add("       Detail: $($result.Message)")
        }
        $lines.Add('')
    }

    if ($printerResult) {
        $lines.Add('PRINTER CONNECTIVITY')
        $lines.Add('------------------------------------------------------------')
        $lines.Add("Target ............... $($printerResult.Address)")
        $lines.Add("Ping ................. $(Get-StatusLabel -Value ([bool]$printerResult.Ping))")
        $lines.Add("TCP 80 ............... $(Get-StatusLabel -Value ([bool]$printerResult.Tcp80))")
        $lines.Add("TCP 443 .............. $(Get-StatusLabel -Value ([bool]$printerResult.Tcp443))")
        $lines.Add("TCP 9100 ............. $(Get-StatusLabel -Value ([bool]$printerResult.Tcp9100))")
        $lines.Add('UDP 161 / SNMP ....... INFORMATIONAL')
        $lines.Add('')
    }

    $lines.Add('============================================================')
    $lines.Add('RESULT')
    $lines.Add('============================================================')
    $lines.Add("Overall status ........ $overallStatus")
    $lines.Add("Required failures ..... $($requiredFailures.Count)")

    if ($requiredFailures.Count -gt 0) {
        $lines.Add('')
        $lines.Add('FAILED REQUIRED ENDPOINTS')
        foreach ($failure in $requiredFailures) {
            $lines.Add("- $($failure.Name): $($failure.Host):443")
        }
    }

    $lines.Add('')
    $lines.Add('Note: Ping/ICMP is informational. DNS, TCP 443 and HTTPS results')
    $lines.Add('are the primary indicators for NDD web service connectivity.')

    Write-Host 'Writing TXT report...'
    $lines | Set-Content -Path $txtFile -Encoding UTF8 -ErrorAction Stop

    Write-Host ''
    Write-Host "Overall status: $overallStatus" -ForegroundColor $(if ($overallStatus -eq 'READY') { 'Green' } else { 'Red' })
    Write-Host "TXT report:  $txtFile" -ForegroundColor Green
    Write-Host "JSON report: $jsonFile" -ForegroundColor Green
    exit 0
}
catch {
    Write-FatalReport -Stage 'validator execution' -ErrorRecord $_
    exit 1
}
