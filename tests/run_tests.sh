#!/bin/bash
# Compiles and runs unit + integration tests. Fixtures and binaries go to a
# scratch dir (default: mktemp) so nothing lands in the repo tree.
set -euo pipefail
cd "$(dirname "$0")/.."

SCRATCH="${1:-$(mktemp -d /tmp/resizer-tests.XXXXXX)}"
mkdir -p "$SCRATCH"
echo "Scratch dir: $SCRATCH"

echo "== Unit: geometry =="
# swiftc only allows top-level statements in a file literally named main.swift
mkdir -p "$SCRATCH/unit"
cp tests/test_geometry.swift "$SCRATCH/unit/main.swift"
swiftc Sources/Geometry.swift "$SCRATCH/unit/main.swift" \
    -swift-version 5 -o "$SCRATCH/test_geometry"
"$SCRATCH/test_geometry"

echo "== Unit: pdf model =="
mkdir -p "$SCRATCH/unit_pdf"
cp tests/test_pdf_model.swift "$SCRATCH/unit_pdf/main.swift"
swiftc Sources/PdfEditModel.swift "$SCRATCH/unit_pdf/main.swift" \
    -swift-version 5 -o "$SCRATCH/test_pdf_model"
"$SCRATCH/test_pdf_model"

echo "== Integration: pdfkit =="
mkdir -p "$SCRATCH/int_pdf"
cp tests/pdf_integration.swift "$SCRATCH/int_pdf/main.swift"
swiftc Sources/PdfEditModel.swift Sources/PdfAssembler.swift \
    "$SCRATCH/int_pdf/main.swift" \
    -swift-version 5 -framework AppKit -framework PDFKit \
    -o "$SCRATCH/test_pdf_integration"
"$SCRATCH/test_pdf_integration" "$SCRATCH/int_pdf"

echo "== Integration: sips + ffmpeg =="
FFMPEG="$(command -v ffmpeg || echo /usr/local/bin/ffmpeg)"
FIXTURES="$SCRATCH/fixtures"
rm -rf "$FIXTURES"
mkdir -p "$FIXTURES"
"$FFMPEG" -v error -f lavfi -i testsrc=size=400x300:rate=1 -frames:v 1 "$FIXTURES/test.png"
"$FFMPEG" -v error -f lavfi -i testsrc=duration=2:size=320x240:rate=15 \
    -pix_fmt yuv420p "$FIXTURES/test.mov"

mkdir -p "$SCRATCH/int"
cp tests/integration.swift "$SCRATCH/int/main.swift"
swiftc Sources/Geometry.swift Sources/ToolRunner.swift \
    Sources/ImageProcessor.swift Sources/GifProcessor.swift \
    "$SCRATCH/int/main.swift" \
    -swift-version 5 -o "$SCRATCH/test_integration"
"$SCRATCH/test_integration" "$FIXTURES"

echo "All tests passed."
