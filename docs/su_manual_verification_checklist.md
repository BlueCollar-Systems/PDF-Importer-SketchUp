# SketchUp Manual Verification Checklist (Blocked AUTO Tests)

Generated from `qa_results_auto_local_full_combined.json` + workbook `SketchUp Tests`.

## Run Setup
1. Open SketchUp Make 2017.
2. Confirm extension `bc_pdf_vector_importer` is enabled.
3. Use input PDF indicated per test.
4. Record result/evidence in `su_manual_verification_report.csv`.

## Blocked Tests
- SU-T001 | P0 | Install | Fresh install via Extension Manager
  Input: SketchUp-PDF-Importer_v3.5.0.rbz
  Steps: Extensions > Extension Manager > Install > select .rbz
  Expected: No errors in Ruby Console. Menu appears under Plugins > PDF Vector Importer.
  Metrics: 

- SU-T019 | P0 | Geometry | Lines import correctly
  Input: your-drawing.pdf
  Steps: Import with mode=auto
  Expected: Straight lines present matching PDF
  Metrics: Edge count > 1000

- SU-T020 | P0 | Geometry | Arcs reconstructed from polyline segments
  Input: your-drawing.pdf
  Steps: Import with mode=auto. Zoom to pipe bends.
  Expected: Smooth arcs, not faceted polylines
  Metrics: Arc count > 10. Radius deviation < 2% RMS

- SU-T026 | P0 | Geometry | Color preservation
  Input: PDF with colored geometry
  Steps: Import with group_by_color=Yes
  Expected: Color groups created matching PDF stroke colors
  Metrics: 

- SU-T027 | P0 | Geometry | Faces created from closed paths
  Input: your-drawing.pdf
  Steps: Import with mode=auto
  Expected: Faces present on closed filled paths
  Metrics: Face count > 0

- SU-T028 | P0 | Text | Labels mode — text as SketchUp text entities
  Input: your-drawing.pdf
  Steps: Import with Text=Labels
  Expected: Text objects placed near geometry. Readable.
  Metrics: Text count > 50

- SU-T041 | P1 | Mode | Auto mode keeps fidelity invariant
  Input: your-drawing.pdf
  Steps: Import with mode=auto and default text settings
  Expected: Geometry, faces, and text preserve source fidelity.
  Metrics: Record import time and geometry/text counts

- SU-T044 | P0 | Core-1071 | Complete shop drawing import
  Input: your-drawing.pdf
  Steps: Import with mode=auto
  Expected: Geometry complete. Dimensions readable. Part marks visible.
  Metrics: Edges>1000, Arcs>10, Text>50

- SU-T047 | P0 | Core-1071 | Import time
  Input: your-drawing.pdf
  Steps: Time the import
  Expected: < 15 seconds on modern hardware
  Metrics: Record actual time

- SU-T049 | P0 | Core-Topo | P0: OCG layers created
  Input: public topo/map PDF with OCG layers
  Steps: Check Layers panel after import
  Expected: 27 PDF::Layer::* tags present
  Metrics: Count layers

- SU-T053 | P0 | Core-Topo | PNG predictor decoding works
  Input: public topo/map PDF with compressed image streams
  Steps: Import (test passes if import succeeds at all)
  Expected: Parser finds >300 objects from compressed xref
  Metrics: 

- SU-T054 | P0 | Core-Topo | Import time
  Input: public topo/map PDF
  Steps: Time the import
  Expected: < 120 seconds
  Metrics: Record actual time

- SU-T057 | P0 | Layers | OCG layers detected from PDF
  Input: public topo/map PDF with OCG layers
  Steps: Import. Check layer count.
  Expected: Layer count matches PDF OCG count (27)
  Metrics: 

- SU-T067 | P0 | Perf | Shop drawing runtime
  Input: your-drawing.pdf
  Steps: Time mode=auto import
  Expected: < 15 seconds
  Metrics: Record time

- SU-T068 | P0 | Perf | Topo map runtime
  Input: public topo/map PDF
  Steps: Time mode=auto import
  Expected: < 120 seconds
  Metrics: Record time

- SU-T078 | P0 | Undo | Re-import produces identical result
  Input: your-drawing.pdf
  Steps: Import twice with same settings. Compare edge counts.
  Expected: Edge count identical both times.
  Metrics: 
