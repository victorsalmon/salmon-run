"""
Invoke-FillT5Slip.py — Fill a CRA T5 Statement of Investment Income fillable PDF.

Fills all 3 slips (payer, recipient, CRA copies) on the CRA T5 fillable PDF
(t5-fill-25e.pdf) with identical dividend data.

Usage:
    python Invoke-FillT5Slip.py ^
        --year 2026 ^
        --payer "Intersite Consulting Inc." ^
        --recipient "Victor Salmon" ^
        --box24 1959.36 ^
        --box25 2155.30 ^
        --output "T5 - Victor Salmon - 2026.pdf"

All box values default to empty if not provided.
"""

import argparse, datetime, os, sys
import fitz

FIELD_SUFFIXES = {
    "Year":              "Slip1Year",
    "PayersName":        "Slip1PayersName",
    "RecipientNameAdd":  "Slip1RecipientNameAdd",
    "Box10":             "Slip1Box10",
    "Box11":             "Slip1Box11",
    "Box12":             "Slip1Box12",
    "Box13":             "Slip1Box13",
    "Box18":             "Slip1Box18",
    "Box21":             "Slip1Box21",
    "Box22":             "Slip1Box22",
    "Box23":             "Slip1Box23",
    "Box24":             "Slip1Box24",
    "Box25":             "Slip1Box25",
    "Box26":             "Slip1Box26",
    "Box27":             "Slip1Box27",
    "Box28":             "Slip1Box28",
    "Box29":             "Slip1Box29",
}

SLIPS = [1, 2, 3]

def fill_t5_slip(blank_path, output_path, field_map, slips=None):
    import fitz
    doc = fitz.open(blank_path)
    if slips is None:
        slips = SLIPS
    filled = 0

    for page_num in range(len(doc)):
        page = doc[page_num]
        for widget in page.widgets():
            name = widget.field_name
            slip_num = None
            for s in slips:
                if f"Slip{s}[0]" in name:
                    slip_num = s
                    break
            if slip_num is None:
                continue
            for field_suffix, value in field_map.items():
                if field_suffix in name:
                    widget.field_value = str(value)
                    widget.update()
                    filled += 1
                    break

    stamp = (
        f"Generated: {datetime.datetime.now().isoformat()}\n"
        f"Data source: {args.input_data if 'args' in dir() else 'unknown'}\n"
        f"Entity: {entity}\n"
        f"Fiscal year: {fy_start}-{fy_end}\n"
        f"Script: Invoke-FillT5Slip.py"
    )
    page = doc[0]
    rect = fitz.Rect(50, 700, 550, 750)
    page.insert_textbox(rect, stamp, fontsize=8, align=fitz.TEXT_ALIGN_LEFT)

    doc.save(output_path, garbage=4, deflate=True, pretty=True)
    doc.close()
    return filled

def format_amt(v):
    if v is None:
        return ""
    return f"{v:.2f}"

def build_field_map(args):
    m = {
        "Slip1Year": str(args.year) if args.year else "",
        "Slip1PayersName": args.payer,
        "Slip1RecipientNameAdd": args.recipient,
        "Slip1Box10": format_amt(args.box10),
        "Slip1Box11": format_amt(args.box11),
        "Slip1Box12": format_amt(args.box12),
        "Slip1Box13": format_amt(args.box13),
        "Slip1Box18": format_amt(args.box18),
        "Slip1Box21": format_amt(args.box21),
        "Slip1Box22": format_amt(args.box22),
        "Slip1Box23": format_amt(args.box23),
        "Slip1Box24": format_amt(args.box24),
        "Slip1Box25": format_amt(args.box25),
        "Slip1Box26": format_amt(args.box26),
        "Slip1Box27": args.box27,
        "Slip1Box28": args.box28,
        "Slip1Box29": args.box29,
    }
    return {k: v for k, v in m.items() if v != ""}

def parse_args():
    parser = argparse.ArgumentParser(
        description="Fill a CRA T5 fillable PDF with dividend data"
    )
    parser.add_argument("--blank", default=None,
                        help="Path to blank T5 fillable PDF (default: auto-resolve)")
    parser.add_argument("--year", type=int, default=2026)
    parser.add_argument("--payer", default="")
    parser.add_argument("--recipient", default="")
    parser.add_argument("--box10", type=float, default=None)
    parser.add_argument("--box11", type=float, default=None)
    parser.add_argument("--box12", type=float, default=None)
    parser.add_argument("--box13", type=float, default=None)
    parser.add_argument("--box18", type=float, default=None)
    parser.add_argument("--box21", type=float, default=None)
    parser.add_argument("--box22", type=float, default=None)
    parser.add_argument("--box23", type=float, default=None)
    parser.add_argument("--box24", type=float, default=None)
    parser.add_argument("--box25", type=float, default=None)
    parser.add_argument("--box26", type=float, default=None)
    parser.add_argument("--box27", default="")
    parser.add_argument("--box28", default="")
    parser.add_argument("--box29", default="")
    parser.add_argument("--output", required=True)
    return parser.parse_args()

def main():
    args = parse_args()

    blank = args.blank
    if not blank:
        script_dir = os.path.dirname(os.path.abspath(__file__))
        blank = os.path.join(script_dir, "..", "assets", "t5-fill-25e.pdf")
    if not os.path.exists(blank):
        print(f"ERROR: blank T5 PDF not found at {blank}", file=sys.stderr)
        sys.exit(1)

    field_map = build_field_map(args)
    filled = fill_t5_slip(blank, args.output, field_map, slips=SLIPS)
    print(f"Filled {filled} fields across {len(SLIPS)} slips")
    print(f"Output: {args.output}")
    print(f"Size: {os.path.getsize(args.output)} bytes")

if __name__ == "__main__":
    main()
