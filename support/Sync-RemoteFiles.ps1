#Requires -Version 5.1

<#
.SYNOPSIS
Downloads files that exist in a Linux folder but not in a local Windows folder.

.DESCRIPTION
Uses the Windows OpenSSH ssh.exe and scp.exe clients. Existing local files are
never overwritten. By default, only files directly inside RemoteFolder are
considered; use -Recurse to include files in subfolders and preserve their
relative paths locally.

The password is held as a SecureString. It is passed to OpenSSH through a
short-lived, randomly named local pipe, rather than a plaintext command-line
argument or password file.

The first connection automatically trusts a new host key and stores it in the
current user's known_hosts file. A changed host key is still rejected.

.PARAMETER RemoteHost
DNS name or IP address of the remote Linux system.

.PARAMETER Username
Login name on the remote Linux system.

.PARAMETER RemoteFolder
Absolute path of the folder on the remote Linux system.

.PARAMETER LocalFolder
Folder on the Windows system. It is created if it does not exist.

.PARAMETER Password
Password as a SecureString. If omitted, the script prompts for it.

.PARAMETER Port
SSH port. The default is 22.

.PARAMETER Recurse
Include files in remote subfolders and preserve their relative paths.

.EXAMPLE
.\Sync-RemoteFiles.ps1 -RemoteHost backup.example.com -Username backup `
    -RemoteFolder /var/backups -LocalFolder C:\Backups

Prompts for the password and downloads missing files from /var/backups.

.EXAMPLE
$password = Read-Host 'Remote password' -AsSecureString
.\Sync-RemoteFiles.ps1 -RemoteHost 192.0.2.10 -Username backup `
    -Password $password -RemoteFolder /var/backups `
    -LocalFolder C:\Backups -Recurse

.NOTES
If Windows prevents local scripts from running, review the execution policy
before changing it. For example, an administrator may choose:
    Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string] $RemoteHost,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string] $Username,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string] $RemoteFolder,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string] $LocalFolder,

    [Parameter()]
    [System.Security.SecureString] $Password,

    [Parameter()]
    [ValidateRange(1, 65535)]
    [int] $Port = 22,

    [Parameter()]
    [switch] $Recurse
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-OpenSshCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Name
    )

    $command = Get-Command "$Name.exe" -CommandType Application -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        return $command.Source
    }

    $installationHelp = @"
Windows OpenSSH Client is required, but $Name.exe was not found.

Install it on Windows 10/11 or Windows Server:
  1. Open PowerShell as Administrator.
  2. Run:
       Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0
  3. Open a new PowerShell window and verify:
       ssh -V
       scp

Alternatively, open Settings > Optional features > View features, search for
'OpenSSH Client', and install it.

Microsoft instructions:
https://learn.microsoft.com/windows-server/administration/openssh/openssh_install_firstuse
"@

    throw $installationHelp
}

function Get-OpenSshVersionText {
    param(
        [Parameter(Mandatory = $true)]
        [string] $FilePath
    )

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $FilePath
    $startInfo.Arguments = '-V'
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    $processStarted = $false

    try {
        if (-not $process.Start()) {
            throw "Could not start $FilePath to determine its version."
        }
        $processStarted = $true

        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()

        if ($process.ExitCode -ne 0) {
            throw "$FilePath -V failed with exit code $($process.ExitCode)."
        }

        $versionText = ($stderrTask.Result + [Environment]::NewLine + $stdoutTask.Result).Trim()
        if ([string]::IsNullOrWhiteSpace($versionText)) {
            throw "$FilePath -V returned no version text."
        }

        return $versionText
    }
    finally {
        if ($processStarted -and -not $process.HasExited) {
            $process.Kill()
            $process.WaitForExit()
        }
        $process.Dispose()
    }
}

function ConvertTo-NativeArgument {
    param(
        [AllowEmptyString()]
        [string] $Argument
    )

    if ($Argument.Length -eq 0) {
        return '""'
    }

    if ($Argument -notmatch '[\s"]') {
        return $Argument
    }

    # Apply the CommandLineToArgvW quoting rules used by Windows executables.
    $builder = New-Object System.Text.StringBuilder
    [void] $builder.Append('"')
    $backslashes = 0

    foreach ($character in $Argument.ToCharArray()) {
        if ($character -eq [char] 92) {
            $backslashes++
            continue
        }

        if ($character -eq [char] 34) {
            [void] $builder.Append(('\' * (($backslashes * 2) + 1)))
            [void] $builder.Append('"')
            $backslashes = 0
            continue
        }

        if ($backslashes -gt 0) {
            [void] $builder.Append(('\' * $backslashes))
            $backslashes = 0
        }
        [void] $builder.Append($character)
    }

    if ($backslashes -gt 0) {
        [void] $builder.Append(('\' * ($backslashes * 2)))
    }
    [void] $builder.Append('"')

    return $builder.ToString()
}

function ConvertTo-PosixShellLiteral {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Value
    )

    $singleQuoteReplacement = "'" + '"' + "'" + '"' + "'"
    return "'" + $Value.Replace("'", $singleQuoteReplacement) + "'"
}

function New-AskPassHelper {
    param(
        [Parameter(Mandatory = $true)]
        [string] $OutputPath,

        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[A-Za-z0-9._-]+$')]
        [string] $PipeName
    )

    $className = 'OpenSshAskPass' + [Guid]::NewGuid().ToString('N')
    $source = @'
using System;
using System.IO;
using System.IO.Pipes;
using System.Text;

public static class __CLASS_NAME__
{
    public static int Main()
    {
        const string pipeName = "__PIPE_NAME__";

        try
        {
            using (NamedPipeClientStream pipe = new NamedPipeClientStream(
                ".", pipeName, PipeDirection.In, PipeOptions.None))
            {
                pipe.Connect(30000);
                using (StreamReader reader = new StreamReader(pipe, Encoding.UTF8))
                {
                    string response = reader.ReadToEnd();
                    byte[] responseBytes = new UTF8Encoding(false).GetBytes(response);

                    try
                    {
                        using (Stream output = Console.OpenStandardOutput())
                        {
                            output.Write(responseBytes, 0, responseBytes.Length);
                            output.Flush();
                        }
                    }
                    finally
                    {
                        Array.Clear(responseBytes, 0, responseBytes.Length);
                    }
                }
            }
            return 0;
        }
        catch
        {
            return 1;
        }
    }
}
'@
    $source = $source.Replace('__CLASS_NAME__', $className)
    $source = $source.Replace('__PIPE_NAME__', $PipeName)

    Add-Type -TypeDefinition $source -Language CSharp -OutputAssembly $OutputPath `
        -OutputType ConsoleApplication -ErrorAction Stop
}

function Send-PasswordToPipe {
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.Pipes.NamedPipeServerStream] $Pipe,

        [Parameter(Mandatory = $true)]
        [System.Security.SecureString] $SecurePassword
    )

    $passwordPointer = [IntPtr]::Zero
    $plainPassword = $null
    $writer = $null

    try {
        $passwordPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePassword)
        $plainPassword = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($passwordPointer)
        $utf8WithoutBom = New-Object System.Text.UTF8Encoding($false)
        $writer = New-Object System.IO.StreamWriter($Pipe, $utf8WithoutBom, 1024, $true)
        $writer.Write($plainPassword)
        $writer.Flush()
    }
    finally {
        if ($null -ne $writer) {
            $writer.Dispose()
        }
        $plainPassword = $null
        if ($passwordPointer -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($passwordPointer)
        }
    }
}

function Invoke-OpenSshProcess {
    param(
        [Parameter(Mandatory = $true)]
        [string] $FilePath,

        [Parameter(Mandatory = $true)]
        [string[]] $Arguments,

        [Parameter(Mandatory = $true)]
        [System.Security.SecureString] $SecurePassword,

        [Parameter(Mandatory = $true)]
        [string] $AskPassPath,

        [Parameter(Mandatory = $true)]
        [string] $AskPassPipeName,

        [Parameter()]
        [switch] $CaptureOutput
    )

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $FilePath
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = [bool] $CaptureOutput
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = [bool] $CaptureOutput
    $startInfo.RedirectStandardError = [bool] $CaptureOutput
    $startInfo.Arguments = (($Arguments | ForEach-Object {
        ConvertTo-NativeArgument -Argument $_
    }) -join ' ')
    $startInfo.EnvironmentVariables['SSH_ASKPASS'] = $AskPassPath
    $startInfo.EnvironmentVariables['SSH_ASKPASS_REQUIRE'] = 'force'
    $startInfo.EnvironmentVariables['DISPLAY'] = 'db-backup-askpass:0'

    if ($CaptureOutput) {
        $startInfo.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false)
        $startInfo.StandardErrorEncoding = New-Object System.Text.UTF8Encoding($false)
    }

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    $processStarted = $false
    $stdoutTask = $null
    $stderrTask = $null
    $askPassInvocationCount = 0

    try {
        if (-not $process.Start()) {
            throw "Could not start $FilePath."
        }
        $processStarted = $true
        $process.StandardInput.Close()

        if ($CaptureOutput) {
            $stdoutTask = $process.StandardOutput.ReadToEndAsync()
            $stderrTask = $process.StandardError.ReadToEndAsync()
        }

        # OpenSSH can invoke askpass more than once when authentication fails.
        while (-not $process.HasExited) {
            $pipe = New-Object System.IO.Pipes.NamedPipeServerStream(
                $AskPassPipeName,
                [System.IO.Pipes.PipeDirection]::Out,
                1,
                [System.IO.Pipes.PipeTransmissionMode]::Byte,
                [System.IO.Pipes.PipeOptions]::Asynchronous
            )

            try {
                $connection = $pipe.BeginWaitForConnection($null, $null)
                while (-not $connection.AsyncWaitHandle.WaitOne(100)) {
                    if ($process.HasExited) {
                        break
                    }
                }

                if ($connection.IsCompleted) {
                    $pipe.EndWaitForConnection($connection)
                }

                if ($pipe.IsConnected) {
                    $askPassInvocationCount++
                    Send-PasswordToPipe -Pipe $pipe -SecurePassword $SecurePassword
                }
            }
            finally {
                $pipe.Dispose()
            }
        }

        $process.WaitForExit()

        $stdout = $null
        $stderr = $null
        if ($CaptureOutput) {
            $stdout = $stdoutTask.Result
            $stderr = $stderrTask.Result
        }

        return [PSCustomObject]@{
            ExitCode               = $process.ExitCode
            StdOut                 = $stdout
            StdErr                 = $stderr
            AskPassInvocationCount = $askPassInvocationCount
        }
    }
    finally {
        if ($processStarted -and -not $process.HasExited) {
            $process.Kill()
            $process.WaitForExit()
        }
        $process.Dispose()
    }
}

function ConvertTo-SafeLocalRelativePath {
    param(
        [Parameter(Mandatory = $true)]
        [string] $RemoteRelativePath
    )

    $parts = $RemoteRelativePath.Split([char] '/')
    $invalidCharacters = [System.IO.Path]::GetInvalidFileNameChars()

    foreach ($part in $parts) {
        if ([string]::IsNullOrEmpty($part) -or $part -eq '.' -or $part -eq '..') {
            throw "The remote path '$RemoteRelativePath' cannot be safely represented on Windows."
        }
        if ($part.IndexOfAny($invalidCharacters) -ge 0) {
            throw "The remote path '$RemoteRelativePath' contains a character that Windows filenames do not support."
        }
        if ($part.EndsWith(' ') -or $part.EndsWith('.')) {
            throw "The remote path '$RemoteRelativePath' ends a path component with a dot or space, which Windows does not support."
        }
        if ($part -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)') {
            throw "The remote path '$RemoteRelativePath' uses a reserved Windows filename."
        }
    }

    return [System.IO.Path]::Combine([string[]] $parts)
}

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw 'This script is intended for Windows PowerShell 5.1 or newer.'
}

if ($RemoteHost.StartsWith('-') -or $RemoteHost -match '[\s\r\n]') {
    throw 'RemoteHost must be a DNS name or IP address without whitespace.'
}
if ($Username.StartsWith('-') -or $Username -notmatch '^[A-Za-z0-9._-]+$') {
    throw 'Username may contain only letters, numbers, dots, underscores, and hyphens, and must not begin with a hyphen.'
}
if (-not $RemoteFolder.StartsWith('/')) {
    throw 'RemoteFolder must be an absolute Linux path beginning with /.'
}
if ($RemoteFolder -match '[\x00\r\n]') {
    throw 'RemoteFolder must not contain NUL or newline characters.'
}

$sshPath = Get-OpenSshCommand -Name 'ssh'
$scpPath = Get-OpenSshCommand -Name 'scp'

if ($null -eq $Password) {
    $Password = Read-Host "Password for $Username@$RemoteHost" -AsSecureString
}
if ($Password.Length -eq 0) {
    throw 'The password must not be empty.'
}

$localRoot = [System.IO.Path]::GetFullPath($LocalFolder)
if (Test-Path -LiteralPath $localRoot) {
    if (-not (Test-Path -LiteralPath $localRoot -PathType Container)) {
        throw "LocalFolder exists but is not a directory: $localRoot"
    }
}
else {
    [void] (New-Item -ItemType Directory -Path $localRoot -Force)
}

$temporaryDirectory = Join-Path ([System.IO.Path]::GetTempPath()) `
    ('db-backup-sync-' + [Guid]::NewGuid().ToString('N'))
[void] [System.IO.Directory]::CreateDirectory($temporaryDirectory)
$askPassPath = Join-Path $temporaryDirectory 'OpenSshAskPass.exe'
$askPassPipeName = 'db-backup-askpass-' + [Guid]::NewGuid().ToString('N')

try {
    Write-Host 'Preparing secure password handoff...'
    New-AskPassHelper -OutputPath $askPassPath -PipeName $askPassPipeName
    if (-not (Test-Path -LiteralPath $askPassPath -PathType Leaf)) {
        throw "The OpenSSH askpass helper was not created: $askPassPath"
    }
    Write-Verbose "Created OpenSSH askpass helper: $askPassPath"

    $destinationHost = $RemoteHost
    if ($destinationHost.Contains(':') -and -not $destinationHost.StartsWith('[')) {
        $destinationHost = "[$destinationHost]"
    }
    $destination = "$Username@$destinationHost"
    $commonSshOptions = @(
        '-o', 'BatchMode=no',
        '-o', 'NumberOfPasswordPrompts=1',
        '-o', 'PreferredAuthentications=password,keyboard-interactive',
        '-o', 'PubkeyAuthentication=no',
        '-o', 'StrictHostKeyChecking=accept-new',
        '-o', 'ConnectTimeout=20'
    )
    if ($VerbosePreference -ne 'SilentlyContinue') {
        $commonSshOptions = @('-vvv') + $commonSshOptions
    }

    $quotedRemoteFolder = ConvertTo-PosixShellLiteral -Value $RemoteFolder
    $findArguments = if ($Recurse) {
        '. -type f -print0'
    }
    else {
        '. -mindepth 1 -maxdepth 1 -type f -print0'
    }
    $remoteCommand = "if ! cd $quotedRemoteFolder; then echo 'Remote folder is unavailable.' >&2; exit 3; fi; printf '\0'; find $findArguments"

    Write-Host "Inspecting $RemoteFolder on $RemoteHost..."
    $listArguments = @('-p', $Port) + $commonSshOptions + @($destination, $remoteCommand)
    $listResult = Invoke-OpenSshProcess -FilePath $sshPath -Arguments $listArguments `
        -SecurePassword $Password -AskPassPath $askPassPath `
        -AskPassPipeName $askPassPipeName -CaptureOutput

    if ($listResult.ExitCode -ne 0) {
        $details = $listResult.StdErr.Trim()
        if ([string]::IsNullOrEmpty($details)) {
            $details = 'No diagnostic text was returned by ssh.exe.'
        }
        throw "Remote inspection failed (ssh exit code $($listResult.ExitCode)). Askpass helper invocations: $($listResult.AskPassInvocationCount).`n$details"
    }

    if (-not [string]::IsNullOrWhiteSpace($listResult.StdErr)) {
        Write-Verbose $listResult.StdErr.Trim()
    }

    $firstSeparator = $listResult.StdOut.IndexOf([char] 0)
    if ($firstSeparator -lt 0) {
        throw 'The remote listing did not have the expected format. Check whether shell startup output or server policy blocks remote commands.'
    }

    $listing = $listResult.StdOut.Substring($firstSeparator + 1)
    $remoteFiles = @($listing.Split(
        [char[]] @([char] 0),
        [System.StringSplitOptions]::RemoveEmptyEntries
    ) | ForEach-Object {
        if ($_.StartsWith('./')) { $_.Substring(2) } else { $_ }
    } | Sort-Object)

    $mappedFiles = New-Object System.Collections.Generic.List[object]
    $localPathOwners = @{}
    foreach ($remoteRelativePath in $remoteFiles) {
        $localRelativePath = ConvertTo-SafeLocalRelativePath -RemoteRelativePath $remoteRelativePath
        if ($localPathOwners.ContainsKey($localRelativePath)) {
            throw "Remote files '$($localPathOwners[$localRelativePath])' and '$remoteRelativePath' map to the same case-insensitive Windows path."
        }
        $localPathOwners[$localRelativePath] = $remoteRelativePath

        $localPath = Join-Path $localRoot $localRelativePath
        if (Test-Path -LiteralPath $localPath) {
            if (-not (Test-Path -LiteralPath $localPath -PathType Leaf)) {
                throw "A local directory conflicts with the remote file '$remoteRelativePath': $localPath"
            }
            continue
        }

        $mappedFiles.Add([PSCustomObject]@{
            RemoteRelativePath = $remoteRelativePath
            LocalPath          = $localPath
        })
    }

    $missingCount = $mappedFiles.Count
    $existingCount = $remoteFiles.Count - $missingCount
    Write-Host "Found $($remoteFiles.Count) remote file(s): $existingCount already local, $missingCount to download."

    if ($missingCount -eq 0) {
        Write-Host 'Local folder is already up to date.'
        return
    }

    $versionText = Get-OpenSshVersionText -FilePath $sshPath
    $useLegacyScpQuoting = $false
    if ($versionText -match 'OpenSSH_(?:for_Windows_)?(\d+)\.') {
        $useLegacyScpQuoting = [int] $Matches[1] -lt 9
    }
    else {
        Write-Warning 'Could not determine the OpenSSH version; assuming scp uses its modern SFTP transport.'
    }

    $downloadedCount = 0
    $processedCount = 0
    foreach ($file in $mappedFiles) {
        $processedCount++
        $position = $processedCount
        $percentComplete = [int] ((($position - 1) / $missingCount) * 100)
        Write-Progress -Activity 'Downloading missing remote files' `
            -Status "$position of $missingCount - $($file.RemoteRelativePath)" `
            -PercentComplete $percentComplete
        Write-Host "[$position/$missingCount] Downloading $($file.RemoteRelativePath)"

        $localParent = Split-Path -Parent $file.LocalPath
        if (-not (Test-Path -LiteralPath $localParent -PathType Container)) {
            [void] (New-Item -ItemType Directory -Path $localParent -Force)
        }

        $partialPath = Join-Path $localParent `
            ('.db-backup-download-' + [Guid]::NewGuid().ToString('N') + '.partial')
        $remoteFilePath = if ($RemoteFolder -eq '/') {
            '/' + $file.RemoteRelativePath
        }
        else {
            $RemoteFolder.TrimEnd('/') + '/' + $file.RemoteRelativePath
        }
        if ($useLegacyScpQuoting) {
            $remoteFilePath = ConvertTo-PosixShellLiteral -Value $remoteFilePath
        }
        $remoteSource = $destination + ':' + $remoteFilePath

        try {
            $copyArguments = @('-P', $Port, '-p') + $commonSshOptions + @($remoteSource, $partialPath)
            $copyResult = Invoke-OpenSshProcess -FilePath $scpPath -Arguments $copyArguments `
                -SecurePassword $Password -AskPassPath $askPassPath `
                -AskPassPipeName $askPassPipeName

            if ($copyResult.ExitCode -ne 0) {
                throw "scp.exe failed with exit code $($copyResult.ExitCode)."
            }
            if (-not (Test-Path -LiteralPath $partialPath -PathType Leaf)) {
                throw 'scp.exe reported success but did not create the expected local file.'
            }

            # Recheck after transfer so a concurrently created file is not overwritten.
            if (Test-Path -LiteralPath $file.LocalPath) {
                Write-Warning "The local file appeared during download and was not overwritten: $($file.LocalPath)"
                Remove-Item -LiteralPath $partialPath -Force
                continue
            }

            Move-Item -LiteralPath $partialPath -Destination $file.LocalPath
            $downloadedCount++
        }
        catch {
            if (Test-Path -LiteralPath $partialPath) {
                Remove-Item -LiteralPath $partialPath -Force
            }
            throw "Failed to download '$($file.RemoteRelativePath)': $($_.Exception.Message)"
        }
    }

    Write-Progress -Activity 'Downloading missing remote files' -Completed
    Write-Host "Completed. Downloaded $downloadedCount file(s) to $localRoot."
}
finally {
    Write-Progress -Activity 'Downloading missing remote files' -Completed
    if (Test-Path -LiteralPath $temporaryDirectory) {
        [System.IO.Directory]::Delete($temporaryDirectory, $true)
    }
}
