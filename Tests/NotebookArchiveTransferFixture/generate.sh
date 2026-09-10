#!/bin/bash
set -euo pipefail
# PencilKit's stroke constructor requires a real process bundle identifier for
# its replica preferences. Generate the synthetic fixture in a private home;
# decoding it in the offline importer does not create or edit a drawing.
root="$(cd "$(dirname "$0")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir "$work/home"
cat > "$work/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.amirtlinov.notebook.archive-fixture</string></dict></plist>
PLIST
cat > "$work/main.swift" <<'SWIFT'
import Foundation
import PencilKit
let points = [CGFloat(20), 100].enumerated().map { index, x in
  PKStrokePoint(location: .init(x: x, y: 40), timeOffset: Double(index) / 60,
    size: .init(width: 2, height: 2), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
}
let stroke = PKStroke(ink: PKInk(.pen, color: .black),
  path: PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSince1970: 1)))
let drawing = PKDrawing(strokes: [stroke])
let data = drawing.dataRepresentation()
let decoded = try PKDrawing(data: data)
precondition(decoded.strokes.count == 1)
try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
SWIFT
xcrun swiftc "$work/main.swift" -o "$work/generate" \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$work/Info.plist"
HOME="$work/home" CFFIXED_USER_HOME="$work/home" "$work/generate" \
  "$root/Tests/NotebookArchiveTransferTests/Resources/one-stroke.pkd"
