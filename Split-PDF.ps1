<#
.SYNOPSIS
Split a PDF file into per-chapter PDF files using cpdf bookmarks.

.DESCRIPTION
Parses PDF bookmarks from cpdf.exe and writes each chapter to its own PDF.
When a part is detected from level-0 Roman numeral bookmarks, output files use
Part-XX_Chapter-YY_Title.pdf naming.

.PARAMETER PdfPath
Path to the input PDF file.

.PARAMETER OutputDir
Directory for output PDF files. If omitted, a folder named after the source PDF
is created beside the source PDF.

.PARAMETER CpdfPath
Optional explicit path to cpdf.exe. If omitted, cpdf.exe is resolved from PATH.

.CONTEXT
ePubSplitter utility project

.AUTHOR
Greg Tate

.NOTES
Program: Split-PDF.ps1
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -Path $_ -PathType Leaf })]
    [string]$PdfPath,

    [string]$OutputDir,

    [string]$CpdfPath
)

#region CONFIGURATION
# Match cpdf bookmark lines with optional trailing state/destination data.
$BookmarkPattern = '^(?<Level>\d+) "(?<Title>.*)" (?<Page>\d+)(?:\s+open)?(?:\s+"|$)'
$PartPattern = '(?i)^(?:part\s+)?(?<Roman>X|IX|VIII|VII|VI|V|IV|III|II|I)\b'
$ChapterPattern = '(?i)^(?:chapter\s+)?(?<Chapter>\d+)(?!\.\d)(?:[:.\s-]+(?<ChapterTitle>.+))?$'
$PartNumberMap = @{
    I    = 1
    II   = 2
    III  = 3
    IV   = 4
    V    = 5
    VI   = 6
    VII  = 7
    VIII = 8
    IX   = 9
    X    = 10
}
$StructuralSkipPattern = @(
    '(?i)^cover(?:\s+page)?$'
    '(?i)^(?:table\s+of\s+contents|contents)$'
    '(?i)^preface$'
    '(?i)^copyright(?:\s+page)?$'
    '(?i)^acknowledg(?:e)?ments?$'
    '(?i)^notes?$'
    '(?i)^selected\s+reading$'
    '(?i)^index$'
    '(?i)^appendix(?:es)?(?:[:\s].*)?$'
    '(?i)^other\s+books(?:\s+you\s+may\s+enjoy)?$'
    '(?i)^share\s+your\s+thoughts$'
    '(?i)^blank\s+page$'
)
#endregion

$Main = {
    . $Helpers

    # Resolve input/output paths and cpdf prerequisites.
    $resolvedPdf = (Resolve-Path -Path $PdfPath).Path
    $resolvedCpdf = Confirm-Prerequisite -PdfFile $resolvedPdf -CpdfOverride $CpdfPath
    $targetOutputDir = New-OutputDirectory -ResolvedPdfPath $resolvedPdf -OutputPath $OutputDir

    # Collect bookmark boundaries and chapter page ranges.
    $pageCount = Get-PdfPageCount -PdfFile $resolvedPdf -CpdfExe $resolvedCpdf
    $boundaryList = Get-BookmarkBoundary -PdfFile $resolvedPdf -CpdfExe $resolvedCpdf
    $chapterBoundary = Get-ChapterBoundary -BoundaryList $boundaryList -TotalPages $pageCount

    # Split the source PDF into chapter PDFs.
    $result = Invoke-PdfSplit -CpdfExe $resolvedCpdf -PdfFile $resolvedPdf -OutputFolder $targetOutputDir -ChapterBoundary $chapterBoundary

    # Display a summary and fail if no chapter files were written.
    Show-SplitSummary -Result $result

    if ($result.Written -eq 0) {
        exit 1
    }
}

$Helpers = {
    #region PREREQUISITE CHECK
    function Confirm-Prerequisite {
        # Resolve and validate cpdf.exe before running any split operations.
        param(
            [string]$PdfFile,
            [string]$CpdfOverride
        )

        if (-not (Test-Path -Path $PdfFile -PathType Leaf)) {
            throw "Input PDF not found: $PdfFile"
        }

        if (-not [string]::IsNullOrWhiteSpace($CpdfOverride)) {
            if (-not (Test-Path -Path $CpdfOverride -PathType Leaf)) {
                throw "cpdf executable not found at: $CpdfOverride"
            }

            $cpdfResolved = (Resolve-Path -Path $CpdfOverride).Path
            Write-Verbose "Using cpdf executable: $cpdfResolved"
            return $cpdfResolved
        }

        $cpdfCommand = Get-Command -Name 'cpdf.exe' -ErrorAction SilentlyContinue

        if (-not $cpdfCommand) {
            $cpdfCommand = Get-Command -Name 'cpdf' -ErrorAction SilentlyContinue
        }

        if (-not $cpdfCommand) {
            throw 'cpdf.exe was not found on PATH. Install cpdf or pass -CpdfPath.'
        }

        Write-Verbose "Using cpdf executable: $($cpdfCommand.Source)"
        return $cpdfCommand.Source
    }
    #endregion

    #region OUTPUT DIRECTORY
    function New-OutputDirectory {
        # Create and return the destination directory for split chapter PDFs.
        param(
            [string]$ResolvedPdfPath,
            [string]$OutputPath
        )

        if ([string]::IsNullOrWhiteSpace($OutputPath)) {
            $pdfParent = Split-Path -Path $ResolvedPdfPath -Parent
            $pdfBaseName = [System.IO.Path]::GetFileNameWithoutExtension($ResolvedPdfPath)
            $OutputPath = Join-Path -Path $pdfParent -ChildPath $pdfBaseName
        }

        $createdDirectory = New-Item -Path $OutputPath -ItemType Directory -Force
        $resolvedDirectory = (Resolve-Path -Path $createdDirectory.FullName).Path

        Write-Verbose "Output directory: $resolvedDirectory"
        return $resolvedDirectory
    }
    #endregion

    #region METADATA
    function Get-PdfPageCount {
        # Read total page count from cpdf so the last chapter can end on the final page.
        param(
            [string]$PdfFile,
            [string]$CpdfExe
        )

        $raw = & $CpdfExe -pages $PdfFile 2>&1

        if ($LASTEXITCODE -ne 0) {
            $errorText = ($raw | Out-String).Trim()
            throw "Failed to read PDF page count. cpdf output: $errorText"
        }

        foreach ($line in $raw) {
            if (($line -as [string]) -match '(?<Pages>\d+)') {
                return [int]$Matches.Pages
            }
        }

        throw 'Unable to parse PDF page count from cpdf output.'
    }

    function Get-BookmarkBoundary {
        # Parse cpdf bookmark output into ordered boundary objects.
        param(
            [string]$PdfFile,
            [string]$CpdfExe
        )

        $raw = & $CpdfExe -list-bookmarks -utf8 $PdfFile 2>&1

        if ($LASTEXITCODE -ne 0) {
            $errorText = ($raw | Out-String).Trim()
            throw "Failed to list PDF bookmarks. cpdf output: $errorText"
        }

        $boundaries = @()
        $currentPartNumber = $null

        foreach ($line in $raw) {
            if (($line -as [string]) -notmatch $BookmarkPattern) {
                continue
            }

            $level = [int]$Matches.Level
            $title = Get-NormalizedBookmarkTitle -Title $Matches.Title
            $page = [int]$Matches.Page

            if ($level -eq 0) {
                if ($title -match $PartPattern) {
                    $roman = $Matches.Roman.ToUpperInvariant()

                    if ($PartNumberMap.ContainsKey($roman)) {
                        $currentPartNumber = $PartNumberMap[$roman]
                    }
                    else {
                        $currentPartNumber = $null
                    }
                }
                else {
                    $currentPartNumber = $null
                }
            }

            $boundaries += [PSCustomObject]@{
                Level      = $level
                Title      = $title
                Page       = $page
                PartNumber = $currentPartNumber
            }
        }

        if ($boundaries.Count -eq 0) {
            throw 'No bookmark boundaries were parsed from cpdf output.'
        }

        return ,$boundaries
    }

    function Get-ChapterBoundary {
        # Build chapter start/end ranges from numbered bookmarks, then fall back to level-0 bookmarks.
        param(
            [object[]]$BoundaryList,
            [int]$TotalPages
        )

        $chapterLevel = Select-ChapterBookmarkLevel -BoundaryList $BoundaryList
        $chapters = @()

        if ($null -ne $chapterLevel) {
            for ($i = 0; $i -lt $BoundaryList.Count; $i++) {
                $boundary = $BoundaryList[$i]

                if ($boundary.Level -ne $chapterLevel) {
                    continue
                }

                if ($boundary.Title -notmatch $ChapterPattern) {
                    Write-Verbose "Skipping non-numbered chapter bookmark: $($boundary.Title)"
                    continue
                }

                $chapterNumber = [int]$Matches.Chapter
                $chapterTitle = ''

                if ($Matches.ChapterTitle) {
                    $chapterTitle = $Matches.ChapterTitle.Trim()
                }

                if ([string]::IsNullOrWhiteSpace($chapterTitle)) {
                    $chapterTitle = Get-ChildBookmarkTitle -BoundaryList $BoundaryList -Index $i
                }

                $nextPrimaryBoundary = Get-NextPrimaryBoundary -BoundaryList $BoundaryList -Index $i -PrimaryLevel $chapterLevel

                if ($null -ne $nextPrimaryBoundary) {
                    $endPage = [int]$nextPrimaryBoundary.Page - 1
                }
                else {
                    $endPage = $TotalPages
                }

                if ($endPage -lt [int]$boundary.Page) {
                    Write-Warning "Skipping invalid page range for chapter '$chapterTitle' starting at page $($boundary.Page)."
                    continue
                }

                $chapters += [PSCustomObject]@{
                    PartNumber    = $boundary.PartNumber
                    ChapterNumber = $chapterNumber
                    ChapterTitle  = $chapterTitle
                    StartPage     = [int]$boundary.Page
                    EndPage       = $endPage
                }
            }
        }

        if ($chapters.Count -gt 0) {
            return ,$chapters
        }

        Write-Verbose 'No numbered chapter bookmarks detected. Falling back to level-0 structural bookmarks.'
        $chapters = Get-StructuralChapterBoundary -BoundaryList $BoundaryList -TotalPages $TotalPages

        if ($chapters.Count -eq 0) {
            throw 'No chapter-like bookmarks were detected in the PDF bookmarks.'
        }

        return ,$chapters
    }

    function Select-ChapterBookmarkLevel {
        # Choose the bookmark level that most likely represents chapter boundaries.
        param(
            [object[]]$BoundaryList
        )

        $candidateBoundaries = $BoundaryList |
            Where-Object { $_.Title -match $ChapterPattern }

        if ($candidateBoundaries.Count -eq 0) {
            return $null
        }

        $primaryCandidates = $candidateBoundaries |
            Where-Object { $_.Level -le 1 }

        if ($primaryCandidates.Count -gt 0) {
            $candidateBoundaries = $primaryCandidates
        }

        $bestLevel = $candidateBoundaries |
            Group-Object -Property Level |
            Sort-Object -Property @{ Expression = 'Count'; Descending = $true }, @{ Expression = 'Name'; Descending = $false } |
            Select-Object -First 1

        return [int]$bestLevel.Name
    }

    function Get-NormalizedBookmarkTitle {
        # Normalize bookmark titles for reliable matching.
        param(
            [string]$Title
        )

        if ($null -eq $Title) {
            return ''
        }

        $normalizedTitle = $Title -replace '\s+', ' '
        return $normalizedTitle.Trim()
    }

    function Test-IsSkippedStructuralTitle {
        # Identify front/back matter bookmark titles that should be ignored in fallback mode.
        param(
            [string]$Title
        )

        if ([string]::IsNullOrWhiteSpace($Title)) {
            return $true
        }

        foreach ($pattern in $StructuralSkipPattern) {
            if ($Title -match $pattern) {
                return $true
            }
        }

        return $false
    }

    function Get-StructuralChapterBoundary {
        # Build chapter ranges from level-0 bookmarks when numbered chapter bookmarks are unavailable.
        param(
            [object[]]$BoundaryList,
            [int]$TotalPages
        )

        $levelZeroBoundaries = @()

        foreach ($boundary in $BoundaryList | Where-Object { $_.Level -eq 0 }) {
            if (Test-IsSkippedStructuralTitle -Title $boundary.Title) {
                Write-Verbose "Skipping structural front/back matter bookmark: $($boundary.Title)"
                continue
            }

            $levelZeroBoundaries += $boundary
        }

        if ($levelZeroBoundaries.Count -eq 0) {
            return @()
        }

        $chapters = @()
        $chapterNumber = 1

        for ($i = 0; $i -lt $levelZeroBoundaries.Count; $i++) {
            $boundary = $levelZeroBoundaries[$i]

            if ($i -lt ($levelZeroBoundaries.Count - 1)) {
                $endPage = [int]$levelZeroBoundaries[$i + 1].Page - 1
            }
            else {
                $endPage = $TotalPages
            }

            if ($endPage -lt [int]$boundary.Page) {
                Write-Warning "Skipping invalid structural range for '$($boundary.Title)' starting at page $($boundary.Page)."
                continue
            }

            $chapters += [PSCustomObject]@{
                PartNumber    = $null
                ChapterNumber = $chapterNumber
                ChapterTitle  = $boundary.Title
                StartPage     = [int]$boundary.Page
                EndPage       = $endPage
            }

            $chapterNumber += 1
        }

        return ,$chapters
    }

    function Get-ChildBookmarkTitle {
        # Find the first direct child bookmark title for chapters without inline titles.
        param(
            [object[]]$BoundaryList,
            [int]$Index
        )

        $parentLevel = [int]$BoundaryList[$Index].Level

        for ($childIndex = ($Index + 1); $childIndex -lt $BoundaryList.Count; $childIndex++) {
            $candidate = $BoundaryList[$childIndex]

            if ([int]$candidate.Level -le $parentLevel) {
                break
            }

            if ([int]$candidate.Level -eq ($parentLevel + 1) -and -not [string]::IsNullOrWhiteSpace($candidate.Title)) {
                return $candidate.Title.Trim()
            }
        }

        return ''
    }

    function Get-NextPrimaryBoundary {
        # Find the next primary boundary while ignoring deeper section-level bookmarks.
        param(
            [object[]]$BoundaryList,
            [int]$Index,
            [int]$PrimaryLevel
        )

        for ($boundaryIndex = ($Index + 1); $boundaryIndex -lt $BoundaryList.Count; $boundaryIndex++) {
            $candidate = $BoundaryList[$boundaryIndex]

            if ([int]$candidate.Level -le $PrimaryLevel) {
                return $candidate
            }
        }

        return $null
    }
    #endregion

    #region SPLIT OPERATION
    function Get-SafeFileName {
        # Convert chapter titles into safe Windows filename segments.
        param(
            [string]$Name
        )

        $safe = $Name -replace '[<>:"/\\|?*]', ''
        $safe = $safe -replace '\s+', ' '
        $safe = $safe.Trim()
        $safe = $safe.TrimEnd('.', ' ')

        if ([string]::IsNullOrWhiteSpace($safe)) {
            return 'untitled'
        }

        if ($safe.Length -gt 80) {
            return $safe.Substring(0, 80).TrimEnd()
        }

        return $safe
    }

    function Invoke-PdfSplit {
        # Split the source PDF into per-chapter PDFs based on parsed boundaries.
        param(
            [string]$CpdfExe,
            [string]$PdfFile,
            [string]$OutputFolder,
            [object[]]$ChapterBoundary
        )

        $written = 0
        $failed = 0
        $skipped = 0
        $failures = @()

        foreach ($chapter in $ChapterBoundary) {
            $safeTitle = Get-SafeFileName -Name $chapter.ChapterTitle
            $hasTitle = -not [string]::IsNullOrWhiteSpace($chapter.ChapterTitle)

            if ($null -ne $chapter.PartNumber) {
                if ($hasTitle) {
                    $fileName = 'Part-{0:D2}_Chapter-{1:D2}_{2}.pdf' -f $chapter.PartNumber, $chapter.ChapterNumber, $safeTitle
                }
                else {
                    $fileName = 'Part-{0:D2}_Chapter-{1:D2}.pdf' -f $chapter.PartNumber, $chapter.ChapterNumber
                }
            }
            else {
                if ($hasTitle) {
                    $fileName = 'Chapter-{0:D2}_{1}.pdf' -f $chapter.ChapterNumber, $safeTitle
                }
                else {
                    $fileName = 'Chapter-{0:D2}.pdf' -f $chapter.ChapterNumber
                }
            }

            $destination = Join-Path -Path $OutputFolder -ChildPath $fileName
            $range = '{0}-{1}' -f $chapter.StartPage, $chapter.EndPage

            Write-Host "Writing $fileName (pages $range)" -ForegroundColor Cyan

            $raw = & $CpdfExe $PdfFile $range -utf8 -o $destination 2>&1

            if ($LASTEXITCODE -ne 0) {
                $failed += 1
                $failures += [PSCustomObject]@{
                    FileName = $fileName
                    Message  = (($raw | Out-String).Trim())
                }
                Write-Warning "Failed to write $fileName"
                continue
            }

            if (-not (Test-Path -Path $destination -PathType Leaf)) {
                $skipped += 1
                Write-Warning "cpdf did not produce expected output file: $destination"
                continue
            }

            $written += 1
        }

        return [PSCustomObject]@{
            Written         = $written
            Failed          = $failed
            Skipped         = $skipped
            OutputDirectory = $OutputFolder
            Failures        = $failures
        }
    }
    #endregion

    #region DISPLAY
    function Show-SplitSummary {
        # Display a concise summary of chapter split results.
        param(
            [PSObject]$Result
        )

        Write-Host ''
        Write-Host '--- PDF Split Complete ---' -ForegroundColor Green
        Write-Host "Chapters Written: $($Result.Written)"
        Write-Host "Failed Writes:    $($Result.Failed)"
        Write-Host "Skipped Writes:   $($Result.Skipped)"
        Write-Host "Output Directory: $($Result.OutputDirectory)"

        if ($Result.Failures.Count -gt 0) {
            Write-Host ''
            Write-Host 'Failures:' -ForegroundColor Yellow

            foreach ($failure in $Result.Failures) {
                Write-Host "- $($failure.FileName): $($failure.Message)"
            }
        }

        Write-Host ''
    }
    #endregion
}

try {
    Push-Location -Path $PSScriptRoot
    & $Main
}
finally {
    Pop-Location
}
