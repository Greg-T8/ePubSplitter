<#
.SYNOPSIS
Split an ePub file into per-chapter text files.

.DESCRIPTION
Wrapper script that invokes the Python back-end (epub_splitter.py)
to extract chapters from an ePub file and write each chapter as a
separate .txt file in the output directory.

.PARAMETER EpubPath
Path to the input .epub file.

.PARAMETER OutputDir
Directory for output text files. Defaults to .\output.

.CONTEXT
ePubSplitter utility project

.AUTHOR
Greg Tate

.NOTES
Program: Split-Epub.ps1
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$EpubPath,

    [string]$OutputDir = (Join-Path -Path $PSScriptRoot -ChildPath 'output')
)

#region CONFIGURATION
$PythonScript = Join-Path -Path $PSScriptRoot -ChildPath 'epub_splitter.py'
#endregion

# Orchestration block
$Main = {
    . $Helpers

    # Resolve the full path of the input ePub file
    $resolvedEpub = Resolve-Path -Path $EpubPath

    # Verify the Python back-end script exists
    Confirm-Prerequisite

    # Invoke the Python back-end to split the ePub into chapter files
    $result = Invoke-PythonSplitter -EpubFile $resolvedEpub -Output $OutputDir

    # Display a summary of the operation
    Show-Summary -Result $result
}

# Helper functions
$Helpers = {

    #region PREREQUISITE CHECK
    function Confirm-Prerequisite {
        <#
        .SYNOPSIS
        Verify that the Python back-end script and interpreter are available.
        #>

        # Check that the Python script exists alongside this wrapper
        if (-not (Test-Path -Path $PythonScript -PathType Leaf)) {
            Write-Error "Python back-end not found at: $PythonScript"
            exit 1
        }

        # Check that a Python interpreter is reachable
        $venvPython = Join-Path -Path $PSScriptRoot -ChildPath '.venv/Scripts/python.exe'

        if (Test-Path -Path $venvPython -PathType Leaf) {
            $Script:PythonExe = $venvPython
        }
        else {
            $Script:PythonExe = (Get-Command python -ErrorAction SilentlyContinue).Source
        }

        if (-not $Script:PythonExe) {
            Write-Error 'Python interpreter not found. Install Python 3.10+ and ensure it is on PATH.'
            exit 1
        }

        Write-Verbose "Using Python: $Script:PythonExe"
    }
    #endregion

    #region PYTHON INVOCATION
    function Invoke-PythonSplitter {
        <#
        .SYNOPSIS
        Run the Python back-end and return the parsed JSON result.
        #>
        param(
            [string]$EpubFile,
            [string]$Output
        )

        # Build the argument list for the Python script
        $arguments = @(
            $PythonScript,
            "`"$EpubFile`"",
            '-o',
            "`"$Output`""
        )

        Write-Host "Splitting: $EpubFile" -ForegroundColor Cyan
        Write-Host "Output to: $Output" -ForegroundColor Cyan

        # Execute the Python script and capture stdout
        $raw = & $Script:PythonExe $PythonScript $EpubFile '-o' $Output 2>&1

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
    function Show-Summary {
        <#
        .SYNOPSIS
        Display a formatted summary of the split operation.
        #>
        param(
            [PSObject]$Result
        )

        Write-Host ''
        Write-Host '--- ePub Split Complete ---' -ForegroundColor Green
        Write-Host "Book Title:       $($Result.book_title)"
        Write-Host "Chapters Written: $($Result.chapters_written)"
        Write-Host "Output Directory: $($Result.output_directory)"
        Write-Host ''

        # List the generated files
        if (Test-Path -Path $Result.output_directory) {
            Get-ChildItem -Path $Result.output_directory -Filter '*.txt' |
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
