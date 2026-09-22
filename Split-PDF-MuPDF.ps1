<#
.SYNOPSIS
List PDF bookmarks or split a PDF into per-section PDFs using PyMuPDF.

.DESCRIPTION
Wrapper script that invokes the Python back-end (pdf_splitter.py) which uses
PyMuPDF (fitz). The Python interpreter is taken exclusively from a dedicated
virtual environment; the script never falls back to a native Python on PATH.

Three actions are supported:
  List  - return bookmark PSCustomObjects with level, page, title, and the
          full SectionName path. Use -Level to filter the returned objects.
  Split - split the PDF into one PDF per bookmark at the requested level.
          Use -Section to export one bookmark and all of its subsections as a
          single PDF.

List output is intended for the PowerShell pipeline. The SectionName property
can be passed directly to -Section. A leaf title may be used when unique; use
the full SectionName path with '>' when duplicate titles exist.

.EXAMPLE
.\Split-PDF-MuPDF.ps1 -PdfPath "input\MyBook.pdf" -Action List -Level 3

Returns only level-3 bookmark objects. Each object includes Level, Page, Title,
and SectionName properties.

.EXAMPLE
$bookmarks = .\Split-PDF-MuPDF.ps1 -PdfPath "input\MyBook.pdf" -Action List -Level 3
$section = $bookmarks |
    Where-Object { $_.Title -eq 'Unique section title' } |
    Select-Object -First 1 -ExpandProperty SectionName
.\Split-PDF-MuPDF.ps1 -PdfPath "input\MyBook.pdf" -Action Split -Section $section

Lists level-3 bookmarks, obtains the full SectionName path, and exports the
selected bookmark with all of its subsections.

.OUTPUTS
System.Management.Automation.PSCustomObject

When Action is List, each output object contains Level, Page, Title, and
SectionName properties. Split and Tree return no bookmark-list objects.

.EXAMPLE
.\Split-PDF-MuPDF.ps1 `
    -PdfPath "input\sql-sql-server-ver17.pdf" `
    -Action Split `
    -Section "SQL Server on Linux > High availability and disaster recovery > Availability groups"

Exports one path-qualified section when the leaf title is duplicated. The
selected bookmark's descendant bookmarks and pages are retained in the output.

.PARAMETER PdfPath
Path to the input .pdf file.

.PARAMETER Action
Operation to perform: List (default), Split, or Tree. List returns structured
bookmark objects; Split writes PDFs; Tree writes own-content-only PDFs.

.PARAMETER Level
Bookmark level to split at when Action is Split, or filter to when Action is
List. Split defaults to level 1; List displays all levels unless specified.

.PARAMETER Section
Bookmark title or full SectionName path to export as one PDF with all of its
subsections. Titles are matched case-insensitively after normalizing spacing,
punctuation, and hyphens. A leaf title must be unique; duplicate titles must
use the full path with '>'. Valid only with Action Split.

.PARAMETER OutputDir
Directory for output PDF files. Defaults to .\output.

.PARAMETER PythonEnv
Path to the PyMuPDF virtual environment. Defaults to .\.venv\pymupdf.

.CONTEXT
ePubSplitter utility project

.AUTHOR
Greg Tate

.NOTES
Program: Split-PDF-MuPDF.ps1
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -Path $_ -PathType Leaf })]
    [string]$PdfPath,

    [ValidateSet('List', 'Split', 'Tree')]
    [string]$Action = 'List',

    [int]$Level = 1,

    [string]$Section,

    [string]$OutputDir = (Join-Path -Path $PSScriptRoot -ChildPath 'output'),

    [string]$PythonEnv = (Join-Path -Path $PSScriptRoot -ChildPath '.venv/pymupdf')
)

#region CONFIGURATION
$PythonScript = Join-Path -Path $PSScriptRoot -ChildPath 'src/pdf_splitter.py'
$OutputDirWasSpecified = $PSBoundParameters.ContainsKey('OutputDir')
$LevelWasSpecified = $PSBoundParameters.ContainsKey('Level')
#endregion

$Main = {
    . $Helpers

    # Resolve the full path of the input PDF file
    $resolvedPdf = (Resolve-Path -Path $PdfPath).Path

    # Restrict section selection to the combined Split action.
    if (-not [string]::IsNullOrWhiteSpace($Section) -and $Action -ne 'Split') {
        Write-Error "The -Section parameter is valid only with -Action Split."
        exit 1
    }

    # Verify the venv Python, the back-end script, and PyMuPDF are available
    Confirm-Prerequisite

    # Warn when list mode is used with an explicit output directory
    if ($Action -eq 'List' -and $OutputDirWasSpecified) {
        Write-Warning (
            "Action 'List' only displays bookmarks and does not create PDF files. " +
            "The provided OutputDir '$OutputDir' is ignored. " +
            "Use -Action Split or -Action Tree to write files."
        )
    }

    # Invoke the Python back-end for the requested action
    $result = Invoke-PdfSplitter `
        -PdfFile $resolvedPdf `
        -Output $OutputDir `
        -SelectedSection $Section `
        -IncludeLevel $LevelWasSpecified

    # Display results appropriate to the action
    if ($Action -eq 'List') {
        Show-BookmarkList -Result $result
    }
    else {
        Show-SplitSummary -Result $result
    }
}

$Helpers = {

    #region PREREQUISITE CHECK
    function Confirm-Prerequisite {
        # Verify the back-end script, the venv Python, and PyMuPDF availability.

        # Check that the Python script exists alongside this wrapper
        if (-not (Test-Path -Path $PythonScript -PathType Leaf)) {
            Write-Error "Python back-end not found at: $PythonScript"
            exit 1
        }

        # Resolve the interpreter strictly from the PyMuPDF virtual environment
        $Script:PythonExe = Resolve-PythonExe

        # Confirm PyMuPDF is importable inside that virtual environment
        Confirm-PyMuPdf -PythonExe $Script:PythonExe

        Write-Verbose "Using Python: $Script:PythonExe"
    }

    function Resolve-PythonExe {
        # Return the venv python.exe path or fail; never fall back to PATH.

        # Validate the virtual environment directory exists
        if (-not (Test-Path -Path $PythonEnv -PathType Container)) {
            Write-Error (
                "PyMuPDF virtual environment not found at: $PythonEnv`n" +
                "Create it and install PyMuPDF into it, for example:`n" +
                "  python -m venv `"$PythonEnv`"`n" +
                "  & `"$PythonEnv\Scripts\Activate.ps1`"; pip install pymupdf"
            )
            exit 1
        }

        # Build the expected interpreter path within the virtual environment
        $venvPython = Join-Path -Path $PythonEnv -ChildPath 'Scripts/python.exe'

        if (-not (Test-Path -Path $venvPython -PathType Leaf)) {
            Write-Error "Python interpreter not found in venv: $venvPython"
            exit 1
        }

        return (Resolve-Path -Path $venvPython).Path
    }

    function Confirm-PyMuPdf {
        # Ensure the PyMuPDF package is importable in the virtual environment.
        param(
            [string]$PythonExe
        )

        # Probe the interpreter for the fitz module (PyMuPDF)
        & $PythonExe -c 'import fitz' 2>&1 | Out-Null

        if ($LASTEXITCODE -ne 0) {
            Write-Error (
                "PyMuPDF is not installed in the virtual environment: $PythonEnv`n" +
                "Install it into the venv (do not use native Python):`n" +
                "  & `"$PythonEnv\Scripts\Activate.ps1`"; pip install pymupdf"
            )
            exit 1
        }
    }
    #endregion

    #region PYTHON INVOCATION
    function Invoke-PdfSplitter {
        # Run the Python back-end and return the parsed JSON result.
        param(
            [string]$PdfFile,
            [string]$Output,
            [string]$SelectedSection,
            [bool]$IncludeLevel
        )

        Write-Host "Action:     $Action" -ForegroundColor Cyan
        Write-Host "PDF:        $PdfFile" -ForegroundColor Cyan

        if ($Action -eq 'Split') {
            Write-Host "Level:      $Level" -ForegroundColor Cyan
            if (-not [string]::IsNullOrWhiteSpace($SelectedSection)) {
                Write-Host "Section:    $SelectedSection" -ForegroundColor Cyan
            }
            Write-Host "Output to:  $Output" -ForegroundColor Cyan
        }
        elseif ($Action -eq 'Tree') {
            Write-Host "Output to:  $Output" -ForegroundColor Cyan
        }

        # Execute the Python script and capture stdout and stderr
        # Build the backend argument list while preserving the existing defaults.
        $arguments = @(
            $PythonScript,
            $PdfFile,
            '--action', $Action.ToLower()
        )

        if ($Action -ne 'List' -or $IncludeLevel) {
            $arguments += @('--level', [string]$Level)
        }

        $arguments += @('-o', $Output)

        if (-not [string]::IsNullOrWhiteSpace($SelectedSection)) {
            $arguments += @('--section', $SelectedSection)
        }

        $raw = & $Script:PythonExe @arguments 2>&1

        # Separate stderr warnings from stdout JSON
        $stderr = $raw | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] }
        $stdout = $raw | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }

        # Log any Python warnings at verbose level
        foreach ($line in $stderr) {
            Write-Verbose "Python: $line"
        }

        # Join stdout lines and parse the JSON summary
        $jsonText = ($stdout -join "`n").Trim()

        if (-not $jsonText) {
            Write-Error 'Python back-end returned no output.'
            exit 1
        }

        return ($jsonText | ConvertFrom-Json)
    }
    #endregion

    #region DISPLAY
    function Show-BookmarkList {
        # Return every bookmark returned by the back-end as structured objects.
        param(
            [PSObject]$Result
        )

        Write-Host ''
        Write-Host '--- PDF Bookmarks ---' -ForegroundColor Green
        Write-Host "PDF Title:       $($Result.pdf_title)"
        Write-Host "Bookmark Count:  $($Result.bookmark_count)"

        if ($null -eq $Result.level_filter) {
            Write-Host 'Level Filter:    All'
        }
        else {
            Write-Host "Level Filter:    $($Result.level_filter)"
        }

        Write-Host ''

        # Return the bookmark records as structured pipeline objects.
        if ($Result.bookmark_count -gt 0) {
            # Materialize the display rows so callers can pipe them to PowerShell commands.
            $bookmarkRows = @($Result.bookmarks |
                ForEach-Object {
                    [PSCustomObject]@{
                        Level       = $_.level
                        Page        = $_.page
                        Title       = $_.title
                        SectionName = $_.section_name
                    }
                })

            $bookmarkRows
        }
        else {
            Write-Host 'No bookmarks were found in this PDF.' -ForegroundColor Yellow
        }
    }

    function Show-SplitSummary {
        # Display a formatted summary of the split operation.
        param(
            [PSObject]$Result
        )

        Write-Host ''
        Write-Host '--- PDF Split Complete ---' -ForegroundColor Green
        Write-Host "PDF Title:        $($Result.pdf_title)"

        # Show the split level only for single-level splits
        if ($Action -eq 'Split') {
            Write-Host "Split Level:      $($Result.level)"

            if ($Result.section_path) {
                Write-Host "Selected Section: $($Result.section_path)"
                Write-Host "Source Pages:     $($Result.start_page)-$($Result.end_page)"
            }
        }

        Write-Host "Sections Written: $($Result.sections_written)"
        Write-Host "Output Directory: $($Result.output_directory)"

        # Show a per-level breakdown when running Tree mode
        if ($Action -eq 'Tree' -and $Result.per_level) {
            Write-Host ''
            Write-Host 'Sections per level:' -ForegroundColor Cyan

            foreach ($property in $Result.per_level.PSObject.Properties | Sort-Object Name) {
                Write-Host "  Level $($property.Name): $($property.Value)"
            }
        }

        Write-Host ''

        # Warn and fail when no sections were produced
        if ($Result.sections_written -eq 0) {
            if ($Action -eq 'Tree') {
                Write-Warning 'No navigable bookmarks with exclusive pages were found. Nothing was written.'
            }
            else {
                if ($Result.section_path) {
                    Write-Warning "The selected section did not produce a navigable page range. Nothing was written."
                }
                else {
                    Write-Warning "No bookmarks at level $Level were found. Nothing was written."
                }
            }
            exit 1
        }

        # List the generated files
        if (Test-Path -Path $Result.output_directory) {
            Get-ChildItem -Path $Result.output_directory -Filter '*.pdf' |
                Sort-Object Name |
                ForEach-Object { Write-Host "  $_" }
        }
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
