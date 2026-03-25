# -------------------------------------------------------------------------
# Program: epub_splitter.py
# Description: Extract chapters from an ePub file and write each as a
#              separate text file. Used as the back-end engine for the
#              PowerShell wrapper Split-Epub.ps1.
# Context: ePubSplitter utility project
# Author: Greg Tate
# -------------------------------------------------------------------------

#region IMPORTS
import argparse
import json
import re
from pathlib import Path
from xml.etree import ElementTree

import ebooklib
from bs4 import BeautifulSoup, NavigableString
from ebooklib import epub
#endregion

# Minimum character count for a section to be considered real content
MIN_CONTENT_LENGTH = 200


#region MAIN WORKFLOW
def main() -> None:
    """Parse CLI args, extract chapters, write output files."""
    args = parse_args()

    # Load the ePub
    book = epub.read_epub(args.epub, {"ignore_ncx": False})

    # Resolve the display title once so we can use it for output folder naming
    book_title = get_book_title(book)

    # Build the TOC-based chapter map (href -> title) from NCX/nav
    toc_map = build_toc_map(book)

    # Build an ordered list of content documents from the spine
    spine_items = get_spine_items(book)

    # Extract chapter titles and text from each spine item
    chapters = extract_chapters(spine_items, toc_map)

    # Write each chapter into a title-based subfolder under the output root
    output_root = Path(args.output)
    output_dir = output_root / sanitize_filename(book_title)
    output_dir.mkdir(parents=True, exist_ok=True)
    written = write_chapters(chapters, output_dir)

    # Return JSON summary to the calling process
    summary = {
        "book_title": book_title,
        "chapters_written": written,
        "output_directory": str(output_dir.resolve()),
    }
    print(json.dumps(summary, indent=2))
#endregion


#region HELPER FUNCTIONS
def parse_args() -> argparse.Namespace:
    """Parse command-line arguments."""
    parser = argparse.ArgumentParser(
        description="Split an ePub file into per-chapter text files.",
    )
    parser.add_argument(
        "epub",
        help="Path to the input .epub file.",
    )
    parser.add_argument(
        "-o", "--output",
        default="output",
        help="Directory for output text files (default: ./output).",
    )
    return parser.parse_args()


def get_book_title(book: epub.EpubBook) -> str:
    """Return the book title from metadata."""
    title = book.get_metadata("DC", "title")
    if title:
        return title[0][0]
    return "Unknown"


def build_toc_map(book: epub.EpubBook) -> dict[str, str]:
    """
    Build a mapping of href -> title from the TOC (nav or NCX).

    Strips fragment identifiers so we can match on filename alone.
    """
    toc_map: dict[str, str] = {}

    def walk_toc(items: list | tuple) -> None:
        for item in items:
            if isinstance(item, tuple):
                # (section, children) pair
                section, children = item
                if hasattr(section, "href"):
                    href = section.href.split("#")[0]
                    toc_map[href] = section.title
                walk_toc(children)
            elif hasattr(item, "href"):
                href = item.href.split("#")[0]
                toc_map[href] = item.title

    walk_toc(book.toc)
    return toc_map


def get_spine_items(book: epub.EpubBook) -> list:
    """Return spine documents in reading order."""
    items = []

    # Walk the spine (list of id, linear pairs)
    for item_id, _ in book.spine:
        item = book.get_item_with_id(item_id)
        if item and item.get_type() == ebooklib.ITEM_DOCUMENT:
            items.append(item)

    return items


def is_boilerplate(item, soup: BeautifulSoup) -> bool:
    """
    Return True if a spine document is front/back matter boilerplate
    rather than real chapter content.
    """
    filename = Path(item.get_name()).name.lower()

    # Skip known non-content filenames
    skip_patterns = [
        "cover", "toc", "nav", "copyright",
        "title", "halftitle", "dedication",
        "discover", "ad-card", "adcard",
    ]
    for pattern in skip_patterns:
        if pattern in filename:
            return True

    # Check epub:type attributes for non-body content
    body = soup.find("body")
    if body:
        epub_type = body.get("epub:type", "")
        boilerplate_types = {
            "cover", "toc", "copyright-page",
            "titlepage", "dedication", "colophon",
        }
        for bt in boilerplate_types:
            if bt in epub_type:
                return True

    # Check section epub:type as well
    sections = soup.find_all("section")
    for section in sections:
        epub_type = section.get("epub:type", "")
        if "bodymatter" in epub_type or "chapter" in epub_type:
            return False

    return False


def extract_chapters(
    spine_items: list,
    toc_map: dict[str, str],
) -> list[dict]:
    """
    Walk every spine document and extract chapter content.

    Strategy:
    1.  Skip boilerplate documents (covers, TOC, copyright, ads).
    2.  Use the TOC map to get proper chapter titles.
    3.  For documents with multiple heading tags, split into sections.
    4.  For single-chapter documents, extract as one chapter.
    5.  Only keep sections with substantial text content.
    """
    chapters: list[dict] = []

    for item in spine_items:
        html = item.get_content().decode("utf-8", errors="replace")
        soup = BeautifulSoup(html, "html.parser")
        href = Path(item.get_name()).name

        # Skip boilerplate pages
        if is_boilerplate(item, soup):
            continue

        # Try heading-based split for multi-chapter documents
        headings = soup.find_all(re.compile(r"^h[1-3]$", re.I))

        if len(headings) > 1:
            # Multiple headings — split into sections
            sections = split_on_headings(soup, headings)
            for title, text in sections:
                text = clean_text(text)
                if len(text) >= MIN_CONTENT_LENGTH:
                    chapters.append({"title": title, "text": text})
        else:
            # Single or no heading — extract the whole document
            title = toc_map.get(href, "")

            # Fall back to first heading or <title> tag
            if not title and headings:
                title = headings[0].get_text(strip=True)
            if not title:
                title_tag = soup.find("title")
                if title_tag:
                    title = title_tag.get_text(strip=True)
            if not title:
                title = Path(item.get_name()).stem

            text = clean_text(extract_body_text(soup))
            if len(text) >= MIN_CONTENT_LENGTH:
                chapters.append({"title": title, "text": text})

    return chapters


def extract_body_text(soup: BeautifulSoup) -> str:
    """Extract visible text from the body, preserving paragraph breaks."""
    body = soup.find("body")
    if not body:
        return soup.get_text("\n")

    parts: list[str] = []

    # Walk block-level elements to preserve paragraph structure
    for element in body.descendants:
        if isinstance(element, NavigableString):
            text = element.strip()
            if text:
                parts.append(text)
        elif element.name in (
            "p", "div", "br", "hr",
            "h1", "h2", "h3", "h4", "h5", "h6",
            "blockquote", "li",
        ):
            parts.append("\n")

    return "\n".join(parts)


def split_on_headings(
    soup: BeautifulSoup,
    headings: list,
) -> list[tuple[str, str]]:
    """
    Split a document into sections based on heading elements.

    Each heading starts a new section that continues until the next
    heading of equal or higher rank, or EOF.
    """
    sections: list[tuple[str, str]] = []

    for i, heading in enumerate(headings):
        title = heading.get_text(strip=True)

        # Collect all text nodes until the next heading
        parts: list[str] = []
        node = heading.next_element
        stop_nodes = set(headings[i + 1:])

        while node is not None:
            if node in stop_nodes:
                break

            if isinstance(node, NavigableString):
                text = node.strip()
                if text:
                    parts.append(text)

            node = node.next_element

        sections.append((title, "\n".join(parts)))

    return sections


def clean_text(text: str) -> str:
    """Normalise whitespace and strip empty lines."""
    lines = []
    for line in text.splitlines():
        line = line.strip()
        if line:
            lines.append(line)

    result = "\n\n".join(lines)
    return result


def sanitize_filename(name: str) -> str:
    """Remove characters that are invalid in file paths."""
    name = re.sub(r'[<>:"/\\|?*]', "", name)
    name = name.strip(". ")
    return name[:80] if name else "untitled"


def write_chapters(
    chapters: list[dict],
    output_dir: Path,
) -> int:
    """Write each chapter dict to a numbered text file. Return count."""
    written = 0

    for idx, chapter in enumerate(chapters, start=1):
        safe_title = sanitize_filename(chapter["title"])
        filename = f"{idx:02d}_{safe_title}.txt"
        filepath = output_dir / filename
        filepath.write_text(
            chapter["text"],
            encoding="utf-8",
        )
        written += 1

    return written
#endregion


#region ENTRY POINT
if __name__ == "__main__":
    main()
#endregion
