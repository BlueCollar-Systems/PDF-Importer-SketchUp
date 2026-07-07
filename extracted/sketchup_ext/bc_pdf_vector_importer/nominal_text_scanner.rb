# nominal_text_scanner.rb — Round 13 Row 4 (owner field bug: SU 3D text scale)
#
# Scans decoded PDF content streams for text-showing operations and records,
# per show-op, the NOMINAL text height and rotation derived the one correct
# way (Round 13 directive):
#
#   nominal_height_pt = Tf_size * vertical_scale(Tm . CTM)
#   vertical_scale(M) = length of the image of (0,1) under M's linear part
#                     = hypot(c, d) for PDF row-vector [a b c d e f]
#
# The external (pdftotext) extractor then matches each string to the nearest
# anchor and takes its nominal size + angle, demoting bbox-derived sizing to
# fallback only. Ruby 2.2 compatible (SketchUp Make 2017).

module BlueCollarSystems
  module PDFVectorImporter
    module NominalTextScanner
      Anchor = Struct.new(:x, :y, :size_pt, :angle_deg)

      NUM = /[-+]?(?:\d+\.?\d*|\.\d+)/

      # Tokenize a decoded content stream into numbers/operators/strings,
      # tracking only what text sizing needs: q/Q, cm, BT/ET, Tf, Tm,
      # Td/TD/T* (origin moves), Tj/TJ/quote ops (anchors emitted).
      def self.scan(streams)
        anchors = []
        streams = [streams] unless streams.is_a?(Array)
        streams.each do |raw|
          next unless raw
          begin
            scan_stream(raw.to_s, anchors)
          rescue StandardError
            next # a malformed stream never breaks import
          end
        end
        anchors
      end

      def self.scan_stream(src, anchors)
        # CTM stack (graphics state), text state
        ctm = [1.0, 0.0, 0.0, 1.0]
        stack = []
        tm = nil     # text matrix (a,b,c,d) — nil outside BT/ET
        tlm = nil
        tf = 1.0
        tx = 0.0
        ty = 0.0
        operands = []

        tokens = src.scan(%r{
          \((?:\\.|[^\\()])*\) |   # literal string
          <[0-9A-Fa-f\s]*>     |   # hex string
          \[[^\]]*\]           |   # array (TJ)
          /[^\s\[\]()<>/]+     |   # name
          #{NUM}               |   # number
          [A-Za-z'"*]+             # operator
        }x)

        tokens.each do |tok|
          case tok
          when /\A#{NUM}\z/
            operands << tok.to_f
          when /\A[\(<\[]/
            operands << tok
          when %r{\A/}
            operands << tok
          when 'q'
            stack.push(ctm.dup)
            operands = []
          when 'Q'
            ctm = stack.pop || [1.0, 0.0, 0.0, 1.0]
            operands = []
          when 'cm'
            if operands.length >= 6
              n = operands[-6, 6]
              ctm = mat_mul([n[0], n[1], n[2], n[3]], ctm)
            end
            operands = []
          when 'BT'
            tm = [1.0, 0.0, 0.0, 1.0]
            tlm = tm.dup
            tx = 0.0
            ty = 0.0
            operands = []
          when 'ET'
            tm = nil
            operands = []
          when 'Tf'
            tf = operands[-1].is_a?(Float) ? operands[-1] : tf
            operands = []
          when 'Tm'
            if operands.length >= 6
              n = operands[-6, 6]
              tm = [n[0], n[1], n[2], n[3]]
              tlm = tm.dup
              tx = n[4].to_f
              ty = n[5].to_f
            end
            operands = []
          when 'Td', 'TD'
            if tm && operands.length >= 2
              dx = operands[-2].to_f
              dy = operands[-1].to_f
              tx += tlm[0] * dx + tlm[2] * dy
              ty += tlm[1] * dx + tlm[3] * dy
            end
            operands = []
          when 'T*'
            operands = []
          when 'Tj', 'TJ', "'", '"'
            if tm
              m = mat_mul(tm, ctm)
              hx = m[0]
              hy = m[1]                              # image of (1,0) -> angle
              hlen = Math.hypot(hx, hy)
              # Shear-invariant glyph height (matches the shared core /
              # MuPDF convention): |det| / |image of (1,0)|. Plain hypot(c,d)
              # would inflate skewed text by the shear component.
              det = (m[0] * m[3] - m[1] * m[2]).abs
              vs = hlen > 1e-9 ? det / hlen : Math.hypot(m[2], m[3])
              ang = -Math.atan2(hy, hx) * 180.0 / Math::PI
              # device position of text origin
              dx = tx * ctm[0] + ty * ctm[2]
              dy = tx * ctm[1] + ty * ctm[3]
              anchors << Anchor.new(dx, dy, tf * vs, ang)
            end
            operands = []
          else
            operands = []
          end
        end
      end

      # PDF row-vector convention: [a b c d] applied as row * M.
      def self.mat_mul(m1, m2)
        [
          m1[0] * m2[0] + m1[1] * m2[2],
          m1[0] * m2[1] + m1[1] * m2[3],
          m1[2] * m2[0] + m1[3] * m2[2],
          m1[2] * m2[1] + m1[3] * m2[3]
        ]
      end

      # Nearest anchor to a point (PDF user space, y-up), nil if none close.
      def self.nearest(anchors, x, y, max_dist)
        best = nil
        best_d = max_dist * max_dist
        anchors.each do |a|
          d = (a.x - x) * (a.x - x) + (a.y - y) * (a.y - y)
          if d <= best_d
            best_d = d
            best = a
          end
        end
        best
      end
    end
  end
end
