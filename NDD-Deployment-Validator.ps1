param(
    [string]$PrinterIP
)

$ErrorActionPreference = 'SilentlyContinue'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$configPath = Join-Path $scriptRoot 'config\ndd-global-endpoints.json'
$outputPath = Join-Path $scriptRoot 'output'

if (-not (Test-Path $outputPath)) {
    New-Item -ItemType Directory -Path $outputPath | Out-Null
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
    $release = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full').Release
    return $release
}

function Get-WinHttpProxy {
    try {
        $proxyText = (netsh winhttp show proxy | Out-String).Trim()
        return $proxyText
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

    $ping = Test-Connection -ComputerName $Address -Count 1 -Quiet
    $tcp80 = Test-TcpPort -HostName $Address -Port 80
    $tcp443 = Test-TcpPort -HostName $Address -Port 443
    $tcp9100 = Test-TcpPort -HostName $Address -Port 9100

    # UDP does not provide a reliable open/closed state through a generic socket test.
    # This result is therefore informational until a true SNMP query is implemented.
    $udp161Reachability = $ping

    return [pscustomobject]@{
        Address = $Address
        Ping = $ping
        Tcp80 = $tcp80
        Tcp443 = $tcp443
        Tcp9100 = $tcp9100
        SnmpUdp161Informational = $udp161Reachability
    }
}

Write-Host ''
Write-Host 'NDD Print Deployment Validator v0.1' -ForegroundColor Cyan
Write-Host '-----------------------------------' -ForegroundColor Cyan

if (-not (Test-Path $configPath)) {
    Write-Error "Configuration file not found: $configPath"
    exit 1
}

$config = Get-Content $configPath -Raw | ConvertFrom-Json

if ([string]::IsNullOrWhiteSpace($PrinterIP)) {
    $PrinterIP = Read-Host 'Printer IP for optional connectivity test (press Enter to skip)'
}

$computerSystem = Get-CimInstance Win32_ComputerSystem
$operatingSystem = Get-CimInstance Win32_OperatingSystem
$systemDrive = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$($env:SystemDrive)'"

$serverInfo = [pscustomobject]@{
    ComputerName = $env:COMPUTERNAME
    User = "$env:USERDOMAIN\$env:USERNAME"
    Domain = $computerSystem.Domain
    Manufacturer = $computerSystem.Manufacturer
    Model = $computerSystem.Model
    OperatingSystem = $operatingSystem.Caption
    OSVersion = $operatingSystem.Version
    TotalMemoryGB = [math]::Round($computerSystem.TotalPhysicalMemory / 1GB, 2)
    FreeDiskGB = if ($systemDrive) { [math]::Round($systemDrive.FreeSpace / 1GB, 2) } else { $null }
    DotNetRelease = Get-DotNetRelease
    WinHttpProxy = Get-WinHttpProxy
}

$endpointResults = @()

foreach ($endpoint in $config.endpoints) {
    Write-Host ("Testing {0} ({1})..." -f $endpoint.name, $endpoint.host)

    $dns = Test-DnsResolution -HostName $endpoint.host
    $ping = Test-Connection -ComputerName $endpoint.host -Count 1 -Quiet
    $tcp443 = Test-TcpPort -HostName $endpoint.host -Port $endpoint.port

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

    $overall = $dns.Success -and $tcp443 -and $https.Success

    $endpointResults += [pscustomobject]@{
        Name = $endpoint.name
        Host = $endpoint.host
        Purpose = $endpoint.purpose
        Required = [bool]$endpoint.required
        DNS = [pscustomobject]@{
            Status = Get-StatusLabel $dns.Success
            Addresses = $dns.Addresses
        }
        Ping = if ($ping) { 'PASS' } else { 'BLOCKED_OR_UNREACHABLE' }
        Tcp443 = Get-StatusLabel $tcp443
        HTTPS = if ($https.Success) { 'PASS' } else { 'FAIL' }
        HttpStatusCode = $https.StatusCode
        Message = $https.Message
        Overall = Get-StatusLabel $overall
    }
}

$printerResult = Test-PrinterTarget -Address $PrinterIP

$requiredFailures = @($endpointResults | Where-Object { $_.Required -and $_.Overall -eq 'FAIL' })
$overallStatus = if ($requiredFailures.Count -eq 0) { 'READY' } else { 'NOT_READY' }

$report = [pscustomobject]@{
    Tool = 'NDD Print Deployment Validator'
    Version = '0.1'
    Timestamp = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssK')
    Datacenter = $config.datacenter
    OverallStatus = $overallStatus
    RequiredEndpointFailures = $requiredFailures.Count
    Server = $serverInfo
    Printer = $printerResult
    NddEndpoints = $endpointResults
}

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$baseName = "NDD-Validation-$($env:COMPUTERNAME)-$timestamp"
$jsonFile = Join-Path $outputPath "$baseName.json"
$txtFile = Join-Path $outputPath "$baseName.txt"

$report | ConvertTo-Json -Depth 8 | Set-Content -Path $jsonFile -Encoding UTF8

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
$lines.Add($serverInfo.WinHttpProxy)
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
    $lines.Add('')
}

if ($printerResult) {
    $lines.Add('PRINTER CONNECTIVITY')
    $lines.Add('------------------------------------------------------------')
    $lines.Add("Target ............... $($printerResult.Address)")
    $lines.Add("Ping ................. $(Get-StatusLabel $printerResult.Ping)")
    $lines.Add("TCP 80 ............... $(Get-StatusLabel $printerResult.Tcp80)")
    $lines.Add("TCP 443 .............. $(Get-StatusLabel $printerResult.Tcp443)")
    $lines.Add("TCP 9100 ............. $(Get-StatusLabel $printerResult.Tcp9100)")
    $lines.Add("UDP 161 / SNMP ....... INFORMATIONAL")
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

$lines | Set-Content -Path $txtFile -Encoding UTF8

Write-Host ''
Write-Host "Overall status: $overallStatus" -ForegroundColor $(if ($overallStatus -eq 'READY') { 'Green' } else { 'Red' })
Write-Host "TXT report:  $txtFile"
Write-Host "JSON report: $jsonFile"
