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

$MinimumRamGB = 4
$MinimumFreeDiskGB = 10
$MinimumDotNet48Release = 528040

try {
    if (-not (Test-Path $outputPath)) {
        New-Item -ItemType Directory -Path $outputPath -Force -ErrorAction Stop | Out-Null
    }
    $writeTest = Join-Path $outputPath '.write-test.tmp'
    'write-test' | Set-Content -Path $writeTest -Encoding UTF8 -ErrorAction Stop
    Remove-Item $writeTest -Force -ErrorAction SilentlyContinue
}
catch {
    Write-Host "ERROR: Unable to write to $outputPath" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 2
}

function Get-StatusLabel {
    param([bool]$Value)
    if ($Value) { 'PASS' } else { 'FAIL' }
}

function Test-TcpPort {
    param([string]$HostName,[int]$Port,[int]$TimeoutMs = 4000)
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $async = $client.BeginConnect($HostName,$Port,$null,$null)
        $success = $async.AsyncWaitHandle.WaitOne($TimeoutMs,$false)
        if (-not $success) { $client.Close(); return $false }
        $client.EndConnect($async)
        $client.Close()
        return $true
    } catch { return $false }
}

function Test-DnsResolution {
    param([string]$HostName)
    try {
        $addresses = [System.Net.Dns]::GetHostAddresses($HostName)
        [pscustomobject]@{ Success = ($addresses.Count -gt 0); Addresses = @($addresses | ForEach-Object { $_.IPAddressToString }) }
    } catch {
        [pscustomobject]@{ Success = $false; Addresses = @() }
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
        [pscustomobject]@{ Success = $true; StatusCode = $statusCode; Message = 'HTTPS request completed' }
    }
    catch [System.Net.WebException] {
        $response = $_.Exception.Response
        if ($response) {
            $statusCode = [int]$response.StatusCode
            $response.Close()
            return [pscustomobject]@{ Success = $true; StatusCode = $statusCode; Message = 'Endpoint responded over HTTPS' }
        }
        [pscustomobject]@{ Success = $false; StatusCode = $null; Message = $_.Exception.Message }
    }
    catch {
        [pscustomobject]@{ Success = $false; StatusCode = $null; Message = $_.Exception.Message }
    }
}

function Get-DotNet48Info {
    try {
        $release = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -ErrorAction Stop).Release
        [pscustomobject]@{
            Release = [int]$release
            Installed = ([int]$release -ge $MinimumDotNet48Release)
            Required = '4.8 or later'
        }
    } catch {
        [pscustomobject]@{ Release = $null; Installed = $false; Required = '4.8 or later' }
    }
}

function Get-NetFx3Info {
    try {
        $feature = Get-WindowsOptionalFeature -Online -FeatureName NetFx3 -ErrorAction Stop
        $enabled = ($feature.State -eq 'Enabled')
        return [pscustomobject]@{ State = [string]$feature.State; Installed = $enabled; Required = '.NET Framework 3.5' }
    } catch {
        try {
            $raw = dism.exe /Online /Get-FeatureInfo /FeatureName:NetFx3 2>$null | Out-String
            $enabled = ($raw -match 'State\s*:\s*Enabled' -or $raw -match 'Estado\s*:\s*Habilitado')
            return [pscustomobject]@{ State = if ($enabled) { 'Enabled' } else { 'Unknown/Disabled' }; Installed = $enabled; Required = '.NET Framework 3.5' }
        } catch {
            return [pscustomobject]@{ State = 'Unable to detect'; Installed = $false; Required = '.NET Framework 3.5' }
        }
    }
}

function Get-WinHttpProxy {
    try { (netsh winhttp show proxy | Out-String).Trim() }
    catch { 'Unable to read WinHTTP proxy configuration' }
}

function Get-AdReadiness {
    param($ComputerSystem)

    $partOfDomain = [bool]$ComputerSystem.PartOfDomain
    if (-not $partOfDomain) {
        return [pscustomobject]@{
            PartOfDomain = $false
            Domain = $ComputerSystem.Domain
            DomainController = $null
            Dns = 'NOT_TESTED'
            Ldap389 = 'NOT_TESTED'
            Status = 'NOT_CONFIGURED'
        }
    }

    $domain = [string]$ComputerSystem.Domain
    $dcName = $null
    try {
        $nl = nltest.exe "/dsgetdc:$domain" 2>$null | Out-String
        $match = [regex]::Match($nl,'(?im)^\s*(DC|Controlador de Domínio)\s*:\s*\\\\([^\s]+)')
        if ($match.Success) { $dcName = $match.Groups[2].Value }
    } catch {}

    if (-not $dcName) {
        try {
            $dcName = ([System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().FindDomainController()).Name
        } catch {}
    }

    if ($dcName) {
        $dns = Test-DnsResolution -HostName $dcName
        $ldap = Test-TcpPort -HostName $dcName -Port 389
        $status = if ($dns.Success -and $ldap) { 'PASS' } else { 'FAIL' }
        return [pscustomobject]@{
            PartOfDomain = $true
            Domain = $domain
            DomainController = $dcName
            Dns = Get-StatusLabel ([bool]$dns.Success)
            Ldap389 = Get-StatusLabel ([bool]$ldap)
            Status = $status
        }
    }

    [pscustomobject]@{
        PartOfDomain = $true
        Domain = $domain
        DomainController = $null
        Dns = 'FAIL'
        Ldap389 = 'FAIL'
        Status = 'FAIL'
    }
}

function Test-PrinterTarget {
    param([string]$Address)
    if ([string]::IsNullOrWhiteSpace($Address)) { return $null }
    $ping = $false
    try { $ping = Test-Connection -ComputerName $Address -Count 1 -Quiet -ErrorAction SilentlyContinue } catch {}
    [pscustomobject]@{
        Address = $Address
        Ping = [bool]$ping
        Tcp80 = [bool](Test-TcpPort $Address 80)
        Tcp443 = [bool](Test-TcpPort $Address 443)
        Tcp9100 = [bool](Test-TcpPort $Address 9100)
        Snmp = 'NOT_VALIDATED'
    }
}

function Write-FatalReport {
    param([string]$Stage,[System.Management.Automation.ErrorRecord]$ErrorRecord)
    @(
        'NDD PRINT DEPLOYMENT VALIDATOR - EXECUTION ERROR'
        "Timestamp: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        "Computer: $computerName"
        "Stage: $Stage"
        "Error: $($ErrorRecord.Exception.Message)"
        ''
        ($ErrorRecord | Out-String).Trim()
    ) | Set-Content -Path $errorFile -Encoding UTF8 -ErrorAction SilentlyContinue
    Write-Host "Execution failed: $($ErrorRecord.Exception.Message)" -ForegroundColor Red
    Write-Host "Error report: $errorFile" -ForegroundColor Yellow
}

Write-Host ''
Write-Host 'NDD Print Deployment Validator v0.2' -ForegroundColor Cyan
Write-Host '-----------------------------------' -ForegroundColor Cyan
Write-Host "Output folder: $outputPath" -ForegroundColor DarkGray

try {
    if (-not (Test-Path $configPath)) { throw "Configuration file not found: $configPath" }
    $config = Get-Content $configPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop

    if ([string]::IsNullOrWhiteSpace($PrinterIP)) {
        $PrinterIP = Read-Host 'Printer IP for optional connectivity test (press Enter to skip)'
    }

    Write-Host 'Collecting server prerequisites...'
    $computerSystem = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
    $operatingSystem = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    $systemDrive = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$($env:SystemDrive)'" -ErrorAction SilentlyContinue

    $ramGB = [math]::Round([double]$computerSystem.TotalPhysicalMemory / 1GB,2)
    $diskGB = if ($systemDrive) { [math]::Round([double]$systemDrive.FreeSpace / 1GB,2) } else { $null }
    $net35 = Get-NetFx3Info
    $net48 = Get-DotNet48Info

    $serverInfo = [pscustomobject]@{
        ComputerName = $computerName
        User = "$env:USERDOMAIN\$env:USERNAME"
        Domain = $computerSystem.Domain
        OperatingSystem = $operatingSystem.Caption
        OSVersion = $operatingSystem.Version
        Memory = [pscustomobject]@{ ValueGB = $ramGB; MinimumGB = $MinimumRamGB; Status = Get-StatusLabel ($ramGB -ge $MinimumRamGB) }
        FreeDisk = [pscustomobject]@{ ValueGB = $diskGB; MinimumGB = $MinimumFreeDiskGB; Status = Get-StatusLabel ($null -ne $diskGB -and $diskGB -ge $MinimumFreeDiskGB) }
        DotNet35 = [pscustomobject]@{ State = $net35.State; Status = Get-StatusLabel ([bool]$net35.Installed) }
        DotNet48 = [pscustomobject]@{ Release = $net48.Release; Status = Get-StatusLabel ([bool]$net48.Installed) }
        WinHttpProxy = Get-WinHttpProxy
    }

    Write-Host 'Validating Active Directory / LDAP context...'
    $adResult = Get-AdReadiness -ComputerSystem $computerSystem

    Write-Host 'Testing NDD Global web services...'
    $endpointResults = @()
    foreach ($endpoint in $config.endpoints) {
        Write-Host ("  {0} ({1})" -f $endpoint.name,$endpoint.host)
        $dns = Test-DnsResolution $endpoint.host
        $ping = $false
        try { $ping = Test-Connection -ComputerName $endpoint.host -Count 1 -Quiet -ErrorAction SilentlyContinue } catch {}
        $tcp = Test-TcpPort $endpoint.host ([int]$endpoint.port)
        $https = if ($tcp) { Test-HttpsEndpoint $endpoint.host } else { [pscustomobject]@{ Success=$false; StatusCode=$null; Message='HTTPS skipped because TCP 443 failed' } }
        $overall = [bool]($dns.Success -and $tcp -and $https.Success)
        $endpointResults += [pscustomobject]@{
            Name=$endpoint.name; Host=$endpoint.host; Purpose=$endpoint.purpose; Required=[bool]$endpoint.required
            DNS=[pscustomobject]@{ Status=Get-StatusLabel ([bool]$dns.Success); Addresses=$dns.Addresses }
            Ping=if($ping){'PASS'}else{'BLOCKED_OR_UNREACHABLE'}
            Tcp443=Get-StatusLabel ([bool]$tcp)
            HTTPS=if($https.Success){'PASS'}else{'FAIL'}
            HttpStatusCode=$https.StatusCode
            Message=$https.Message
            Overall=Get-StatusLabel $overall
        }
    }

    Write-Host 'Testing optional printer connectivity...'
    $printerResult = Test-PrinterTarget $PrinterIP

    $requiredEndpointFailures = @($endpointResults | Where-Object { $_.Required -and $_.Overall -eq 'FAIL' })
    $serverFailures = @()
    if ($serverInfo.Memory.Status -eq 'FAIL') { $serverFailures += 'RAM' }
    if ($serverInfo.FreeDisk.Status -eq 'FAIL') { $serverFailures += 'Free disk' }
    if ($serverInfo.DotNet35.Status -eq 'FAIL') { $serverFailures += '.NET Framework 3.5' }
    if ($serverInfo.DotNet48.Status -eq 'FAIL') { $serverFailures += '.NET Framework 4.8' }

    $serverStatus = if ($serverFailures.Count -eq 0) { 'PASS' } else { 'FAIL' }
    $webStatus = if ($requiredEndpointFailures.Count -eq 0) { 'PASS' } else { 'FAIL' }
    $adStatus = $adResult.Status
    $printerStatus = if (-not $printerResult) { 'SKIPPED' } elseif ($printerResult.Ping -and ($printerResult.Tcp80 -or $printerResult.Tcp443)) { 'PASS' } else { 'WARN' }

    $overallStatus = if ($serverStatus -eq 'PASS' -and $webStatus -eq 'PASS') { 'READY' } else { 'NOT_READY' }
    $warnings = @()
    if ($adStatus -eq 'FAIL') { $warnings += 'Active Directory / LDAP validation failed' }
    if ($printerStatus -eq 'WARN') { $warnings += 'Printer connectivity is incomplete' }
    if ($printerResult -and $printerResult.Snmp -eq 'NOT_VALIDATED') { $warnings += 'SNMP has not yet been validated with a real SNMP query' }

    $report = [pscustomobject]@{
        Tool='NDD Print Deployment Validator'; Version='0.2'; Timestamp=(Get-Date).ToString('yyyy-MM-ddTHH:mm:ssK'); Datacenter=$config.datacenter
        OverallStatus=$overallStatus
        Summary=[pscustomobject]@{ ServerReadiness=$serverStatus; NddWebServices=$webStatus; ActiveDirectory=$adStatus; PrinterConnectivity=$printerStatus; Warnings=$warnings }
        Server=$serverInfo; ActiveDirectory=$adResult; Printer=$printerResult; NddEndpoints=$endpointResults
    }

    Write-Host 'Writing reports...'
    $report | ConvertTo-Json -Depth 10 | Set-Content -Path $jsonFile -Encoding UTF8 -ErrorAction Stop

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('============================================================')
    $lines.Add('             NDD PRINT DEPLOYMENT VALIDATOR v0.2')
    $lines.Add('============================================================')
    $lines.Add("Computer ............. $($serverInfo.ComputerName)")
    $lines.Add("Domain ............... $($serverInfo.Domain)")
    $lines.Add("Operating System ..... $($serverInfo.OperatingSystem)")
    $lines.Add("Datacenter ........... $($config.datacenter)")
    $lines.Add('')
    $lines.Add('SERVER READINESS')
    $lines.Add('------------------------------------------------------------')
    $lines.Add("[$($serverInfo.Memory.Status)] RAM .............. $($serverInfo.Memory.ValueGB) GB (minimum $MinimumRamGB GB)")
    $lines.Add("[$($serverInfo.FreeDisk.Status)] Free disk ........ $($serverInfo.FreeDisk.ValueGB) GB (minimum $MinimumFreeDiskGB GB)")
    $lines.Add("[$($serverInfo.DotNet35.Status)] .NET 3.5 ......... $($serverInfo.DotNet35.State)")
    $lines.Add("[$($serverInfo.DotNet48.Status)] .NET 4.8 ......... Release $($serverInfo.DotNet48.Release)")
    $lines.Add('')
    $lines.Add('WINHTTP PROXY')
    $lines.Add('------------------------------------------------------------')
    $lines.Add([string]$serverInfo.WinHttpProxy)
    $lines.Add('')
    $lines.Add('ACTIVE DIRECTORY / LDAP')
    $lines.Add('------------------------------------------------------------')
    $lines.Add("Status ............... $($adResult.Status)")
    $lines.Add("Domain joined ........ $($adResult.PartOfDomain)")
    $lines.Add("Domain ............... $($adResult.Domain)")
    $lines.Add("Domain Controller .... $($adResult.DomainController)")
    $lines.Add("DC DNS ............... $($adResult.Dns)")
    $lines.Add("LDAP TCP 389 ......... $($adResult.Ldap389)")
    $lines.Add('')
    $lines.Add('NDD GLOBAL WEB SERVICES')
    $lines.Add('------------------------------------------------------------')
    foreach ($result in $endpointResults) {
        $requiredText = if ($result.Required) { 'REQUIRED' } else { 'OPTIONAL' }
        $lines.Add("[$($result.Overall)] $($result.Name) [$requiredText]")
        $lines.Add("       Host: $($result.Host)")
        $lines.Add("       DNS: $($result.DNS.Status) | Ping: $($result.Ping) | TCP443: $($result.Tcp443) | HTTPS: $($result.HTTPS)")
        if ($null -ne $result.HttpStatusCode) { $lines.Add("       HTTP Status: $($result.HttpStatusCode)") }
        $lines.Add('')
    }
    if ($printerResult) {
        $lines.Add('PRINTER CONNECTIVITY')
        $lines.Add('------------------------------------------------------------')
        $lines.Add("Target ............... $($printerResult.Address)")
        $lines.Add("Ping ................. $(Get-StatusLabel ([bool]$printerResult.Ping))")
        $lines.Add("TCP 80 ............... $(Get-StatusLabel ([bool]$printerResult.Tcp80))")
        $lines.Add("TCP 443 .............. $(Get-StatusLabel ([bool]$printerResult.Tcp443))")
        $lines.Add("TCP 9100 ............. $(Get-StatusLabel ([bool]$printerResult.Tcp9100))")
        $lines.Add("SNMP UDP 161 ......... $($printerResult.Snmp)")
        $lines.Add('')
    }
    $lines.Add('============================================================')
    $lines.Add('SUMMARY')
    $lines.Add('============================================================')
    $lines.Add("Server readiness ...... $serverStatus")
    $lines.Add("NDD web services ...... $webStatus")
    $lines.Add("Active Directory ...... $adStatus")
    $lines.Add("Printer connectivity .. $printerStatus")
    $lines.Add("Overall ............... $overallStatus")
    if ($warnings.Count -gt 0) {
        $lines.Add('')
        $lines.Add('WARNINGS')
        foreach ($warning in $warnings) { $lines.Add("- $warning") }
    }
    if ($serverFailures.Count -gt 0) {
        $lines.Add('')
        $lines.Add('FAILED SERVER REQUIREMENTS')
        foreach ($item in $serverFailures) { $lines.Add("- $item") }
    }
    if ($requiredEndpointFailures.Count -gt 0) {
        $lines.Add('')
        $lines.Add('FAILED REQUIRED NDD ENDPOINTS')
        foreach ($failure in $requiredEndpointFailures) { $lines.Add("- $($failure.Name): $($failure.Host):443") }
    }
    $lines.Add('')
    $lines.Add('Note: ICMP/ping is informational for NDD web services.')
    $lines.Add('DNS, TCP 443 and HTTPS are used for web-service readiness.')
    $lines | Set-Content -Path $txtFile -Encoding UTF8 -ErrorAction Stop

    Write-Host ''
    Write-Host "Overall status: $overallStatus" -ForegroundColor $(if ($overallStatus -eq 'READY') {'Green'} else {'Red'})
    Write-Host "TXT report:  $txtFile" -ForegroundColor Green
    Write-Host "JSON report: $jsonFile" -ForegroundColor Green
    exit 0
}
catch {
    Write-FatalReport -Stage 'validator execution' -ErrorRecord $_
    exit 1
}
