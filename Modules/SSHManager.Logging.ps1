$script:SSHManagerLogFile = $null
$script:SSHManagerLogMaxBytes = 5MB

function Initialize-SSHManagerLog {
    param([Parameter(Mandatory = $true)]$Paths)
    if (-not (Test-Path -LiteralPath $Paths.LogsRoot -PathType Container)) {
        New-Item -ItemType Directory -Path $Paths.LogsRoot -Force | Out-Null
    }
    $script:SSHManagerLogFile = Join-Path $Paths.LogsRoot 'ProperSSHManager.log'
    return $script:SSHManagerLogFile
}

function Get-SSHManagerLogFile { return $script:SSHManagerLogFile }

function Write-SSHManagerLog {
    param(
        [ValidateSet('DEBUG', 'INFO', 'WARN', 'ERROR')][string]$Level = 'INFO',
        [string]$Component = 'App',
        [string]$Action = '',
        [string]$HostName = '',
        [string]$Message = '',
        $ErrorRecord = $null
    )

    # Logging must never break the caller; secrets are never passed to this function.
    if ([string]::IsNullOrWhiteSpace($script:SSHManagerLogFile)) { return }
    try {
        $exceptionText = ''
        if ($null -ne $ErrorRecord) {
            $exception = if ($ErrorRecord -is [Management.Automation.ErrorRecord]) { $ErrorRecord.Exception } else { $ErrorRecord }
            if ($exception -is [Exception]) {
                $exceptionText = '{0}: {1}' -f $exception.GetType().FullName, $exception.Message
                $inner = $exception.InnerException
                while ($null -ne $inner) { $exceptionText += (' | {0}: {1}' -f $inner.GetType().FullName, $inner.Message); $inner = $inner.InnerException }
                if ($ErrorRecord -is [Management.Automation.ErrorRecord] -and $ErrorRecord.InvocationInfo) {
                    $exceptionText += (' @ {0}' -f ($ErrorRecord.InvocationInfo.PositionMessage -replace '\s+', ' '))
                }
            }
            else { $exceptionText = [string]$ErrorRecord }
        }
        $line = '{0} | {1,-5} | {2} | {3} | host={4} | {5} | exception={6}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff'), $Level, $Component, $Action, $HostName, ($Message -replace '\r?\n', ' '), ($exceptionText -replace '\r?\n', ' ')
        if ((Test-Path -LiteralPath $script:SSHManagerLogFile -PathType Leaf) -and (Get-Item -LiteralPath $script:SSHManagerLogFile).Length -gt $script:SSHManagerLogMaxBytes) {
            Move-Item -LiteralPath $script:SSHManagerLogFile -Destination ($script:SSHManagerLogFile + '.1') -Force
        }
        [IO.File]::AppendAllText($script:SSHManagerLogFile, $line + [Environment]::NewLine, [Text.Encoding]::UTF8)
    }
    catch { }
}
