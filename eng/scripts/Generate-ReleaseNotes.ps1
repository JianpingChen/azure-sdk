param (
  [string]$RepositoryName,
  [string]$BaseBranchName,
  [string]$PrBranchBase,
  [string]$AuthToken
)

$PATTERN_REGEX = "^\[pattern(\.(?<SectionName>\w+))?\]:\s#\s\((?<Pattern>.*)\)"

$releasePeriod = Get-Date -Format "yyyy-MM"
Write-Host "##vso[task.setvariable variable=thisReleasePeriod]$releasePeriod"

$workingDirectory = Get-Location
Write-Host "Working Directory $workingDirectory"

$repoPath = Join-Path $workingDirectory $RepositoryName
if (!(Test-Path $repoPath))
{
  Write-Error "Path [ $repoPath ] not found."
  exit 1
}
Write-Host "Repo Path $repoPath"

$commonScriptsPath = (Join-Path $repoPath eng common scripts)
$commonScript = (Join-Path $commonScriptsPath common.ps1)
Write-Host "Common Script $commonScript"

. $commonScript
$CsvMetaData = Get-CSVMetadata

$isSubsequentRun = $true

$FullBranchName = "${PrBranchBase}_${releasePeriod}"
Push-Location (Join-Path $workingDirectory azure-sdk)
git checkout $FullBranchName
if ($LASTEXITCODE -eq 1)
{
    git checkout -b $FullBranchName
    $isSubsequentRun = $false
}

$releaseFileName = "${Language}.md"
$releaseFilePath = (Join-Path $workingDirectory azure-sdk releases $releasePeriod $releaseFileName)

if (!(Test-Path $releaseFilePath)) 
{
    $releaseFileName = "${LanguageShort}.md"
    $releaseFilePath = (Join-Path $workingDirectory azure-sdk releases $releasePeriod $releaseFileName)
}
LogDebug "Release File Path [ $releaseFilePath ]"
$existingReleaseContent = Get-Content $releaseFilePath


$pathToDateOfLatestUpdates = (Join-Path $workingDirectory azure-sdk releases dateoflastupdate.txt)
$collectChangelogPath = (Join-Path $commonScriptsPath Collect-ChangeLogs.ps1)

function Get-PackagesInfoFromFile ($releaseNotesContent) 
{
    $checkLine = $False
    $presentPkgInfo = @()

    foreach ($line in $releaseNotesContent)
    {
        $line = $line.Trim()
        if ($line.StartsWith("<!--"))
        {
            $checkLine = $True
            continue
        }
        if ($line.EndsWith("-->"))
        {
            break
        }
        if ($checkLine)
        {
            $pkgInfo = $line.Split(":")
            $packageName = $pkgInfo[0]
            $packageMetaData = $CsvMetaData | Where-Object { $_.Package -eq $packageName }
            if ($packageMetaData.Count -gt 0)
            {
                $presentPkgInfo += $line
            }
        }
    }
    return $presentPkgInfo
}

function Filter-ReleaseHighlights ($releaseHighlights)
{
    $results = @{}

    foreach ($key in $releaseHighlights.Keys)
    {
        $keyInfo = $key.Split(":")
        $packageName = $keyInfo[0]
        $releaseVersion = $keyInfo[1]
        $packageGroupId = $releaseHighlights[$key]["PackageProperties"].Group

        $packageMetaData = $CsvMetaData | Where-Object { ($_.Package -eq $packageName) -and ($_.GroupId -eq $packageGroupId) }

        if ($packageMetaData.Hide -eq "true")
        {
            continue
        }

        $sortedVersions = [AzureEngSemanticVersion]::SortVersionStrings(@($releaseVersion, $packageMetaData.VersionGA, $packageMetaData.VersionPreview))

        if ($sortedVersions[0] -eq $releaseVersion)
        {
            continue
        }
        $releaseHighlights[$key]["DisplayName"] = $packageMetaData.DisplayName
        $results.Add($key, $releaseHighlights[$key])
    }
    return $results
}

function Write-GeneralReleaseNote ($releaseHighlights, $releaseNotesContent, $releaseFilePath)
{
    [System.Collections.ArrayList]$newReleaseContent = @()
    $insertPosition = $null
    $arrayToInsert = @()

    foreach ($line in $releaseNotesContent)
    {
        if ($line -match $PATTERN_REGEX)
        {
            $sectionName = $matches["SectionName"]
            $pattern = $matches["Pattern"]

            foreach ($key in $releaseHighlights.Keys)
            {
                $pkgInfo = $key.Split(":")
                $packageName = $pkgInfo[0]
                $packageVersion = $pkgInfo[1]
                $packageFriendlyName = $releaseHighlights[$key]["DisplayName"]

                if ($null -eq $packageFriendlyName)
                {
                    $packageFriendlyName = $packageName
                }

                $changelogUrl = $releaseHighlights[$key]["ChangelogUrl"]
                $changelogUrl = "(${changelogUrl})"
                $highlightsBody = ($releaseHighlights[$key]["Content"] | Out-String).Trim()
                $packageSemVer = [AzureEngSemanticVersion]::ParseVersionString($PackageVersion)
                
                $lineValue = $ExecutionContext.InvokeCommand.ExpandString($pattern)
                if ([System.String]::IsNullOrEmpty($sectionName) -or $packageSemVer.VersionType -eq $sectionName)
                {
                    if ($null -ne $insertPosition)
                    {
                        $arrayToInsert += $lineValue
                    }
                    else
                    {
                        if ($isSubsequentRun -and [System.String]::IsNullOrEmpty($newReleaseContent[$newReleaseContent.Count - 1]))
                        {
                            $newReleaseContent.Insert($newReleaseContent[$newReleaseContent.Count - 1], $lineValue)
                        }
                        else {
                            $newReleaseContent += $lineValue
                        }
                        
                    }
                }
            }

            if ($null -ne $insertPosition -and ($arrayToInsert.Count -gt 0))
            {
                if ($isSubsequentRun -and [System.String]::IsNullOrEmpty($newReleaseContent[$insertPosition - 1]))
                {
                    $newReleaseContent.Insert($insertPosition - 1, $arrayToInsert)
                }
                else 
                {
                    $newReleaseContent.Insert($insertPosition, $arrayToInsert)
                }
                $insertPosition = $null
                $arrayToInsert = $null
            }

            if (![System.String]::IsNullOrEmpty($newReleaseContent[$newReleaseContent.Count - 1]))
            {
                $newReleaseContent += ""
            }
        }

        if (($null -ne $insertPosition) -and (![System.String]::IsNullOrEmpty($line)))
        {
            $insertPosition = $null
        }

        if ($line -eq "``````")
        {
            $insertPosition = $newReleaseContent.Count - 1
        }

        $newReleaseContent += $line
    }
    Set-Content -Path $releaseFilePath -Value $newReleaseContent
}

$presentPkgsInfo = Get-PackagesInfoFromFile -releaseNotesContent $existingReleaseContent
$dateOfLatestUpdates = Get-Content -Path $pathToDateOfLatestUpdates -Raw

$incomingReleaseHighlights = &$collectChangelogPath -FromDate $dateOfLatestUpdates

foreach ($key in $incomingReleaseHighlights.Keys)
{
  $presentKey = $presentPkgsInfo | Where-Object { $_ -eq $key }
  if ($presentKey.Count -gt 0)
  {
    $incomingReleaseHighlights.Remove($key)
  }
}

$incomingReleaseHighlights = Filter-ReleaseHighlights -releaseHighlights $incomingReleaseHighlights

Write-GeneralReleaseNote `
-releaseHighlights $incomingReleaseHighlights `
-releaseNotesContent $existingReleaseContent `
-releaseFilePath $releaseFilePath

Set-Content -Path $pathToDateOfLatestUpdates -Value (Get-Date -Format "yyyy-MM-dd") -NoNewline





