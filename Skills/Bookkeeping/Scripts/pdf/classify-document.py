#!/usr/bin/env python3
"""Classify a PDF document as statement, receipt, invoice, or unknown."""

import json
import os
import re
import sys
from pathlib import Path

try:
    import pdfplumber
except ImportError:
    pdfplumber = None


def load_rubric(path=None):
    if path is None:
        path = Path(__file__).resolve().parents[2] / "classify-rubric.json"
    with open(path) as f:
        return json.load(f)


def extract_features(pdf_path):
    features = {
        "page_count": 0,
        "text": "",
        "tables": [],
        "page_dimensions": [],
        "first_page_header": "",
    }
    if pdfplumber is None:
        features["error"] = "pdfplumber not installed"
        return features

    with pdfplumber.open(pdf_path) as pdf:
        features["page_count"] = len(pdf.pages)
        for i, page in enumerate(pdf.pages):
            text = page.extract_text() or ""
            features["text"] += text + "\n"
            dims = page.width, page.height
            features["page_dimensions"].append(dims)

            tables = page.extract_tables()
            for t in tables:
                if t:
                    header = [str(c).strip() if c else "" for c in t[0]]
                    features["tables"].append({
                        "page": i,
                        "rows": len(t),
                        "cols": len(t[0]) if t[0] else 0,
                        "header": header,
                    })

            if i == 0:
                features["first_page_header"] = text[:500]

    return features


def match_signals(text, signals):
    score = 0.0
    matched = []
    for signal in signals:
        if re.search(signal["pattern"], text, re.IGNORECASE | re.MULTILINE):
            score += signal["weight"]
            matched.append(signal["pattern"])
    return score, matched


def match_vendor_hints(text, vendor_hints):
    results = {}
    for vendor, hint in vendor_hints.items():
        if re.search(hint["pattern"], text, re.IGNORECASE | re.MULTILINE):
            results[vendor] = hint
    return results


def classify(features, rubric):
    text = features["text"]
    max_possible = sum(s["weight"] for c in rubric["classifiers"] for s in c["signals"])
    if max_possible == 0:
        return {"type": "unknown", "confidence": 0.0, "detected_vendor": None, "features": features}

    results = []
    for classifier in rubric["classifiers"]:
        score, matched = match_signals(text, classifier["signals"])
        vendors = match_vendor_hints(text, classifier.get("vendor_hints", {}))
        if vendors:
            for v, h in vendors.items():
                score += h.get("weight_boost", 0)
                max_possible += h.get("weight_boost", 0)

        confidence = round(score / max_possible, 4) if max_possible > 0 else 0
        detected_vendor = list(vendors.keys())[0] if vendors else None

        results.append({
            "type": classifier["type"],
            "score": score,
            "confidence": min(confidence, 1.0),
            "matched_signals": len(matched),
            "detected_vendor": detected_vendor,
        })

    # Pick best match
    results.sort(key=lambda r: r["confidence"], reverse=True)
    best = results[0]

    fallback = rubric.get("fallback", {})
    if best["confidence"] < fallback.get("min_confidence", 0.3):
        return {
            "type": fallback.get("type", "unknown"),
            "confidence": best["confidence"],
            "detected_vendor": best["detected_vendor"],
            "features": {
                "page_count": features["page_count"],
                "table_count": len(features["tables"]),
                "has_vendor": best["detected_vendor"] is not None,
            },
        }

    return {
        "type": best["type"],
        "confidence": best["confidence"],
        "detected_vendor": best["detected_vendor"],
        "features": {
            "page_count": features["page_count"],
            "table_count": len(features["tables"]),
            "matched_signals": best["matched_signals"],
            "has_vendor": best["detected_vendor"] is not None,
        },
    }


def main():
    if len(sys.argv) < 2:
        print(json.dumps({"error": "Usage: classify-document.py <pdf_path> [--rubric <path>]"}))
        sys.exit(1)

    pdf_path = sys.argv[1]
    rubric_path = None
    if "--rubric" in sys.argv:
        idx = sys.argv.index("--rubric")
        rubric_path = sys.argv[idx + 1]

    if not os.path.isfile(pdf_path):
        print(json.dumps({"error": f"File not found: {pdf_path}"}))
        sys.exit(1)

    rubric = load_rubric(rubric_path)
    features = extract_features(pdf_path)
    result = classify(features, rubric)
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
