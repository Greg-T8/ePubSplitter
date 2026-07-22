# -------------------------------------------------------------------------
# Program: pdf_splitter.py
# Description: List PDF bookmarks or split a PDF into per-section PDF files
#              at a chosen bookmark level. Used as the back-end engine for
#              the PowerShell wrapper Split-PDF-MuPDF.ps1.
# Context: ePubSplitter utility project
# Author: Greg Tate
# -------------------------------------------------------------------------

#region IMPORTS
import argparse
import json
import re
from pathlib import Path

import fitz
#endregion


#region MAIN WORKFLOW
def main() -> None:
    """Parse CLI args, then list bookmarks or split the PDF."""
    args = parse_args()

    # Open the source PDF and resolve a display title for output naming
    doc = fitz.open(args.pdf)
    pdf_title = get_pdf_title(doc, args.pdf)

    # Read the table of contents as [level, title, page] entries
    toc = doc.get_toc()

    # Dispatch on the requested action
    if args.action == "list":
        summary = list_bookmarks(pdf_title, toc)
    elif args.action == "tree":
        summary = split_tree(doc, pdf_title, toc, args)
    else:
        summary = split_pdf(doc, pdf_title, toc, args)

    # Return JSON summary to the calling process
    print(json.dumps(summary, indent=2))
#endregion


#region HELPER FUNCTIONS
def parse_args() -> argparse.Namespace:
    """Parse command-line arguments."""
    parser = argparse.ArgumentParser(
        description=(
            "List PDF bookmarks or split a PDF into per-section "
            "PDF files at a chosen bookmark level."
        ),
    )
    parser.add_argument(
        "pdf",
        help="Path to the input .pdf file.",
    )
    parser.add_argument(
        "-a", "--action",
        choices=["list", "split", "tree"],
        default="list",
        help="Operation to perform (default: list).",
    )
    parser.add_argument(
        "-l", "--level",
        type=int,
        default=1,
        help="Bookmark level to split at (default: 1).",
    )
    parser.add_argument(
        "-o", "--output",
        default="output",
        help="Directory for output PDF files (default: ./output).",
    )
    return parser.parse_args()


def get_pdf_title(doc: fitz.Document, pdf_path: str) -> str:
    """Resolve a display title from metadata, falling back to file name."""
    metadata_title = ""

    # Prefer the embedded document title when present
    if doc.metadata:
        metadata_title = (doc.metadata.get("title") or "").strip()

    if metadata_title:
        return metadata_title

    # Fall back to the source file name without its extension
    return Path(pdf_path).stem


def list_bookmarks(pdf_title: str, toc: list) -> dict:
    """Build a JSON-serializable summary of every bookmark in the PDF."""
    bookmarks = []

    # Flatten each TOC entry into a simple level/title/page record
    for entry in toc:
        level, title, page = entry[0], entry[1], entry[2]
        bookmarks.append(
            {
                "level": int(level),
                "title": str(title).strip(),
                "page": int(page),
            }
        )

    return {
        "pdf_title": pdf_title,
        "bookmark_count": len(bookmarks),
        "bookmarks": bookmarks,
    }


def split_pdf(
    doc: fitz.Document,
    pdf_title: str,
    toc: list,
    args: argparse.Namespace,
) -> dict:
    """Split the PDF at the requested bookmark level into section PDFs."""
    # Resolve TOC metadata once so page ranges and output navigation stay aligned.
    toc_records = build_toc_records(toc)

    # Compute the page ranges for every bookmark at the requested level
    sections = build_section_ranges(
        toc_records=toc_records,
        split_level=args.level,
        total_pages=doc.page_count,
    )

    if not sections:
        return {
            "pdf_title": pdf_title,
            "level": args.level,
            "sections_written": 0,
            "output_directory": "",
        }

    # Write each section into a title-based subfolder under the output root
    output_root = Path(args.output)
    output_dir = output_root / sanitize_filename(pdf_title)
    output_dir.mkdir(parents=True, exist_ok=True)
    written = write_sections(doc, sections, output_dir)

    return {
        "pdf_title": pdf_title,
        "level": args.level,
        "sections_written": written,
        "output_directory": str(output_dir.resolve()),
    }


def split_tree(
    doc: fitz.Document,
    pdf_title: str,
    toc: list,
    args: argparse.Namespace,
) -> dict:
    """Split the PDF at every level using own-content-only page ranges."""
    # Resolve TOC metadata once so ranges and naming stay aligned.
    toc_records = build_toc_records(toc)

    # Compute own-content ranges for every navigable heading across all levels
    sections = build_own_content_ranges(
        toc_records=toc_records,
        total_pages=doc.page_count,
    )

    if not sections:
        return {
            "pdf_title": pdf_title,
            "mode": "tree",
            "sections_written": 0,
            "per_level": {},
            "output_directory": "",
        }

    # Write each section into a title-based subfolder under the output root
    output_root = Path(args.output)
    output_dir = output_root / sanitize_filename(pdf_title)
    output_dir.mkdir(parents=True, exist_ok=True)
    written, per_level = write_tree_sections(doc, sections, output_dir)

    return {
        "pdf_title": pdf_title,
        "mode": "tree",
        "sections_written": written,
        "per_level": per_level,
        "output_directory": str(output_dir.resolve()),
    }


def build_own_content_ranges(
    toc_records: list[dict],
    total_pages: int,
) -> list[dict]:
    """Return per-heading ranges holding only pages a heading directly owns."""
    # Keep only headings that resolve to a navigable start page.
    navigable = [
        record
        for record in toc_records
        if record["resolved_page"] is not None
    ]

    sections = []

    for position, record in enumerate(navigable):
        # Own content starts at this heading's resolved page (1-based).
        start_page_1b = max(record["resolved_page"], 1)

        # Own content ends just before the next heading in reading order.
        if position < len(navigable) - 1:
            end_page_1b = navigable[position + 1]["resolved_page"] - 1
        else:
            end_page_1b = total_pages

        # Skip headings that own no exclusive pages (shared start page).
        if end_page_1b < start_page_1b:
            continue

        # Reuse parent-aware naming scoped to this heading's own level.
        name_parts = build_section_name_parts(
            mark=record,
            split_level=record["level"],
        )

        sections.append(
            {
                "title": record["title"],
                "level": record["level"],
                "name_parts": name_parts,
                "start_page": start_page_1b - 1,
                "end_page": end_page_1b - 1,
                "bookmarks": [[1, record["title"] or "untitled", 1]],
            }
        )

    return sections


def build_section_ranges(
    toc_records: list[dict],
    split_level: int,
    total_pages: int,
) -> list[dict]:
    """Return ordered section ranges for bookmarks matching the level."""
    # Keep only target-level bookmarks that resolve to navigable start pages.
    navigable_marks = [
        record
        for record in toc_records
        if record["level"] == split_level and record["resolved_page"] is not None
    ]

    sections = []

    for idx, mark in enumerate(navigable_marks):
        # Bookmark pages are 1-based until final conversion for insert_pdf.
        start_page_1b = max(mark["resolved_page"], 1)

        # End just before the next same-level bookmark, or at the last page
        if idx < len(navigable_marks) - 1:
            end_page_1b = navigable_marks[idx + 1]["resolved_page"] - 1
        else:
            end_page_1b = total_pages

        # Skip ranges that resolve to no pages (e.g. duplicate start pages)
        if end_page_1b < start_page_1b:
            continue

        # Build section-local bookmarks so each output PDF retains navigation.
        subtree_end = find_subtree_end_index(
            toc_records=toc_records,
            start_index=mark["index"],
            split_level=split_level,
        )

        section_bookmarks = build_section_bookmarks(
            toc_records=toc_records,
            start_index=mark["index"],
            end_index=subtree_end,
            split_level=split_level,
            start_page_1b=start_page_1b,
            end_page_1b=end_page_1b,
            section_title=mark["title"],
        )

        sections.append(
            {
                "title": mark["title"],
                "name_parts": build_section_name_parts(
                    mark=mark,
                    split_level=split_level,
                ),
                "start_page": start_page_1b - 1,
                "end_page": end_page_1b - 1,
                "bookmarks": section_bookmarks,
            }
        )

    return sections


def build_toc_records(toc: list) -> list[dict]:
    """Normalize TOC entries and resolve a navigable page for each row."""
    records = []
    ancestor_stack = []

    for index, entry in enumerate(toc):
        level = int(entry[0])
        title = str(entry[1]).strip() or "untitled"

        # Pop siblings and descendants so the stack only holds true parents.
        while ancestor_stack and ancestor_stack[-1]["level"] >= level:
            ancestor_stack.pop()

        # Capture ordered parent titles for later filename construction.
        ancestor_titles = [item["title"] for item in ancestor_stack]

        records.append(
            {
                "index": index,
                "level": level,
                "title": title,
                "ancestor_titles": ancestor_titles,
                "resolved_page": resolve_start_page(
                    toc=toc,
                    index=index,
                ),
            }
        )

        ancestor_stack.append(
            {
                "level": level,
                "title": title,
            }
        )

    return records


def find_subtree_end_index(
    toc_records: list[dict],
    start_index: int,
    split_level: int,
) -> int:
    """Return the end index (exclusive) for a split-level bookmark subtree."""
    for idx in range(start_index + 1, len(toc_records)):
        if toc_records[idx]["level"] <= split_level:
            return idx

    return len(toc_records)


def build_section_bookmarks(
    toc_records: list[dict],
    start_index: int,
    end_index: int,
    split_level: int,
    start_page_1b: int,
    end_page_1b: int,
    section_title: str,
) -> list[list]:
    """Build section-local TOC entries with levels/pages rebased to the split."""
    bookmarks = []

    for record in toc_records[start_index:end_index]:
        page = record["resolved_page"]

        if page is None:
            continue

        if page < start_page_1b or page > end_page_1b:
            continue

        title = record["title"] or "untitled"
        local_level = record["level"] - split_level + 1
        local_page = page - start_page_1b + 1

        bookmarks.append(
            [
                max(local_level, 1),
                title,
                max(local_page, 1),
            ]
        )

    if not bookmarks:
        return [[1, section_title or "untitled", 1]]

    return normalize_bookmark_levels(bookmarks)


def normalize_bookmark_levels(bookmarks: list[list]) -> list[list]:
    """Clamp TOC nesting jumps so set_toc receives a valid hierarchy."""
    normalized = []
    previous_level = 1

    for index, entry in enumerate(bookmarks):
        level = max(int(entry[0]), 1)
        title = str(entry[1]).strip() or "untitled"
        page = max(int(entry[2]), 1)

        if index == 0:
            level = 1
        elif level > previous_level + 1:
            level = previous_level + 1

        normalized.append([level, title, page])
        previous_level = level

    return normalized


def resolve_start_page(
    toc: list,
    index: int,
) -> int | None:
    """Resolve the first navigable page for a TOC entry."""
    # Use the bookmark page directly when it is navigable.
    page = int(toc[index][2])

    if page >= 1:
        return page

    # If the page is non-navigable (-1), use the first child with a page.
    current_level = int(toc[index][0])

    for child in toc[index + 1 :]:
        child_level = int(child[0])

        if child_level <= current_level:
            break

        child_page = int(child[2])

        if child_page >= 1:
            return child_page

    return None


def build_section_name_parts(
    mark: dict,
    split_level: int,
) -> list[str]:
    """Return parent-aware name parts with the current title as the leaf."""
    leaf_title = mark.get("title") or "untitled"

    if split_level <= 1:
        return [leaf_title]

    parents = mark.get("ancestor_titles") or []

    if not parents:
        return [leaf_title]

    return [*parents, leaf_title]


def build_section_filename(
    section: dict,
    section_index: int,
    used_stems: set[str],
    max_stem_length: int = 120,
    index_width: int = 2,
) -> str:
    """Build a deterministic, collision-safe file name for a split section."""
    raw_parts = section.get("name_parts") or [section.get("title", "untitled")]
    safe_parts = []

    # Sanitize every path segment and drop any empty results.
    for part in raw_parts:
        cleaned_part = sanitize_filename(str(part))

        if cleaned_part:
            safe_parts.append(cleaned_part)

    if not safe_parts:
        safe_parts = ["untitled"]

    # Trim oldest parents first so the leaf title remains readable.
    trimmed_parts = trim_name_parts(
        parts=safe_parts,
        max_stem_length=max_stem_length,
    )
    stem = "__".join(trimmed_parts)

    # Add a numeric suffix when stems collide after sanitization/truncation.
    unique_stem = make_unique_stem(
        stem=stem,
        used_stems=used_stems,
        max_stem_length=max_stem_length,
    )

    return f"{section_index:0{index_width}d}_{unique_stem}.pdf"


def trim_name_parts(
    parts: list[str],
    max_stem_length: int,
) -> list[str]:
    """Trim filename parts by removing oldest parents before shortening leaf."""
    working_parts = list(parts)

    # Remove older context until the combined stem fits or only the leaf remains.
    while len("__".join(working_parts)) > max_stem_length and len(working_parts) > 1:
        working_parts.pop(0)

    stem = "__".join(working_parts)

    if len(stem) <= max_stem_length:
        return working_parts

    # If only one part remains, cut it directly to the configured max length.
    if len(working_parts) == 1:
        return [working_parts[0][:max_stem_length] or "untitled"]

    prefix = "__".join(working_parts[:-1])
    available_for_leaf = max_stem_length - len(prefix) - 2

    if available_for_leaf <= 0:
        return [working_parts[-1][:max_stem_length] or "untitled"]

    working_parts[-1] = working_parts[-1][:available_for_leaf] or "untitled"
    return working_parts


def make_unique_stem(
    stem: str,
    used_stems: set[str],
    max_stem_length: int,
) -> str:
    """Return a unique stem by appending __N when a duplicate is detected."""
    candidate = stem or "untitled"
    candidate_key = candidate.lower()

    if candidate_key not in used_stems:
        used_stems.add(candidate_key)
        return candidate

    suffix_number = 2

    while True:
        suffix = f"__{suffix_number}"
        available = max_stem_length - len(suffix)
        base = candidate[:available].rstrip("_")

        if base:
            deduped = f"{base}{suffix}"
        else:
            deduped = f"untitled{suffix}"

        deduped_key = deduped.lower()

        if deduped_key not in used_stems:
            used_stems.add(deduped_key)
            return deduped

        suffix_number += 1


def write_tree_sections(
    doc: fitz.Document,
    sections: list[dict],
    output_dir: Path,
) -> tuple[int, dict[str, int]]:
    """Write own-content sections with global numbering. Return counts."""
    written = 0
    global_counter = 0
    used_stems: set[str] = set()
    index_width = max(2, len(str(len(sections))))
    per_level: dict[str, int] = {}

    for section in sections:
        level = int(section["level"])

        # Use one global counter so sorted names stay in document order.
        global_counter += 1

        # Compose a globally ordered, parent-aware, collision-safe file name.
        filename = build_section_filename(
            section=section,
            section_index=global_counter,
            used_stems=used_stems,
            index_width=index_width,
        )
        filepath = output_dir / filename

        # Copy the section's page range into a fresh single-section document
        section_doc = fitz.open()
        section_doc.insert_pdf(
            doc,
            from_page=section["start_page"],
            to_page=section["end_page"],
        )

        # Rebuild bookmark navigation in the split PDF.
        section_doc.set_toc(section["bookmarks"])

        section_doc.save(str(filepath))
        section_doc.close()
        written += 1
        per_level[str(level)] = per_level.get(str(level), 0) + 1

    return written, per_level


def write_sections(
    doc: fitz.Document,
    sections: list[dict],
    output_dir: Path,
) -> int:
    """Write each section range to a numbered PDF file. Return count."""
    written = 0
    used_stems = set()

    for idx, section in enumerate(sections, start=1):
        # Build a parent-aware, deterministic file name for this section.
        filename = build_section_filename(
            section=section,
            section_index=idx,
            used_stems=used_stems,
        )
        filepath = output_dir / filename

        # Copy the section's page range into a fresh single-section document
        section_doc = fitz.open()
        section_doc.insert_pdf(
            doc,
            from_page=section["start_page"],
            to_page=section["end_page"],
        )

        # Rebuild bookmark navigation in the split PDF.
        section_doc.set_toc(section["bookmarks"])

        section_doc.save(str(filepath))
        section_doc.close()
        written += 1

    return written


def sanitize_filename(name: str) -> str:
    """Remove characters that are invalid in file paths."""
    name = re.sub(r'[<>:"/\\|?*]', "", name)
    name = name.strip(". ")
    return name[:80] if name else "untitled"
#endregion


#region ENTRY POINT
if __name__ == "__main__":
    main()
#endregion
