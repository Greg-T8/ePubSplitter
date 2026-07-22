# ePubSplitter

A small utility that splits an ePub file into individual per-chapter plain-text files.  
The Python back-end (`src/epub_splitter.py`) does the heavy lifting; the PowerShell wrapper (`Split-Epub.ps1`) provides a convenient command-line interface.

---

## How It Works

1. The ePub spine and TOC are read to determine reading order and chapter titles.
2. Boilerplate pages (cover, copyright, TOC, ads, etc.) are automatically skipped.
3. Each substantive chapter is written to a numbered `.txt` file in the output folder.
4. A JSON summary (book title, chapter count, output path) is printed on completion.

---

## Requirements

| Requirement | Version |
|---|---|
| Python | 3.10 or later |
| ebooklib | latest |
| beautifulsoup4 | latest |
| cpdf | latest |
| PyMuPDF | latest (in its own venv) |

### Install dependencies

```powershell
python -m venv .venv
.venv\Scripts\Activate.ps1
pip install ebooklib beautifulsoup4
```

---

## Usage

### PowerShell (recommended)

```powershell
.\Split-Epub.ps1 -EpubPath "input\MyBook.epub"
```

```powershell
.\Split-PDF.ps1 -PdfPath "input\MyBook.pdf"
```

Output files are written to `.\output\` by default.

```powershell
.\Split-Epub.ps1 -EpubPath "input\MyBook.epub" -OutputDir "C:\Books\MyBook"
```

For PDF splitting, if `-OutputDir` is omitted, chapter files are written to a folder
named after the source PDF beside the source file. When a part is detected,
filenames use `Part-01_Chapter-01_<chapter title>.pdf`.

```powershell
.\Split-PDF.ps1 -PdfPath "input\MyBook.pdf" -OutputDir "C:\Books\MyBook"
```

Use `-Verbose` to see Python interpreter details and any warnings:

```powershell
.\Split-Epub.ps1 -EpubPath "input\MyBook.epub" -Verbose
```

### PyMuPDF-based PDF splitting

`Split-PDF-MuPDF.ps1` is a separate wrapper around the PyMuPDF back-end
(`src/pdf_splitter.py`). It runs **only** from a dedicated virtual environment
(default `~\Python_Env\pymupdf`) and never falls back to a native Python on PATH.

Create the virtual environment and install PyMuPDF **into it** (not into the
native Python):

```powershell
python -m venv "$HOME\Python_Env\pymupdf"
& "$HOME\Python_Env\pymupdf\Scripts\Activate.ps1"
pip install pymupdf
```

List every bookmark with its level and page (default action):

```powershell
.\Split-PDF-MuPDF.ps1 -PdfPath "input\MyBook.pdf"
```

Split the PDF into one PDF per bookmark at a chosen level:

```powershell
.\Split-PDF-MuPDF.ps1 -PdfPath "input\MyBook.pdf" -Action Split -Level 1
```

For deeper split levels, output file names include parent bookmark context so
sections remain identifiable, for example:

```text
01_Networking__Configure internet connectivity__Enable Managed SNAT for Azure VMware Solution workloads.pdf
```

Split every level at once with `Tree`. Each output holds only the pages a
heading directly owns — from its start page up to just before the next
bookmark of any level — so a section contains none of its parent or child
content. Files are written to one folder with a single global index so sorted
names stay in document order:

```powershell
.\Split-PDF-MuPDF.ps1 -PdfPath "input\MyBook.pdf" -Action Tree
```

```text
001_Networking.pdf
002_Networking__Configure internet connectivity.pdf
003_Networking__Configure internet connectivity__Enable Managed SNAT for Azure VMware Solution workloads.pdf
```

Override the output directory or the virtual environment location:

```powershell
.\Split-PDF-MuPDF.ps1 -PdfPath "input\MyBook.pdf" -Action Split -Level 1 -OutputDir "C:\Books\MyBook"
.\Split-PDF-MuPDF.ps1 -PdfPath "input\MyBook.pdf" -PythonEnv "D:\envs\pymupdf"
```

### Python (direct)

```bash
python src/epub_splitter.py "input/MyBook.epub"
python src/epub_splitter.py "input/MyBook.epub" -o "path/to/output"
python src/pdf_splitter.py "input/MyBook.pdf" --action list
python src/pdf_splitter.py "input/MyBook.pdf" --action split --level 1 -o "path/to/output"
python src/pdf_splitter.py "input/MyBook.pdf" --action tree -o "path/to/output"
```

---

## Output

Each chapter is written as a zero-padded, numbered plain-text file:

```
output/
    01_Prologue.txt
    02_Chapter One.txt
    03_Chapter Two.txt
    ...
```

---

## Project Structure

```
ePubSplitter/
├── src/
│   ├── epub_splitter.py   # Python back-end — ePub parsing and text extraction
│   └── pdf_splitter.py    # Python back-end — PyMuPDF bookmark listing/splitting
├── Split-Epub.ps1        # PowerShell wrapper — ePub CLI interface and summary
├── Split-PDF.ps1         # PowerShell wrapper — cpdf-based PDF splitter
├── Split-PDF-MuPDF.ps1   # PowerShell wrapper — PyMuPDF-based PDF splitter
├── input/                # Place source files here (git-ignored)
├── output/               # Generated files land here (git-ignored)
└── .venv/                # Python virtual environment (git-ignored)
```

---

## Author

Greg Tate
