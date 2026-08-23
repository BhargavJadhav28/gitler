[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$Version,
    [string]$InstallDir,
    [switch]$Force,
    [switch]$AllowDowngrade,
    [switch]$AddToPath,
    [switch]$RemovePath,
    [switch]$Uninstall
)

# Check the host before doing any path, network, or filesystem work.
if ($null -eq $PSVersionTable -or $null -eq $PSVersionTable.PSVersion) {
    throw 'PowerShell version information is unavailable.'
}

$powerShellMajor = $PSVersionTable.PSVersion.Major
$powerShellMinor = $PSVersionTable.PSVersion.Minor
if (($powerShellMajor -eq 5 -and $powerShellMinor -lt 1) -or ($powerShellMajor -ge 6 -and $powerShellMajor -lt 7) -or $powerShellMajor -lt 5) {
    throw 'install.ps1 requires Windows PowerShell 5.1 or PowerShell 7+.'
}

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw 'install.ps1 supports Windows only.'
}

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Set-StrictMode -Version 2.0

$RepositoryOwner = 'BhargavJadhav28'
$RepositoryName = 'gitler'
$StateFileName = '.gitler-install-state.json'
$ExecutableFileName = 'gitler.exe'
$StateFormatVersion = 1

function Test-StableVersion {
    param(
        [AllowNull()]
        [string]$Value
    )

    if ($null -eq $Value) {
        return $false
    }

    return [regex]::IsMatch(
        $Value,
        '\Av(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\z',
        [Text.RegularExpressions.RegexOptions]::CultureInvariant
    )
}

function Test-StableVersionWithoutTag {
    param(
        [AllowNull()]
        [string]$Value
    )

    if ($null -eq $Value) {
        return $false
    }

    return [regex]::IsMatch(
        $Value,
        '\A(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\z',
        [Text.RegularExpressions.RegexOptions]::CultureInvariant
    )
}

function Compare-StableVersion {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Left,
        [Parameter(Mandatory = $true)]
        [string]$Right
    )

    if (-not (Test-StableVersionWithoutTag $Left) -or -not (Test-StableVersionWithoutTag $Right)) {
        throw 'Internal version comparison received an invalid stable version.'
    }

    $leftParts = $Left.Split('.')
    $rightParts = $Right.Split('.')

    for ($index = 0; $index -lt 3; $index++) {
        if ($leftParts[$index].Length -lt $rightParts[$index].Length) {
            return -1
        }

        if ($leftParts[$index].Length -gt $rightParts[$index].Length) {
            return 1
        }

        $comparison = [string]::CompareOrdinal($leftParts[$index], $rightParts[$index])
        if ($comparison -lt 0) {
            return -1
        }

        if ($comparison -gt 0) {
            return 1
        }
    }

    return 0
}

function Get-PropertyValue {
    param(
        [AllowNull()]
        [object]$Object,
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if ($null -eq $Object) {
        return $null
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }

    return $property.Value
}

function Get-NormalizedDirectoryPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw 'InstallDir must be a non-empty directory path.'
    }

    try {
        $fullPath = [IO.Path]::GetFullPath($Path)
    }
    catch {
        throw "InstallDir '$Path' is not a valid Windows path. Details: $($_.Exception.Message)"
    }

    $root = [IO.Path]::GetPathRoot($fullPath)
    if ([string]::IsNullOrEmpty($root)) {
        throw "InstallDir '$Path' has no filesystem root."
    }

    if ($fullPath.Length -gt $root.Length) {
        $fullPath = $fullPath.TrimEnd([char[]]@('\', '/'))
    }

    if ([string]::Equals($fullPath, $root, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'InstallDir must be a dedicated directory, not a filesystem root.'
    }

    return $fullPath
}

function Assert-NoReparsePointsInPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FullPath
    )

    $probe = $FullPath
    while ($null -ne $probe -and $probe.Length -gt 0) {
        if ([IO.Directory]::Exists($probe) -or [IO.File]::Exists($probe)) {
            try {
                $attributes = [IO.File]::GetAttributes($probe)
            }
            catch {
                throw "Cannot inspect path component '$probe'. Details: $($_.Exception.Message)"
            }

            if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Refusing path '$FullPath' because component '$probe' is a symlink or reparse point."
            }
        }

        $parent = [IO.Directory]::GetParent($probe)
        if ($null -eq $parent -or [string]::Equals($parent.FullName, $probe, [StringComparison]::OrdinalIgnoreCase)) {
            break
        }

        $probe = $parent.FullName
    }
}

function Assert-SafeInstallDirectory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    Assert-NoReparsePointsInPath -FullPath $Path

    if ([IO.Directory]::Exists($Path)) {
        $attributes = [IO.File]::GetAttributes($Path)
        if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Refusing install directory '$Path' because it is a symlink or reparse point."
        }

        if (($attributes -band [IO.FileAttributes]::Directory) -eq 0) {
            throw "InstallDir '$Path' is not a directory."
        }
    }
    elseif ([IO.File]::Exists($Path)) {
        throw "InstallDir '$Path' is an existing file, not a directory."
    }
}

function Assert-RegularFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$Description
    )

    if (-not [IO.File]::Exists($Path)) {
        if ([IO.Directory]::Exists($Path)) {
            throw "$Description '$Path' is a directory, not a regular file."
        }

        throw "$Description '$Path' does not exist as a regular file."
    }

    try {
        $attributes = [IO.File]::GetAttributes($Path)
    }
    catch {
        throw "Cannot inspect $Description '$Path'. Details: $($_.Exception.Message)"
    }

    if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Refusing $Description '$Path' because it is a symlink or reparse point."
    }

    if (($attributes -band [IO.FileAttributes]::Directory) -ne 0) {
        throw "$Description '$Path' is a directory, not a regular file."
    }
}

function New-UniqueFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Directory,
        [Parameter(Mandatory = $true)]
        [string]$Prefix,
        [Parameter(Mandatory = $true)]
        [string]$Extension
    )

    if (-not [IO.Directory]::Exists($Directory)) {
        throw "Temporary or staging directory '$Directory' does not exist."
    }

    for ($attempt = 0; $attempt -lt 100; $attempt++) {
        $candidate = [IO.Path]::Combine(
            $Directory,
            ('{0}{1}{2}' -f $Prefix, [IO.Path]::GetRandomFileName(), $Extension)
        )

        try {
            $stream = [IO.File]::Open(
                $candidate,
                [IO.FileMode]::CreateNew,
                [IO.FileAccess]::Write,
                [IO.FileShare]::None
            )
            $stream.Dispose()
            return $candidate
        }
        catch [IO.IOException] {
            continue
        }
        catch {
            throw "Could not create unique file '$candidate'. Details: $($_.Exception.Message)"
        }
    }

    throw "Could not allocate a unique file in '$Directory'."
}

function New-UniqueUnusedPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Directory,
        [Parameter(Mandatory = $true)]
        [string]$Prefix,
        [Parameter(Mandatory = $true)]
        [string]$Extension
    )

    if (-not [IO.Directory]::Exists($Directory)) {
        throw "Directory '$Directory' does not exist."
    }

    for ($attempt = 0; $attempt -lt 100; $attempt++) {
        $candidate = [IO.Path]::Combine(
            $Directory,
            ('{0}{1}{2}' -f $Prefix, [IO.Path]::GetRandomFileName(), $Extension)
        )

        if (-not [IO.File]::Exists($candidate) -and -not [IO.Directory]::Exists($candidate)) {
            return $candidate
        }
    }

    throw "Could not allocate a unique path in '$Directory'."
}

function Remove-KnownFileQuietly {
    param(
        [AllowNull()]
        [string]$Path
    )

    if ([string]::IsNullOrEmpty($Path)) {
        return
    }

    if ([IO.File]::Exists($Path)) {
        try {
            [IO.File]::Delete($Path)
        }
        catch {
            Write-Warning "Could not remove temporary file '$Path': $($_.Exception.Message)"
        }
    }
}

function Set-Tls12 {
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    }
    catch {
        throw "Could not configure TLS 1.2 for HTTPS downloads. Check the Windows/.NET TLS configuration. Details: $($_.Exception.Message)"
    }
}

function Assert-HttpsUri {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Uri
    )

    $parsed = $null
    if (-not [Uri]::TryCreate($Uri, [UriKind]::Absolute, [ref]$parsed)) {
        throw "Refusing invalid download URL '$Uri'."
    }

    if (-not [string]::Equals($parsed.Scheme, 'https', [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing non-HTTPS URL '$Uri'. GitHub downloads must use HTTPS."
    }
}

function Invoke-HttpsRequest {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Uri,
        [AllowNull()]
        [string]$OutFile,
        [switch]$Json
    )

    Assert-HttpsUri -Uri $Uri
    $currentUri = [Uri]$Uri

    for ($redirect = 0; $redirect -le 5; $redirect++) {
        $response = $null
        try {
            $request = [Net.HttpWebRequest]::Create($currentUri)
            $request.Method = 'GET'
            $request.UserAgent = 'gitler-install.ps1'
            $request.Accept = if ($Json) { 'application/vnd.github+json' } else { '*/*' }
            $request.AllowAutoRedirect = $false
            $request.Timeout = 120000
            $request.ReadWriteTimeout = 120000

            $response = $request.GetResponse()
            $statusCode = [int]$response.StatusCode

            if ($statusCode -ge 300 -and $statusCode -lt 400) {
                if ($redirect -ge 5) {
                    throw "Too many HTTPS redirects while requesting '$Uri'."
                }

                $location = $response.Headers['Location']
                if ([string]::IsNullOrEmpty($location)) {
                    throw "HTTPS redirect from '$currentUri' did not include a Location header."
                }

                $nextUri = $null
                if (-not [Uri]::TryCreate($currentUri, $location, [ref]$nextUri)) {
                    throw "HTTPS redirect from '$currentUri' contained an invalid Location header."
                }

                Assert-HttpsUri -Uri $nextUri.AbsoluteUri
                $response.Close()
                $response = $null
                $currentUri = $nextUri
                continue
            }

            if ($statusCode -lt 200 -or $statusCode -ge 300) {
                throw "HTTPS request to '$currentUri' returned HTTP $statusCode ($($response.StatusDescription))."
            }

            $inputStream = $null
            $outputStream = $null
            $reader = $null
            try {
                $inputStream = $response.GetResponseStream()
                if (-not [string]::IsNullOrEmpty($OutFile)) {
                    $outputStream = [IO.File]::Open(
                        $OutFile,
                        [IO.FileMode]::Create,
                        [IO.FileAccess]::Write,
                        [IO.FileShare]::None
                    )
                    $inputStream.CopyTo($outputStream)
                    return $null
                }

                $reader = New-Object -TypeName IO.StreamReader -ArgumentList @(
                    $inputStream,
                    [Text.Encoding]::UTF8,
                    $true
                )
                return $reader.ReadToEnd()
            }
            catch {
                throw "HTTPS request to '$currentUri' failed while reading the response. This may be a proxy, TLS certificate, DNS, or network failure. Details: $($_.Exception.Message)"
            }
            finally {
                if ($null -ne $reader) {
                    $reader.Dispose()
                }
                elseif ($null -ne $inputStream) {
                    $inputStream.Dispose()
                }

                if ($null -ne $outputStream) {
                    $outputStream.Dispose()
                }

                $response.Close()
            }
        }
        catch {
            if ($null -ne $response) {
                try {
                    $response.Close()
                }
                catch {
                }
            }

            $exception = $_.Exception
            $errorResponse = $null
            if ($null -ne $exception.PSObject.Properties['Response']) {
                $errorResponse = $exception.Response
            }

            if ($null -ne $errorResponse) {
                $errorStatus = [int]$errorResponse.StatusCode
                try {
                    $errorResponse.Close()
                }
                catch {
                }

                throw "HTTPS request to '$currentUri' returned HTTP $errorStatus."
            }

            if ($exception.Message -like 'HTTPS request to *failed while reading the response*' -or
                $exception.Message -like 'HTTPS request to *returned HTTP *' -or
                $exception.Message -like 'Refusing non-HTTPS URL *' -or
                $exception.Message -like 'Refusing invalid download URL *' -or
                $exception.Message -like 'HTTPS redirect *' -or
                $exception.Message -like 'Too many HTTPS redirects *') {
                throw $exception.Message
            }

            throw "HTTPS request to '$currentUri' failed. This may be a proxy, TLS certificate, DNS, or network failure. Configure a working system HTTPS proxy and certificate trust, then retry. Details: $($exception.Message)"
        }
    }

    throw "HTTPS request to '$Uri' did not complete."
}

function Get-ExpectedAssetNames {
    param(
        [Parameter(Mandatory = $true)]
        [string]$VersionWithoutTag
    )

    $names = @(
        "gitler-v$VersionWithoutTag-windows-x86_64.exe",
        "gitler-v$VersionWithoutTag-macos-x86_64",
        "gitler-v$VersionWithoutTag-macos-aarch64",
        "gitler-v$VersionWithoutTag-linux-x86_64-gnu",
        'install.sh',
        'install.ps1',
        'SHA256SUMS'
    )

    $sortedNames = New-Object 'System.Collections.Generic.List[string]'
    foreach ($name in $names) {
        [void]$sortedNames.Add($name)
    }

    $sortedNames.Sort([StringComparer]::Ordinal)
    return $sortedNames.ToArray()
}

function Assert-ReleaseAssetNames {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Release,
        [Parameter(Mandatory = $true)]
        [string[]]$ExpectedNames
    )

    $assets = Get-PropertyValue -Object $Release -Name 'assets'
    if ($null -eq $assets) {
        throw 'GitHub latest release response has no assets array.'
    }

    $actualNames = New-Object 'System.Collections.Generic.List[string]'
    $seen = New-Object -TypeName 'System.Collections.Generic.HashSet[string]' -ArgumentList @([StringComparer]::Ordinal)

    foreach ($asset in @($assets)) {
        $name = Get-PropertyValue -Object $asset -Name 'name'
        if ($name -isnot [string] -or [string]::IsNullOrEmpty($name)) {
            throw 'GitHub latest release response contains an asset without a valid name.'
        }

        if (-not $seen.Add($name)) {
            throw "GitHub latest release response contains duplicate asset '$name'."
        }

        [void]$actualNames.Add($name)
    }

    if ($actualNames.Count -ne $ExpectedNames.Count) {
        throw "GitHub latest release has an unexpected asset set: expected exactly $($ExpectedNames.Count) assets, found $($actualNames.Count)."
    }

    foreach ($expectedName in $ExpectedNames) {
        if (-not $seen.Contains($expectedName)) {
            throw "GitHub latest release is missing expected asset '$expectedName'."
        }
    }
}

function ConvertTo-ResolvedRelease {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Release,
        [Parameter(Mandatory = $true)]
        [string]$Description,
        [AllowNull()]
        [string]$ExpectedTag,
        [Parameter(Mandatory = $true)]
        [bool]$UsedLatestApi
    )

    $draft = Get-PropertyValue -Object $Release -Name 'draft'
    $prerelease = Get-PropertyValue -Object $Release -Name 'prerelease'
    if ($draft -ne $false -or $prerelease -ne $false) {
        throw "$Description is draft or prerelease; refusing to install it."
    }

    $tag = Get-PropertyValue -Object $Release -Name 'tag_name'
    if ($tag -isnot [string] -or -not (Test-StableVersion $tag)) {
        throw "$Description has invalid stable tag '$tag'."
    }

    if (-not [string]::IsNullOrEmpty($ExpectedTag) -and $tag -cne $ExpectedTag) {
        throw "$Description resolved tag '$tag', not requested tag '$ExpectedTag'."
    }

    $versionWithoutTag = $tag.Substring(1)
    $expectedNames = Get-ExpectedAssetNames -VersionWithoutTag $versionWithoutTag
    Assert-ReleaseAssetNames -Release $Release -ExpectedNames $expectedNames

    return [pscustomobject][ordered]@{
        Tag             = $tag
        Version         = $versionWithoutTag
        ExpectedAssets  = $expectedNames
        UsedLatestApi   = $UsedLatestApi
    }
}

function Resolve-Release {
    param(
        [AllowNull()]
        [string]$RequestedVersion,
        [Parameter(Mandatory = $true)]
        [bool]$HasExplicitVersion
    )

    if ($HasExplicitVersion) {
        if (-not (Test-StableVersion $RequestedVersion)) {
            throw "Version '$RequestedVersion' is invalid. Use an exact stable tag such as v0.1.0."
        }

        $escapedTag = [Uri]::EscapeDataString($RequestedVersion)
        $apiUri = "https://api.github.com/repos/$RepositoryOwner/$RepositoryName/releases/tags/$escapedTag"
        try {
            $releaseJson = Invoke-HttpsRequest -Uri $apiUri -Json
        }
        catch {
            throw "Could not resolve requested gitler release '$RequestedVersion' over HTTPS. This may be a missing public release, GitHub API rate limit, proxy, TLS certificate, DNS, or network failure. Details: $($_.Exception.Message)"
        }

        try {
            $release = ConvertFrom-Json -InputObject $releaseJson -ErrorAction Stop
        }
        catch {
            throw "GitHub Release API for '$RequestedVersion' returned invalid JSON. Details: $($_.Exception.Message)"
        }

        return ConvertTo-ResolvedRelease -Release $release -Description "GitHub Release '$RequestedVersion'" -ExpectedTag $RequestedVersion -UsedLatestApi $false
    }

    $apiUri = "https://api.github.com/repos/$RepositoryOwner/$RepositoryName/releases/latest"
    try {
        # This is the single latest-release lookup. All later requests use the tag URL.
        $releaseJson = Invoke-HttpsRequest -Uri $apiUri -Json
    }
    catch {
        throw "Could not resolve the latest stable gitler release over HTTPS. This may be a GitHub API rate limit, proxy, TLS certificate, DNS, or network failure. No latest-download fallback was attempted; rerun with -Version vX.Y.Z. Details: $($_.Exception.Message)"
    }

    try {
        $release = ConvertFrom-Json -InputObject $releaseJson -ErrorAction Stop
    }
    catch {
        throw "GitHub latest release API returned invalid JSON. Details: $($_.Exception.Message)"
    }

    return ConvertTo-ResolvedRelease -Release $release -Description 'GitHub latest release' -ExpectedTag $null -UsedLatestApi $true
}

function Get-TagDownloadUri {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Tag,
        [Parameter(Mandatory = $true)]
        [string]$AssetName
    )

    $escapedTag = [Uri]::EscapeDataString($Tag)
    $escapedAsset = [Uri]::EscapeDataString($AssetName)
    $uri = "https://github.com/$RepositoryOwner/$RepositoryName/releases/download/$escapedTag/$escapedAsset"
    Assert-HttpsUri -Uri $uri
    return $uri
}

function Get-ManifestHashes {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ManifestPath,
        [Parameter(Mandatory = $true)]
        [string[]]$ExpectedNames
    )

    $bytes = $null
    try {
        $bytes = [IO.File]::ReadAllBytes($ManifestPath)
    }
    catch {
        throw "Could not read checksum manifest '$ManifestPath'. Details: $($_.Exception.Message)"
    }

    try {
        $encoding = New-Object -TypeName Text.UTF8Encoding -ArgumentList @($false, $true)
        $text = $encoding.GetString($bytes)
    }
    catch {
        throw "SHA256SUMS is not strict UTF-8 text. Details: $($_.Exception.Message)"
    }

    if ($text.IndexOf([char]13) -ge 0) {
        throw 'SHA256SUMS must be LF-delimited and must not contain CRLF line endings.'
    }

    if ($text.IndexOf([char]0xFEFF) -ge 0) {
        throw 'SHA256SUMS must not contain a UTF-8 byte-order mark.'
    }

    if (-not $text.EndsWith("`n", [StringComparison]::Ordinal)) {
        throw 'SHA256SUMS must end with an LF newline.'
    }

    if ($text.Length -le 1) {
        throw 'SHA256SUMS is empty.'
    }

    $content = $text.Substring(0, $text.Length - 1)
    $lines = $content.Split([char]10)
    $hashes = New-Object -TypeName 'System.Collections.Generic.Dictionary[string,string]' -ArgumentList @([StringComparer]::Ordinal)
    $previousName = $null

    foreach ($line in $lines) {
        $match = [regex]::Match(
            $line,
            '\A([0-9a-f]{64})  ([^\s]+)\z',
            [Text.RegularExpressions.RegexOptions]::CultureInvariant
        )

        if (-not $match.Success) {
            throw "SHA256SUMS contains a malformed line: '$line'. Expected 64 lowercase hex characters, two spaces, and a filename."
        }

        $hash = $match.Groups[1].Value
        $name = $match.Groups[2].Value

        if ($null -ne $previousName -and [string]::CompareOrdinal($previousName, $name) -gt 0) {
            throw 'SHA256SUMS entries must be sorted by filename using ordinal order.'
        }

        if ($hashes.ContainsKey($name)) {
            throw "SHA256SUMS contains duplicate entry '$name'."
        }

        [void]$hashes.Add($name, $hash)
        $previousName = $name
    }

    if ($hashes.Count -ne $ExpectedNames.Count) {
        throw "SHA256SUMS must contain exactly one entry for each expected release asset; found $($hashes.Count) entries."
    }

    foreach ($expectedName in $ExpectedNames) {
        if (-not $hashes.ContainsKey($expectedName)) {
            throw "SHA256SUMS is missing expected entry '$expectedName'."
        }
    }

    return ,$hashes
}

function Get-StateFromFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$StatePath,
        [Parameter(Mandatory = $true)]
        [string]$InstallDirectory
    )

    Assert-RegularFile -Path $StatePath -Description 'Installer state file'

    $json = $null
    try {
        $json = [IO.File]::ReadAllText($StatePath)
    }
    catch {
        throw "Could not read installer state '$StatePath'. Details: $($_.Exception.Message)"
    }

    $state = $null
    try {
        $state = ConvertFrom-Json -InputObject $json -ErrorAction Stop
    }
    catch {
        throw "Installer state '$StatePath' is not valid JSON. Details: $($_.Exception.Message)"
    }

    if ($null -eq $state) {
        throw "Installer state '$StatePath' is empty."
    }

    $allowedProperties = @(
        'FormatVersion',
        'InstalledVersion',
        'AssetName',
        'Sha256',
        'PathAdded',
        'InstallDirectory'
    )
    $actualProperties = @($state.PSObject.Properties | ForEach-Object { $_.Name })

    if ($actualProperties.Count -ne $allowedProperties.Count) {
        throw "Installer state '$StatePath' has an unsupported format."
    }

    foreach ($allowedProperty in $allowedProperties) {
        if (-not ($actualProperties -ccontains $allowedProperty)) {
            throw "Installer state '$StatePath' is missing '$allowedProperty'."
        }
    }

    foreach ($actualProperty in $actualProperties) {
        if (-not ($allowedProperties -ccontains $actualProperty)) {
            throw "Installer state '$StatePath' contains unsupported property '$actualProperty'."
        }
    }

    $formatVersion = Get-PropertyValue -Object $state -Name 'FormatVersion'
    if (($formatVersion -isnot [int]) -and ($formatVersion -isnot [long])) {
        throw "Installer state '$StatePath' has an invalid format version."
    }

    if ([int64]$formatVersion -ne $StateFormatVersion) {
        throw "Installer state '$StatePath' uses unsupported format version '$formatVersion'."
    }

    $installedVersion = Get-PropertyValue -Object $state -Name 'InstalledVersion'
    if ($installedVersion -isnot [string] -or -not (Test-StableVersionWithoutTag $installedVersion)) {
        throw "Installer state '$StatePath' has an invalid installed version."
    }

    $assetName = Get-PropertyValue -Object $state -Name 'AssetName'
    $expectedAssetName = "gitler-v$installedVersion-windows-x86_64.exe"
    if ($assetName -isnot [string] -or $assetName -cne $expectedAssetName) {
        throw "Installer state '$StatePath' has an invalid executable asset name."
    }

    $sha256 = Get-PropertyValue -Object $state -Name 'Sha256'
    if ($sha256 -isnot [string] -or -not [regex]::IsMatch($sha256, '\A[0-9a-f]{64}\z', [Text.RegularExpressions.RegexOptions]::CultureInvariant)) {
        throw "Installer state '$StatePath' has an invalid lowercase SHA-256 hash."
    }

    $pathAdded = Get-PropertyValue -Object $state -Name 'PathAdded'
    if ($pathAdded -isnot [bool]) {
        throw "Installer state '$StatePath' has invalid PATH ownership data."
    }

    $recordedDirectory = Get-PropertyValue -Object $state -Name 'InstallDirectory'
    if ($recordedDirectory -isnot [string]) {
        throw "Installer state '$StatePath' has no valid install directory."
    }

    $normalizedRecordedDirectory = Get-NormalizedDirectoryPath -Path $recordedDirectory
    if (-not [string]::Equals($normalizedRecordedDirectory, $InstallDirectory, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Installer state '$StatePath' does not belong to selected install directory '$InstallDirectory'."
    }

    return $state
}

function New-StateObject {
    param(
        [Parameter(Mandatory = $true)]
        [string]$VersionWithoutTag,
        [Parameter(Mandatory = $true)]
        [string]$AssetName,
        [Parameter(Mandatory = $true)]
        [string]$Sha256,
        [Parameter(Mandatory = $true)]
        [bool]$PathAdded,
        [Parameter(Mandatory = $true)]
        [string]$InstallDirectory
    )

    return [pscustomobject][ordered]@{
        FormatVersion     = $StateFormatVersion
        InstalledVersion  = $VersionWithoutTag
        AssetName         = $AssetName
        Sha256            = $Sha256
        PathAdded         = $PathAdded
        InstallDirectory  = $InstallDirectory
    }
}

function Write-StateFile {
    param(
        [Parameter(Mandatory = $true)]
        [object]$State,
        [Parameter(Mandatory = $true)]
        [string]$StatePath,
        [Parameter(Mandatory = $true)]
        [bool]$PreviouslyExisted
    )

    $stateDirectory = [IO.Path]::GetDirectoryName($StatePath)
    $stagePath = $null
    $backupPath = $null
    $committed = $false

    try {
        $stagePath = New-UniqueFile -Directory $stateDirectory -Prefix '.gitler-state-' -Extension '.tmp'
        $json = ConvertTo-Json -InputObject $State -Depth 4
        $encoding = New-Object -TypeName Text.UTF8Encoding -ArgumentList @($false)
        [IO.File]::WriteAllText($stagePath, $json, $encoding)

        if ($PreviouslyExisted) {
            $backupPath = New-UniqueUnusedPath -Directory $stateDirectory -Prefix '.gitler-state-backup-' -Extension '.tmp'
            [IO.File]::Replace($stagePath, $StatePath, $backupPath, $true)
        }
        else {
            [IO.File]::Move($stagePath, $StatePath)
        }

        $committed = $true
    }
    catch {
        throw "Could not write installer state '$StatePath'. Details: $($_.Exception.Message)"
    }
    finally {
        if ($null -ne $stagePath -and [IO.File]::Exists($stagePath)) {
            Remove-KnownFileQuietly -Path $stagePath
        }
    }

    return [pscustomobject][ordered]@{
        Committed   = $committed
        HadExisting = $PreviouslyExisted
        BackupPath  = $backupPath
        StatePath   = $StatePath
    }
}

function Restore-StateFile {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Transaction
    )

    $statePath = $Transaction.StatePath
    if ($Transaction.HadExisting) {
        if ([string]::IsNullOrEmpty($Transaction.BackupPath) -or -not [IO.File]::Exists($Transaction.BackupPath)) {
            throw "Installer state rollback backup is missing for '$statePath'."
        }

        Assert-RegularFile -Path $statePath -Description 'Current installer state file'
        $rollbackPath = New-UniqueUnusedPath -Directory ([IO.Path]::GetDirectoryName($statePath)) -Prefix '.gitler-state-rollback-' -Extension '.tmp'
        [IO.File]::Replace($Transaction.BackupPath, $statePath, $rollbackPath, $true)
        Remove-KnownFileQuietly -Path $rollbackPath
    }
    else {
        if ([IO.File]::Exists($statePath)) {
            Assert-RegularFile -Path $statePath -Description 'New installer state file'
            [IO.File]::Delete($statePath)
        }
    }

    $Transaction.BackupPath = $null
}

function Replace-ManagedExecutable {
    param(
        [Parameter(Mandatory = $true)]
        [string]$StagePath,
        [Parameter(Mandatory = $true)]
        [string]$DestinationPath,
        [Parameter(Mandatory = $true)]
        [bool]$PreviouslyExisted
    )

    $directory = [IO.Path]::GetDirectoryName($DestinationPath)
    $backupPath = $null
    $committed = $false

    try {
        if ($PreviouslyExisted) {
            Assert-RegularFile -Path $DestinationPath -Description 'Existing gitler executable'
            $backupPath = New-UniqueUnusedPath -Directory $directory -Prefix '.gitler-executable-backup-' -Extension '.tmp'
            [IO.File]::Replace($StagePath, $DestinationPath, $backupPath, $true)
        }
        else {
            if ([IO.File]::Exists($DestinationPath) -or [IO.Directory]::Exists($DestinationPath)) {
                throw "Destination '$DestinationPath' appeared while installation was in progress."
            }

            [IO.File]::Move($StagePath, $DestinationPath)
        }

        $committed = $true
    }
    catch {
        if ($PreviouslyExisted) {
            throw "Could not replace '$DestinationPath'. The existing executable may be locked by a running process or blocked by antivirus; the old version was left intact. Details: $($_.Exception.Message)"
        }

        throw "Could not install '$DestinationPath'. Details: $($_.Exception.Message)"
    }

    return [pscustomobject][ordered]@{
        Committed   = $committed
        HadExisting = $PreviouslyExisted
        BackupPath  = $backupPath
        Destination = $DestinationPath
    }
}

function Restore-ReplacedExecutable {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Transaction
    )

    $destinationPath = $Transaction.Destination
    if ($Transaction.HadExisting) {
        if ([string]::IsNullOrEmpty($Transaction.BackupPath) -or -not [IO.File]::Exists($Transaction.BackupPath)) {
            throw "Executable rollback backup is missing for '$destinationPath'."
        }

        Assert-RegularFile -Path $destinationPath -Description 'Current gitler executable'
        $rollbackPath = New-UniqueUnusedPath -Directory ([IO.Path]::GetDirectoryName($destinationPath)) -Prefix '.gitler-executable-rollback-' -Extension '.tmp'
        [IO.File]::Replace($Transaction.BackupPath, $destinationPath, $rollbackPath, $true)
        Remove-KnownFileQuietly -Path $rollbackPath
    }
    else {
        if ([IO.File]::Exists($destinationPath)) {
            Assert-RegularFile -Path $destinationPath -Description 'New gitler executable'
            [IO.File]::Delete($destinationPath)
        }
    }

    $Transaction.BackupPath = $null
}

function Get-PathEntries {
    param(
        [AllowNull()]
        [string]$Value
    )

    if ([string]::IsNullOrEmpty($Value)) {
        return
    }

    return $Value.Split([char][IO.Path]::PathSeparator, [StringSplitOptions]::None)
}

function Join-PathEntries {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Entries
    )

    if ($Entries.Count -eq 0) {
        return $null
    }

    return [string]::Join([string][IO.Path]::PathSeparator, [string[]]$Entries)
}

function Normalize-PathEntry {
    param(
        [AllowNull()]
        [string]$Entry
    )

    if ($null -eq $Entry) {
        return ''
    }

    $candidate = $Entry.Trim()
    if ($candidate.Length -ge 2 -and $candidate[0] -eq [char]34 -and $candidate[$candidate.Length - 1] -eq [char]34) {
        $candidate = $candidate.Substring(1, $candidate.Length - 2)
    }

    if ([string]::IsNullOrEmpty($candidate)) {
        return ''
    }

    try {
        $fullPath = [IO.Path]::GetFullPath($candidate)
        $root = [IO.Path]::GetPathRoot($fullPath)
        if ($fullPath.Length -gt $root.Length) {
            $fullPath = $fullPath.TrimEnd([char[]]@('\', '/'))
        }

        return $fullPath
    }
    catch {
        return $candidate.TrimEnd([char[]]@('\', '/'))
    }
}

function Get-PathPlan {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InstallDirectory,
        [Parameter(Mandatory = $true)]
        [bool]$StatePathAdded,
        [Parameter(Mandatory = $true)]
        [bool]$ForAdd,
        [Parameter(Mandatory = $true)]
        [bool]$ForRemove
    )

    $currentValue = [Environment]::GetEnvironmentVariable('Path', [EnvironmentVariableTarget]::User)
    $entries = @(Get-PathEntries -Value $currentValue)
    $targetNormalized = Normalize-PathEntry -Entry $InstallDirectory
    $hasExactTarget = $false

    foreach ($entry in $entries) {
        if ([string]::Equals((Normalize-PathEntry -Entry $entry), $targetNormalized, [StringComparison]::OrdinalIgnoreCase)) {
            $hasExactTarget = $true
            break
        }
    }

    $newEntries = New-Object 'System.Collections.Generic.List[string]'
    foreach ($entry in $entries) {
        [void]$newEntries.Add($entry)
    }

    $desiredOwnership = $StatePathAdded
    $changed = $false
    $processAction = 'None'

    if ($ForAdd) {
        $processAction = 'Add'
        if ($StatePathAdded) {
            $desiredOwnership = $true
            if (-not $hasExactTarget) {
                [void]$newEntries.Add($InstallDirectory)
                $changed = $true
            }
        }
        elseif (-not $hasExactTarget) {
            [void]$newEntries.Add($InstallDirectory)
            $desiredOwnership = $true
            $changed = $true
        }
        else {
            # An existing user entry is usable but is not installer-owned.
            $desiredOwnership = $false
        }
    }
    elseif ($ForRemove) {
        $desiredOwnership = $false
        if ($StatePathAdded) {
            $processAction = 'Remove'
            $filteredEntries = New-Object 'System.Collections.Generic.List[string]'
            foreach ($entry in $entries) {
                if (-not [string]::Equals((Normalize-PathEntry -Entry $entry), $targetNormalized, [StringComparison]::OrdinalIgnoreCase)) {
                    [void]$filteredEntries.Add($entry)
                }
                else {
                    $changed = $true
                }
            }

            $newEntries = $filteredEntries
        }
    }

    $newValue = $currentValue
    if ($changed) {
        $newValue = Join-PathEntries -Entries $newEntries.ToArray()
    }

    return [pscustomobject][ordered]@{
        CurrentValue      = $currentValue
        NewValue          = $newValue
        Changed           = $changed
        DesiredOwnership  = [bool]$desiredOwnership
        ProcessAction     = $processAction
    }
}

function Set-UserPathValue {
    param(
        [AllowNull()]
        [string]$Value
    )

    try {
        [Environment]::SetEnvironmentVariable('Path', $Value, [EnvironmentVariableTarget]::User)
    }
    catch {
        throw "Could not update the User-scope PATH. This may be a registry permission or profile policy problem. Details: $($_.Exception.Message)"
    }
}

function Update-CurrentProcessPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InstallDirectory,
        [Parameter(Mandatory = $true)]
        [ValidateSet('Add', 'Remove', 'None')]
        [string]$Action
    )

    if ($Action -eq 'None') {
        return
    }

    $currentValue = [Environment]::GetEnvironmentVariable('Path', [EnvironmentVariableTarget]::Process)
    $entries = @(Get-PathEntries -Value $currentValue)
    $targetNormalized = Normalize-PathEntry -Entry $InstallDirectory
    $newEntries = New-Object 'System.Collections.Generic.List[string]'

    foreach ($entry in $entries) {
        $isTarget = [string]::Equals((Normalize-PathEntry -Entry $entry), $targetNormalized, [StringComparison]::OrdinalIgnoreCase)
        if ($Action -eq 'Remove' -and $isTarget) {
            continue
        }

        [void]$newEntries.Add($entry)
    }

    if ($Action -eq 'Add') {
        $hasTarget = $false
        foreach ($entry in $newEntries) {
            if ([string]::Equals((Normalize-PathEntry -Entry $entry), $targetNormalized, [StringComparison]::OrdinalIgnoreCase)) {
                $hasTarget = $true
                break
            }
        }

        if (-not $hasTarget) {
            [void]$newEntries.Add($InstallDirectory)
        }
    }

    $newValue = Join-PathEntries -Entries $newEntries.ToArray()
    if ($currentValue -cne $newValue) {
        [Environment]::SetEnvironmentVariable('Path', $newValue, [EnvironmentVariableTarget]::Process)
    }
}

function Broadcast-EnvironmentChange {
    try {
        $typeName = [System.Management.Automation.PSTypeName]'GitlerInstallerNativeMethods'
        if ($null -eq $typeName.Type) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class GitlerInstallerNativeMethods
{
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern IntPtr SendMessageTimeout(
        IntPtr hWnd,
        uint Msg,
        UIntPtr wParam,
        string lParam,
        uint fuFlags,
        uint uTimeout,
        out UIntPtr lpdwResult);
}
'@
        }

        $result = [UIntPtr]::Zero
        [void][GitlerInstallerNativeMethods]::SendMessageTimeout(
            [IntPtr](-1),
            0x001A,
            [UIntPtr]::Zero,
            'Environment',
            0x0002,
            5000,
            [ref]$result
        )
    }
    catch {
        Write-Warning "User PATH changed, but the Windows environment-change broadcast was unavailable. New processes will still receive the updated User PATH. Details: $($_.Exception.Message)"
    }
}

function Invoke-StagedCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ExecutablePath,
        [Parameter(Mandatory = $true)]
        [string]$Argument
    )

    Assert-RegularFile -Path $ExecutablePath -Description 'Staged executable'
    $absolutePath = [IO.Path]::GetFullPath($ExecutablePath)
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $absolutePath
    $startInfo.Arguments = $Argument
    $startInfo.WorkingDirectory = [IO.Path]::GetDirectoryName($absolutePath)
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true

    $process = New-Object Diagnostics.Process
    $process.StartInfo = $startInfo

    try {
        $started = $process.Start()
        if (-not $started) {
            throw "Process.Start returned false for '$absolutePath'."
        }

        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(60000)) {
            try {
                $process.Kill()
            }
            catch {
            }

            throw "Executable '$absolutePath' did not exit within 60 seconds for argument '$Argument'."
        }

        $stdout = $stdoutTask.Result
        $stderr = $stderrTask.Result
        return [pscustomobject][ordered]@{
            ExitCode = $process.ExitCode
            StdOut   = $stdout
            StdErr   = $stderr
        }
    }
    catch {
        throw "Could not run staged executable '$absolutePath' with '$Argument'. Details: $($_.Exception.Message)"
    }
    finally {
        $process.Dispose()
    }
}

function Assert-StagedExecutable {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ExecutablePath,
        [Parameter(Mandatory = $true)]
        [string]$ExpectedVersion
    )

    $versionResult = Invoke-StagedCommand -ExecutablePath $ExecutablePath -Argument '--version'
    if ($versionResult.ExitCode -ne 0) {
        throw "Staged executable --version failed with exit code $($versionResult.ExitCode). Output: $($versionResult.StdErr.Trim())"
    }

    $expectedDisplay = "gitler $ExpectedVersion"
    if ($versionResult.StdOut.Trim() -cne $expectedDisplay) {
        throw "Staged executable reported '$($versionResult.StdOut.Trim())'; expected exactly '$expectedDisplay'."
    }

    $helpResult = Invoke-StagedCommand -ExecutablePath $ExecutablePath -Argument '--help'
    if ($helpResult.ExitCode -ne 0) {
        throw "Staged executable --help failed with exit code $($helpResult.ExitCode). Output: $($helpResult.StdErr.Trim())"
    }

    if ([string]::IsNullOrWhiteSpace($helpResult.StdOut) -and [string]::IsNullOrWhiteSpace($helpResult.StdErr)) {
        throw 'Staged executable --help produced no output.'
    }
}

function Invoke-Uninstall {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InstallDirectory,
        [Parameter(Mandatory = $true)]
        [bool]$RemoveOwnedPath
    )

    Assert-SafeInstallDirectory -Path $InstallDirectory
    if (-not [IO.Directory]::Exists($InstallDirectory)) {
        if ([IO.File]::Exists($InstallDirectory)) {
            throw "Cannot uninstall because '$InstallDirectory' is a file."
        }

        Write-Output "gitler is not installed at '$InstallDirectory'."
        return
    }

    $statePath = [IO.Path]::Combine($InstallDirectory, $StateFileName)
    if (-not [IO.File]::Exists($statePath)) {
        throw "Refusing to uninstall unrecognized directory '$InstallDirectory': installer state is missing."
    }

    $state = Get-StateFromFile -StatePath $statePath -InstallDirectory $InstallDirectory
    if ([bool]$state.PathAdded -and -not $RemoveOwnedPath) {
        throw 'Installer added this directory to User PATH; rerun uninstall with -RemovePath to remove the owned entry safely.'
    }
    $destinationPath = [IO.Path]::Combine($InstallDirectory, $ExecutableFileName)
    Assert-RegularFile -Path $destinationPath -Description 'Managed gitler executable'

    $pathPlan = $null
    if ($RemoveOwnedPath) {
        $pathPlan = Get-PathPlan -InstallDirectory $InstallDirectory -StatePathAdded ([bool]$state.PathAdded) -ForAdd $false -ForRemove $true
    }

    $executableBackup = $null
    $stateBackup = $null
    $movedExecutable = $false
    $movedState = $false
    $userPathChanged = $false

    try {
        $executableBackup = New-UniqueUnusedPath -Directory $InstallDirectory -Prefix '.gitler-uninstall-executable-' -Extension '.tmp'
        $stateBackup = New-UniqueUnusedPath -Directory $InstallDirectory -Prefix '.gitler-uninstall-state-' -Extension '.tmp'

        [IO.File]::Move($destinationPath, $executableBackup)
        $movedExecutable = $true
        [IO.File]::Move($statePath, $stateBackup)
        $movedState = $true

        if ($null -ne $pathPlan -and $pathPlan.Changed) {
            Set-UserPathValue -Value $pathPlan.NewValue
            $userPathChanged = $true
        }

        [IO.File]::Delete($executableBackup)
        $executableBackup = $null
        [IO.File]::Delete($stateBackup)
        $stateBackup = $null
    }
    catch {
        $failure = $_.Exception.Message
        $rollbackErrors = New-Object 'System.Collections.Generic.List[string]'

        if ($userPathChanged) {
            try {
                Set-UserPathValue -Value $pathPlan.CurrentValue
            }
            catch {
                [void]$rollbackErrors.Add("User PATH rollback failed: $($_.Exception.Message)")
            }
        }

        if ($movedState -and $null -ne $stateBackup -and [IO.File]::Exists($stateBackup) -and -not [IO.File]::Exists($statePath)) {
            try {
                [IO.File]::Move($stateBackup, $statePath)
                $stateBackup = $null
            }
            catch {
                [void]$rollbackErrors.Add("State rollback failed: $($_.Exception.Message)")
            }
        }

        if ($movedExecutable -and $null -ne $executableBackup -and [IO.File]::Exists($executableBackup) -and -not [IO.File]::Exists($destinationPath)) {
            try {
                [IO.File]::Move($executableBackup, $destinationPath)
                $executableBackup = $null
            }
            catch {
                [void]$rollbackErrors.Add("Executable rollback failed: $($_.Exception.Message)")
            }
        }

        if ($rollbackErrors.Count -gt 0) {
            throw "Uninstall failed: $failure Rollback also failed: $([string]::Join('; ', $rollbackErrors.ToArray()))"
        }

        throw "Uninstall failed: $failure Managed files were left intact where possible."
    }
    finally {
        if ($null -ne $executableBackup) {
            Remove-KnownFileQuietly -Path $executableBackup
        }
        if ($null -ne $stateBackup) {
            Remove-KnownFileQuietly -Path $stateBackup
        }
    }

    if ($null -ne $pathPlan -and $pathPlan.ProcessAction -ne 'None') {
        try {
            Update-CurrentProcessPath -InstallDirectory $InstallDirectory -Action $pathPlan.ProcessAction
            if ($pathPlan.Changed) {
                Broadcast-EnvironmentChange
            }
        }
        catch {
            Write-Warning "Managed files were uninstalled, but the current process PATH could not be updated. Open a new terminal. Details: $($_.Exception.Message)"
        }
    }

    if (@([IO.Directory]::GetFileSystemEntries($InstallDirectory)).Count -eq 0) {
        try {
            [IO.Directory]::Delete($InstallDirectory)
        }
        catch {
            Write-Warning "Managed files were uninstalled, but empty directory '$InstallDirectory' could not be removed: $($_.Exception.Message)"
        }
    }
    else {
        Write-Output "Uninstalled managed gitler files; unrelated files in '$InstallDirectory' were preserved."
    }

    if ($RemoveOwnedPath -and [bool]$state.PathAdded) {
        if ($null -ne $pathPlan -and $pathPlan.Changed) {
            Write-Output "Removed the exact installer-owned directory from User PATH. Open a new terminal for other processes to observe the change."
        }
        else {
            Write-Output 'Installer-owned PATH entry was already absent.'
        }
    }
    elseif ([bool]$state.PathAdded) {
        Write-Output 'The installer-owned PATH entry was retained. Re-run with -RemovePath to remove it.'
    }

    Write-Output "Uninstalled gitler from '$InstallDirectory'."
}

function Get-TargetWindowsArchitecture {
    $processArchitecture = [Environment]::GetEnvironmentVariable('PROCESSOR_ARCHITECTURE', [EnvironmentVariableTarget]::Process)
    $wowArchitecture = [Environment]::GetEnvironmentVariable('PROCESSOR_ARCHITEW6432', [EnvironmentVariableTarget]::Process)
    $systemArchitecture = $null

    $runtimeType = ([System.Management.Automation.PSTypeName]'System.Runtime.InteropServices.RuntimeInformation').Type
    if ($null -ne $runtimeType) {
        try {
            $architectureProperty = $runtimeType.GetProperty('OSArchitecture')
            if ($null -ne $architectureProperty) {
                $systemArchitecture = [string]$architectureProperty.GetValue($null, $null)
            }
        }
        catch {
            $systemArchitecture = $null
        }
    }

    if ([string]::IsNullOrWhiteSpace($systemArchitecture)) {
        try {
            $systemArchitecture = [string][Microsoft.Win32.Registry]::GetValue(
                'HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\Session Manager\Environment',
                'PROCESSOR_ARCHITECTURE',
                $null
            )
        }
        catch {
            $systemArchitecture = $null
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($wowArchitecture)) {
        # This variable is the native OS architecture when a 32-bit process runs on a 64-bit OS.
        return $wowArchitecture.ToUpperInvariant()
    }

    if (-not [string]::IsNullOrWhiteSpace($systemArchitecture)) {
        $normalizedSystemArchitecture = $systemArchitecture.ToUpperInvariant()
        if ($normalizedSystemArchitecture -eq 'X86' -and [Environment]::Is64BitOperatingSystem) {
            return 'AMD64'
        }

        return $normalizedSystemArchitecture
    }

    if ([string]::Equals($processArchitecture, 'x86', [StringComparison]::OrdinalIgnoreCase) -and [Environment]::Is64BitOperatingSystem) {
        return 'AMD64'
    }

    return $processArchitecture
}

$hasExplicitVersion = $PSBoundParameters.ContainsKey('Version')
$hasExplicitInstallDirectory = $PSBoundParameters.ContainsKey('InstallDir')

if ($AddToPath -and $RemovePath) {
    throw 'AddToPath and RemovePath cannot be used together.'
}

if ($RemovePath -and $hasExplicitVersion) {
    throw 'RemovePath cannot be combined with Version; select the install directory and remove the owned PATH entry only.'
}

if ($RemovePath -and ($Force -or $AllowDowngrade)) {
    throw 'RemovePath cannot be combined with Force or AllowDowngrade.'
}

if ($Uninstall) {
    if ($hasExplicitVersion -or $Force -or $AllowDowngrade -or $AddToPath) {
        throw 'Uninstall cannot be combined with Version, Force, AllowDowngrade, or AddToPath. Use RemovePath explicitly when PATH removal is wanted.'
    }
}

if ($hasExplicitVersion -and -not (Test-StableVersion $Version)) {
    throw "Version '$Version' is invalid. Use an exact stable tag such as v0.1.0."
}

if ($hasExplicitInstallDirectory) {
    if ([string]::IsNullOrWhiteSpace($InstallDir)) {
        throw 'InstallDir must be a non-empty directory path.'
    }
}
else {
    if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        throw 'LOCALAPPDATA is not set; specify -InstallDir explicitly.'
    }

    $InstallDir = [IO.Path]::Combine($env:LOCALAPPDATA, 'Programs', 'gitler')
}

$normalizedInstallDirectory = Get-NormalizedDirectoryPath -Path $InstallDir
if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
    $localAppDataDirectory = Get-NormalizedDirectoryPath -Path $env:LOCALAPPDATA
    $programsDirectory = Get-NormalizedDirectoryPath -Path ([IO.Path]::Combine($env:LOCALAPPDATA, 'Programs'))
    if ([string]::Equals($normalizedInstallDirectory, $localAppDataDirectory, [StringComparison]::OrdinalIgnoreCase) -or
        [string]::Equals($normalizedInstallDirectory, $programsDirectory, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'InstallDir must be a dedicated child directory; shared LOCALAPPDATA locations cannot be managed.'
    }
}

$targetArchitecture = Get-TargetWindowsArchitecture
if ([string]::IsNullOrWhiteSpace($targetArchitecture)) {
    throw 'Could not determine the Windows operating-system architecture.'
}

switch ($targetArchitecture.ToUpperInvariant()) {
    'AMD64' { }
    'X64' { }
    'ARM64' { throw 'Windows ARM64 is not supported by the published gitler assets.' }
    'ARM' { throw 'Windows ARM is not supported by the published gitler assets.' }
    'X86' { throw '32-bit Windows is not supported; gitler provides a Windows x86_64 asset only.' }
    default { throw "Unsupported Windows operating-system architecture '$targetArchitecture'." }
}

$operation = if ($Uninstall) { "Uninstall managed gitler files from '$normalizedInstallDirectory'" } else { "Install or update gitler in '$normalizedInstallDirectory'" }
if (-not $PSCmdlet.ShouldProcess($normalizedInstallDirectory, $operation)) {
    return
}

if ($Uninstall) {
    Invoke-Uninstall -InstallDirectory $normalizedInstallDirectory -RemoveOwnedPath ([bool]$RemovePath)
    return
}

$installDirectoryExists = [IO.Directory]::Exists($normalizedInstallDirectory)
Assert-SafeInstallDirectory -Path $normalizedInstallDirectory
if ([IO.File]::Exists($normalizedInstallDirectory)) {
    throw "InstallDir '$normalizedInstallDirectory' is an existing file, not a directory."
}

$statePath = [IO.Path]::Combine($normalizedInstallDirectory, $StateFileName)
$destinationPath = [IO.Path]::Combine($normalizedInstallDirectory, $ExecutableFileName)
$stateExists = $false
$state = $null
$existingHash = $null

if ($installDirectoryExists) {
    $stateExists = [IO.File]::Exists($statePath)
    if (-not $stateExists) {
        throw "Refusing existing unrecognized install directory '$normalizedInstallDirectory': installer state is missing."
    }

    $state = Get-StateFromFile -StatePath $statePath -InstallDirectory $normalizedInstallDirectory
    Assert-RegularFile -Path $destinationPath -Description 'Managed gitler executable'

    if ($RemovePath) {
        if (-not [bool]$state.PathAdded) {
            Write-Output "No installer-owned PATH entry is recorded for '$normalizedInstallDirectory'."
            return
        }

        $pathOnlyPlan = Get-PathPlan -InstallDirectory $normalizedInstallDirectory -StatePathAdded $true -ForAdd $false -ForRemove $true
        $pathOnlyStateTransaction = $null
        $pathOnlyChanged = $false
        try {
            if ($pathOnlyPlan.Changed) {
                Set-UserPathValue -Value $pathOnlyPlan.NewValue
                $pathOnlyChanged = $true
            }

            $pathOnlyState = New-StateObject -VersionWithoutTag ([string]$state.InstalledVersion) -AssetName ([string]$state.AssetName) -Sha256 ([string]$state.Sha256) -PathAdded $false -InstallDirectory $normalizedInstallDirectory
            $pathOnlyStateTransaction = Write-StateFile -State $pathOnlyState -StatePath $statePath -PreviouslyExisted $true

            if ($pathOnlyPlan.ProcessAction -ne 'None') {
                Update-CurrentProcessPath -InstallDirectory $normalizedInstallDirectory -Action $pathOnlyPlan.ProcessAction
            }
            if ($pathOnlyPlan.Changed) {
                Broadcast-EnvironmentChange
            }

            if ($null -ne $pathOnlyStateTransaction.BackupPath) {
                Remove-KnownFileQuietly -Path $pathOnlyStateTransaction.BackupPath
                $pathOnlyStateTransaction.BackupPath = $null
            }
        }
        catch {
            $pathOnlyFailure = $_.Exception.Message
            if ($null -ne $pathOnlyStateTransaction -and $pathOnlyStateTransaction.Committed) {
                try {
                    Restore-StateFile -Transaction $pathOnlyStateTransaction
                }
                catch {
                    $pathOnlyFailure = "$pathOnlyFailure State rollback failed: $($_.Exception.Message)"
                }
            }
            if ($pathOnlyChanged) {
                try {
                    Set-UserPathValue -Value $pathOnlyPlan.CurrentValue
                }
                catch {
                    $pathOnlyFailure = "$pathOnlyFailure PATH rollback failed: $($_.Exception.Message)"
                }
            }
            throw "PATH removal failed: $pathOnlyFailure"
        }

        if ($pathOnlyPlan.Changed) {
            Write-Output "Removed the exact installer-owned directory from User PATH. Open a new terminal for other processes to observe the change."
        }
        else {
            Write-Output 'Installer-owned PATH entry was already absent; ownership state was cleared.'
        }
        return
    }

    try {
        $existingHash = (Get-FileHash -LiteralPath $destinationPath -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
    }
    catch {
        throw "Could not read managed executable '$destinationPath'. It may be locked by another process or blocked by antivirus; the old version was left intact. Details: $($_.Exception.Message)"
    }

    if ($existingHash -cne $state.Sha256 -and -not $Force) {
        throw "Managed executable '$destinationPath' has a hash different from installer state; use -Force only after reviewing the file."
    }
}
elseif ([IO.File]::Exists($statePath) -or [IO.Directory]::Exists($statePath) -or [IO.File]::Exists($destinationPath) -or [IO.Directory]::Exists($destinationPath)) {
    throw "InstallDir '$normalizedInstallDirectory' is not a clean first-install location."
}

Set-Tls12
$release = Resolve-Release -RequestedVersion $Version -HasExplicitVersion ([bool]$hasExplicitVersion)
$resolvedVersion = $release.Version
$assetName = "gitler-$($release.Tag)-windows-x86_64.exe"
$manifestName = 'SHA256SUMS'

if ($stateExists) {
    $versionComparison = Compare-StableVersion -Left $resolvedVersion -Right ([string]$state.InstalledVersion)
    if ($versionComparison -lt 0 -and -not $AllowDowngrade) {
        throw "Refusing downgrade from v$($state.InstalledVersion) to v$resolvedVersion. Use -AllowDowngrade explicitly."
    }
}

$tempFiles = New-Object 'System.Collections.Generic.List[string]'
$stagePath = $null
$createdInstallDirectory = $false
$installationCommitted = $false

try {
    $tempDirectory = [IO.Path]::GetTempPath()
    $executableTempPath = New-UniqueFile -Directory $tempDirectory -Prefix 'gitler-download-' -Extension '.exe'
    [void]$tempFiles.Add($executableTempPath)
    $manifestTempPath = New-UniqueFile -Directory $tempDirectory -Prefix 'gitler-manifest-' -Extension '.txt'
    [void]$tempFiles.Add($manifestTempPath)

    $executableUri = Get-TagDownloadUri -Tag $release.Tag -AssetName $assetName
    $manifestUri = Get-TagDownloadUri -Tag $release.Tag -AssetName $manifestName
    Invoke-HttpsRequest -Uri $executableUri -OutFile $executableTempPath | Out-Null
    Invoke-HttpsRequest -Uri $manifestUri -OutFile $manifestTempPath | Out-Null

    $checksumNames = @($release.ExpectedAssets | Where-Object { $_ -cne 'SHA256SUMS' })
    $manifestHashes = Get-ManifestHashes -ManifestPath $manifestTempPath -ExpectedNames $checksumNames
    if (-not $manifestHashes.ContainsKey($assetName)) {
        throw "SHA256SUMS has no exact entry for expected executable '$assetName'."
    }

    $expectedHash = $manifestHashes[$assetName]
    $downloadedHash = (Get-FileHash -LiteralPath $executableTempPath -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
    if ($downloadedHash -cne $expectedHash) {
        throw "SHA-256 verification failed for '$assetName': expected $expectedHash, got $downloadedHash."
    }

    $needsExecutableReplacement = $true
    if ($stateExists) {
        $sameVersion = (Compare-StableVersion -Left $resolvedVersion -Right ([string]$state.InstalledVersion)) -eq 0
        if ($sameVersion -and $existingHash -cne $downloadedHash -and -not $Force) {
            throw "The same version is already installed but its verified hash differs; use -Force to replace it."
        }

        if ($sameVersion -and $existingHash -ceq $downloadedHash) {
            $needsExecutableReplacement = $false
        }
    }

    $pathPlan = Get-PathPlan -InstallDirectory $normalizedInstallDirectory -StatePathAdded $(if ($stateExists) { [bool]$state.PathAdded } else { $false }) -ForAdd ([bool]$AddToPath) -ForRemove ([bool]$RemovePath)
    $newState = New-StateObject -VersionWithoutTag $resolvedVersion -AssetName $assetName -Sha256 $downloadedHash -PathAdded ([bool]$pathPlan.DesiredOwnership) -InstallDirectory $normalizedInstallDirectory

    if (-not $needsExecutableReplacement) {
        Assert-StagedExecutable -ExecutablePath $executableTempPath -ExpectedVersion $resolvedVersion
    }

    if (-not $needsExecutableReplacement -and -not $pathPlan.Changed -and $pathPlan.ProcessAction -eq 'None' -and ([bool]$pathPlan.DesiredOwnership -eq [bool]$state.PathAdded)) {
        Write-Output "gitler v$resolvedVersion is already installed at '$destinationPath'; verified hash matches, so no changes were made."
        $installationCommitted = $true
        return
    }

    if (-not $installDirectoryExists) {
        Assert-NoReparsePointsInPath -FullPath $normalizedInstallDirectory
        [void][IO.Directory]::CreateDirectory($normalizedInstallDirectory)
        $createdInstallDirectory = $true
        Assert-SafeInstallDirectory -Path $normalizedInstallDirectory
    }

    if ($needsExecutableReplacement) {
        $stagePath = New-UniqueFile -Directory $normalizedInstallDirectory -Prefix '.gitler-stage-' -Extension '.exe'
        [IO.File]::Copy($executableTempPath, $stagePath, $true)
        $stagedHash = (Get-FileHash -LiteralPath $stagePath -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
        if ($stagedHash -cne $downloadedHash) {
            throw "Staged executable hash changed before verification."
        }

        Assert-StagedExecutable -ExecutablePath $stagePath -ExpectedVersion $resolvedVersion
    }

    $executableTransaction = $null
    $stateTransaction = $null
    $userPathChanged = $false

    try {
        if ($needsExecutableReplacement) {
            $executableTransaction = Replace-ManagedExecutable -StagePath $stagePath -DestinationPath $destinationPath -PreviouslyExisted $stateExists
            $stagePath = $null
        }

        if ($pathPlan.Changed) {
            Set-UserPathValue -Value $pathPlan.NewValue
            $userPathChanged = $true
        }

        $stateTransaction = Write-StateFile -State $newState -StatePath $statePath -PreviouslyExisted $stateExists

        if ($pathPlan.ProcessAction -ne 'None') {
            try {
                Update-CurrentProcessPath -InstallDirectory $normalizedInstallDirectory -Action $pathPlan.ProcessAction
            }
            catch {
                Write-Warning "Installation succeeded, but the current process PATH could not be updated. Open a new terminal. Details: $($_.Exception.Message)"
            }
        }

        if ($pathPlan.Changed) {
            Broadcast-EnvironmentChange
        }

        if ($null -ne $stateTransaction.BackupPath) {
            Remove-KnownFileQuietly -Path $stateTransaction.BackupPath
            $stateTransaction.BackupPath = $null
        }
        if ($null -ne $executableTransaction -and $null -ne $executableTransaction.BackupPath) {
            Remove-KnownFileQuietly -Path $executableTransaction.BackupPath
            $executableTransaction.BackupPath = $null
        }

        $installationCommitted = $true
    }
    catch {
        $failure = $_.Exception.Message
        $rollbackErrors = New-Object 'System.Collections.Generic.List[string]'

        if ($null -ne $stateTransaction -and $stateTransaction.Committed) {
            try {
                Restore-StateFile -Transaction $stateTransaction
            }
            catch {
                [void]$rollbackErrors.Add("State rollback failed: $($_.Exception.Message)")
            }
        }

        if ($userPathChanged) {
            try {
                Set-UserPathValue -Value $pathPlan.CurrentValue
            }
            catch {
                [void]$rollbackErrors.Add("User PATH rollback failed: $($_.Exception.Message)")
            }
        }

        if ($null -ne $executableTransaction -and $executableTransaction.Committed) {
            try {
                Restore-ReplacedExecutable -Transaction $executableTransaction
            }
            catch {
                [void]$rollbackErrors.Add("Executable rollback failed: $($_.Exception.Message)")
            }
        }

        if ($rollbackErrors.Count -gt 0) {
            throw "Installation failed: $failure Rollback also failed: $([string]::Join('; ', $rollbackErrors.ToArray()))"
        }

        throw "Installation failed: $failure The previous installation was restored where possible."
    }

    if ($pathPlan.ProcessAction -eq 'Add') {
        Write-Output "Installed gitler v$resolvedVersion at '$destinationPath'."
        if ($pathPlan.DesiredOwnership) {
            if ($pathPlan.Changed) {
                Write-Output "Added '$normalizedInstallDirectory' to User PATH. Open a new terminal for other processes to observe the change."
            }
            else {
                Write-Output 'User PATH already contains the exact install directory.'
            }
        }
    }
    elseif ($pathPlan.ProcessAction -eq 'Remove') {
        Write-Output "Installed gitler v$resolvedVersion at '$destinationPath'."
        if ($pathPlan.Changed) {
            Write-Output "Removed the exact installer-owned directory from User PATH. Open a new terminal for other processes to observe the change."
        }
    }
    else {
        Write-Output "Installed gitler v$resolvedVersion at '$destinationPath'."
    }
}
finally {
    if ($null -ne $stagePath) {
        Remove-KnownFileQuietly -Path $stagePath
    }

    foreach ($tempFile in $tempFiles) {
        Remove-KnownFileQuietly -Path $tempFile
    }

    if ($createdInstallDirectory -and -not $installationCommitted -and [IO.Directory]::Exists($normalizedInstallDirectory)) {
        try {
            if (@([IO.Directory]::GetFileSystemEntries($normalizedInstallDirectory)).Count -eq 0) {
                [IO.Directory]::Delete($normalizedInstallDirectory)
            }
        }
        catch {
            Write-Warning "Could not remove incomplete install directory '$normalizedInstallDirectory': $($_.Exception.Message)"
        }
    }
}