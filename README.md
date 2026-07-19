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

### Python (direct)

```bash
python src/epub_splitter.py "input/MyBook.epub"
python src/epub_splitter.py "input/MyBook.epub" -o "path/to/output"
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
│   └── epub_splitter.py   # Python back-end — ePub parsing and text extraction
├── Split-Epub.ps1     # PowerShell wrapper — CLI interface and output summary
├── input/             # Place .epub files here (git-ignored)
├── output/            # Generated .txt files land here (git-ignored)
└── .venv/             # Python virtual environment (git-ignored)
```

---

## Author

Greg Tate
