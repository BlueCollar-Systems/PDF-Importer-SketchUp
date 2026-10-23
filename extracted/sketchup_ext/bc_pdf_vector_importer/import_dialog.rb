# bc_pdf_vector_importer/import_dialog.rb
# Import dialog v7 — BCS-ARCH-001 professional single-flow + Rule 5 sweep.
# HtmlDialog with Modus styling (Trimble design system).
#
# Default UI: professional import (Auto per page internally). Vector and
# Raster appear only in Advanced ('Hybrid' is still accepted from saved
# settings and the CLI as another name for Auto). Basic dialog shows:
#   1. Text rendering selector (Text, Labels, 3D Text, Glyphs, Geometry, Raster)
#   2. Import text Yes/No toggle
# Plus legitimate workflow controls: pages, scale, page arrangement.
# Quality parameters are consolidated to the values in import_config.rb
# defaults — they are no longer adjustable.
#
# Falls back to UI.inputbox when HtmlDialog is unavailable (headless / test).
#
# Copyright 2024-2026 BlueCollar Systems — BUILT. NOT BOUGHT.

require File.join(File.dirname(__FILE__), 'page_selection')

module BlueCollarSystems
  module PDFVectorImporter
    module ImportDialog

      # BCS-ARCH-001 4-mode system (mirrors ImportConfig::MODES).
      # Auto   = decide per-page (vector | raster | hybrid)
      # Vector = force vector extraction; raster fallback OFF
      # Raster = force raster rendering; skip vectors/text/fills/arcs
      # Hybrid = vector + embedded raster images (raster fallback ON)
      MODES = {
        'Auto' => {
          'import_mode'        => 'auto',
          'text_mode'          => '3D Text',
          'import_text'        => 'Yes',
          'grouping_mode'      => 'Group per page',
          'page_arrangement'   => 'Spread (20% gap)',
        }.freeze,
        'Vector' => {
          'import_mode'        => 'vector',
          'text_mode'          => '3D Text',
          'import_text'        => 'Yes',
          'grouping_mode'      => 'Group per page',
          'page_arrangement'   => 'Spread (20% gap)',
        }.freeze,
        'Raster' => {
          'import_mode'        => 'raster',
          'text_mode'          => 'No text',
          'import_text'        => 'No',
          'grouping_mode'      => 'Single group',
          'page_arrangement'   => 'Spread (20% gap)',
        }.freeze,
        'Hybrid' => {
          'import_mode'        => 'hybrid',
          'text_mode'          => '3D Text',
          'import_text'        => 'Yes',
          'grouping_mode'      => 'Group per page',
          'page_arrangement'   => 'Spread (20% gap)',
        }.freeze,
      }.freeze

      YES_NO       = 'Yes|No'
      MODE_NAMES   = MODES.keys.join('|')
      TEXT_MODES   = 'Text|Labels|3D Text|Glyphs|Geometry|Raster'
      TEXT_MODE_CHOICES = TEXT_MODES.split('|').freeze
      # One short plain line per text choice, shown under the two text boxes.
      # Sketchup::Text is the Labels representation, not the distinct flat Text
      # representation. On SketchUp 2017, finite-bbox Text and Labels cannot
      # keep the PDF's letter size, so they arrive as source-outline 3D letters
      # (never an editable annotation and never a silent picture).
      TEXT_MODE_HINT_LINES = [
        '3D Text: solid letters that match the PDF',
        'Text / Labels: on SketchUp 2017 these also arrive as 3D letters',
        'Glyphs: letter outlines',
        'Geometry: lines and faces',
        'Raster: picture'
      ].map(&:freeze).freeze
      TEXT_MODE_HINT = TEXT_MODE_HINT_LINES.join("\n").freeze
      # A page with inline pictures can also arrive as one picture (the
      # inline-image paint-order rule), so the hint names both cases.
      AUTO_MODE_HINT = 'Auto keeps lines and text editable and places pictures where they are; ' \
                       'a page becomes one picture only when it is a scan or its pictures ' \
                       'cannot be placed separately.'.freeze
      # Grouping is fixed: one group per page with color sub-groups inside.
      # 'Picture of each page' (Raster) places one picture per page instead.
      # The saved grouping_mode value is still read so old settings load.
      GROUPING_HINT = 'Each page comes in as its own group, with color sub-groups inside ' \
                      '(in Picture of each page mode, each page comes in as one picture).'.freeze
      # Advanced 'Mode' choices in plain words. 'Hybrid' behaves exactly like
      # Auto, so it is not offered; saved 'Hybrid' settings show as Auto.
      MODE_CHOICE_LABELS = [
        ['Auto', 'Auto (recommended)'],
        ['Vector', 'Lines and text only (skips pictures)'],
        ['Raster', 'Picture of each page']
      ].map { |pair| pair.map(&:freeze).freeze }.freeze
      MODE_CHOICES = MODE_CHOICE_LABELS.map(&:first).join('|').freeze
      # Outer window sizes. Both fit a 1366x768 screen and a 1080p laptop at
      # 150% scaling (about 720 px) with the taskbar showing. The Import and
      # Cancel buttons are pinned to the bottom of the window and the
      # settings above them scroll, so a shorter window never hides them.
      DIALOG_SIZES = {
        :basic => [440, 620],
        :advanced => [460, 620]
      }.freeze
      # The tallest window that still fits those screens.
      DIALOG_MAX_HEIGHT = 640
      FIRST_RUN_TEXT_MODE = '3D Text'.freeze
      FIRST_RUN_MATCH_PDF_LAYERS = 'Yes'.freeze

      # Workflow choices kept after the Rule 5 sweep
      GROUPING_CHOICES         = 'Single group|Group per page|Group per layer|Group per color|Nested: page > layer|Nested: page > lineweight'
      PAGE_ARRANGEMENT_CHOICES = 'Spread (20% gap)|Compact gap|Touching pages|Overlay pages'
      LINEWIDTH_CHOICES = [
        ['Ignore', 'Editable centerlines (fast)'],
        ['Preserve visually', 'Draw source line widths'],
        ['Group by lineweight', 'Group centerlines by width'],
        ['Map to tags', 'Put centerline widths on tags']
      ].map { |pair| pair.map(&:freeze).freeze }.freeze
      LINEWIDTH_HINT = 'Centerlines stay editable but do not reproduce PDF line thickness. ' \
        'Drawing source widths takes longer; dense sheets or work beyond the time limit ' \
        'retain centerlines and list the limit in the import report. Raster uses the page image.'.freeze

      # Closed-region page extrusion is disabled independently of 3D text.
      SHAPE_EXTRUSION_UI_ENABLED = false

      def self.complexity_confirmation_message(assessment)
        data = assessment.is_a?(Hash) ? assessment : {}
        counts = data[:counts].is_a?(Hash) ? data[:counts] : {}
        size_label = data[:class].to_s == 'very_large' ?
          'Very large' : 'Large'
        parts = []
        parts << "#{format_integer(counts[:paths])} paths" if counts.key?(:paths)
        if counts.key?(:text_items)
          parts << "#{format_integer(counts[:text_items])} text items"
        end
        if counts.key?(:glyph_placements)
          parts << "#{format_integer(counts[:glyph_placements])} glyph placements"
        end
        "#{size_label} editable import: #{parts.join(', ')} " \
          "(#{format_integer(data[:work_units])} work units).\n\n" \
          'Progress will remain visible. Esc cancels the current partial page; ' \
          'certified completed pages are kept and can be resumed.'
      end

      PROGRESS_STAGE_LABELS = {
          'reading_pdf' => 'reading the PDF',
          'page_parse' => 'reading the page',
          'page' => 'placing the page picture',
          'reading_paths' => 'reading lines and fills',
          'reading_text' => 'reading text',
          'analyzing_page' => 'checking the page',
          'geometry_path' => 'drawing lines and fills',
          'stroke_footprint' => 'measuring line widths',
          'renderer_stage' => 'preparing text',
          'text_outlines' => 'reading letter shapes',
          'text_item' => 'building text',
          'glyph_placement' => 'placing letters',
          'text_evidence' => 'checking text',
          'text_step_down' => 'stepping down text that did not build',
          'page_picture' => 'drawing the page picture',
          'cleanup' => 'cleaning up lines',
          'extruding' => 'extruding faces',
          'certify_page' => 'recording the finished page',
          'pre_commit' => 'saving the page',
          'page_completed' => 'page finished',
          'import_report' => 'writing the import report',
          'complexity_confirmation' => 'checking the page size',
          'white_mask_scan' => 'checking page content',
          'white_mask_inventory' => 'reading PDF paint order',
          'white_mask_inventory_glyphs' => 'reading text outlines',
          'white_mask_binding' => 'matching fills to PDF',
          'white_mask_binding_ink' => 'matching text to PDF',
          'white_mask_ink' => 'reading text outlines',
          'white_mask_boundaries' => 'processing fill boundaries',
          'white_mask_intersections' => 'processing fill boundaries',
          'white_mask_partition' => 'dividing fill regions',
          'white_mask_cells' => 'building fill cutouts',
          'white_mask_verify' => 'checking fill cutouts',
          'white_mask_coverage' => 'checking text coverage',
          'white_mask_style' => 'finishing fill cutouts',
          'white_mask' => 'layering fills and text'
      }.freeze

      # A stage needs this much of its own running time before its
      # remaining time is shown; earlier estimates swing too much.
      PROGRESS_ETA_MIN_STAGE_SECONDS = 2.0

      # One plain status line, for example
      # "Importing page 1 of 1: building text 120 of 557 (about 30 s left),
      # press Esc to cancel". The time left is the current step's, measured
      # from its own pace, and is shown only once that pace is known.
      def self.progress_status(snapshot)
        data = snapshot.is_a?(Hash) ? snapshot : {}
        stage_key = data[:stage].to_s
        stage = PROGRESS_STAGE_LABELS.fetch(stage_key, stage_key.tr('_', ' '))
        # Fine composition stages repeat for separate masks on the same page.
        # The controller's page-wide monotonic value/ETA belong to an earlier
        # mask after a restart; display the current task's real count instead.
        repeated_mask_stage = stage_key.start_with?('white_mask_')
        completed = data[:completed].to_i
        total = data[:total].to_i
        completed = total if total > 0 && completed > total
        text = "Importing #{progress_page_phrase(data)}: #{stage}"
        if total > 0
          text += " #{format_integer(completed)} of #{format_integer(total)}"
        end
        left = repeated_mask_stage ? nil : progress_time_left(data, completed, total)
        text += " (#{left})" if left
        text + ', press Esc to cancel'
      end

      def self.progress_page_phrase(data)
        page = data[:page] || data[:current_page]
        index = data[:page_index]
        page_total = data[:page_total]
        if index && page_total
          if page && page.to_i != index.to_i
            "page #{page} (#{index} of #{page_total})"
          else
            "page #{index} of #{page_total}"
          end
        elsif page
          "page #{page}"
        else
          'the PDF'
        end
      end

      def self.progress_time_left(data, completed, total)
        eta = data[:eta_seconds]
        return nil if eta.nil? || total <= 0 || completed <= 0 || completed >= total
        stage_elapsed = data[:stage_elapsed_seconds]
        return nil unless stage_elapsed &&
                          stage_elapsed.to_f >= PROGRESS_ETA_MIN_STAGE_SECONDS
        seconds = eta.to_f
        return nil unless seconds.finite? && seconds >= 0.0
        return 'a few seconds left' if seconds < 10.0
        rounded = ((seconds / 5.0).round * 5).to_i
        return "about #{rounded} s left" if rounded < 60
        "about #{[(seconds / 60.0).round, 1].max} min left"
      end

      def self.format_integer(value)
        value.to_i.to_s.reverse.scan(/.{1,3}/).join(',').reverse
      end

      def self.show(filepath)
        filename = File.basename(filepath)
        saved    = load_prefs
        if defined?(UI::HtmlDialog) && !ENV['BC_HEADLESS']
          show_html_basic(filename, saved)
        else
          show_inputbox_basic(filename, saved)
        end
      end

      def self.show_advanced(filepath, pages_str, scale_str, _recog_str, text_mode_str)
        filename = File.basename(filepath)
        saved    = load_prefs
        if defined?(UI::HtmlDialog) && !ENV['BC_HEADLESS']
          show_html_advanced(filename, pages_str, scale_str, text_mode_str, saved)
        else
          show_inputbox_advanced(filename, pages_str, scale_str, text_mode_str, saved)
        end
      end

      # ---- HtmlDialog: Basic ----------------------------------------
      def self.show_html_basic(filename, saved)
        result = nil
        dlg = UI::HtmlDialog.new(
          dialog_title: "Import PDF \u2014 #{filename}",
          preferences_key: 'BC_PDFImport_Basic',
          width: DIALOG_SIZES[:basic][0], height: DIALOG_SIZES[:basic][1],
          resizable: false
        )
        apply_dialog_size(dlg, :basic)

        mode_val    = valid_mode_name(saved[:last_mode])
        # A page range belongs to this request, not the next PDF opened.
        pages_val   = 'All'
        scale_val   = saved[:scale]       || '1.0'
        text_val    = effective_text_mode(saved)
        itext_val   = saved[:import_text] || 'Yes'
        match_val   = effective_match_pdf_layers(saved)
        lineweight_val = effective_lineweight_mode(saved)
        # A saved Audit = Yes (or BC_PDF_AUDIT=1) also applies here, so the
        # window says so instead of leaving a slow mode on unseen.
        audit_on    = audit_requested?({})

        dlg.set_html(basic_html(filename, mode_val, pages_val, scale_val, text_val, itext_val,
                                match_val, audit_on, lineweight_val))

        dlg.add_action_callback('on_import') do |_ctx, p|
          begin
            pages_str   = p['pages']       || 'All'
            scale_str   = p['scale']       || '1.0'
            text_mode   = p['text_mode']   || text_val
            import_text = p['import_text'] || 'Yes'
            match_pdf_layers = p['match_pdf_layers'] || match_val
            lineweight = parse_lineweight_mode(p['lineweight_mode'] || lineweight_val)
            PageSelection.parse(pages_str)
            parse_import_scale(scale_str)
            save_prefs(last_mode: 'Auto', pages: pages_str,
                       scale: scale_str, text_mode: text_mode,
                       import_text: import_text,
                       match_pdf_layers: match_pdf_layers, lineweight_mode: lineweight)
            mode_raw = MODES['Auto']
            mode_sym = {}
            mode_raw.each { |k, v| mode_sym[k.to_sym] = v }
            result = build_opts(mode_sym.merge(pages: pages_str,
                                               scale: scale_str,
                                               text_mode: text_mode,
                                               import_text: import_text,
                                               match_pdf_layers: match_pdf_layers, lineweight_mode: lineweight))
            dlg.close
          rescue ArgumentError => error
            UI.messagebox(error.message)
          end
        end

        dlg.add_action_callback('on_cancel') do |_ctx, _p|
          result = nil
          dlg.close
        end
        dlg.add_action_callback('on_advanced') do |_ctx, p|
          begin
            PageSelection.parse(p['pages'] || 'All')
            parse_import_scale(p['scale'] || '1.0')
            save_prefs(last_mode: 'Auto',
                       pages: p['pages']     || 'All',
                       scale: p['scale']     || '1.0',
                       text_mode: p['text_mode'] || text_val,
                       import_text: p['import_text'] || 'Yes',
                       match_pdf_layers: p['match_pdf_layers'] || match_val)
            dlg.close
            result = show_html_advanced(filename, p['pages'] || 'All',
                                        p['scale'] || '1.0',
                                        p['text_mode'] || text_val,
                                        load_prefs)
          rescue ArgumentError => error
            UI.messagebox(error.message)
          end
        end
        dlg.show_modal
        result
      end

      # ---- HtmlDialog: Advanced (workflow and line-width representation) ---
      def self.show_html_advanced(filename, pages_str, scale_str, text_mode_str, saved)
        result = nil
        dlg = UI::HtmlDialog.new(
          dialog_title: "Advanced Import \u2014 #{filename}",
          preferences_key: 'BC_PDFImport_Advanced',
          width: DIALOG_SIZES[:advanced][0], height: DIALOG_SIZES[:advanced][1],
          resizable: false
        )
        apply_dialog_size(dlg, :advanced)

        d = {
          mode:             valid_mode_name(saved[:last_mode]),
          pages:            pages_str      || 'All',
          scale:            scale_str      || saved[:scale]            || '1.0',
          text_mode:        text_mode_str  || effective_text_mode(saved),
          import_text:      saved[:import_text]                        || 'Yes',
          match_pdf_layers: effective_match_pdf_layers(saved),
          grouping_mode:    saved[:grouping_mode]                      || 'Group per page',
          page_arrangement: saved[:page_arrangement]                   || 'Spread (20% gap)',
          lineweight_mode: effective_lineweight_mode(saved),
          extrude_to_3d:    saved[:extrude_to_3d]                      || 'No',
          extrude_depth_mm: saved[:extrude_depth_mm]                   || '',
          audit:            audit_choice(saved[:audit])
        }

        dlg.set_html(advanced_html(filename, d))

        dlg.add_action_callback('on_import') do |_ctx, p|
          begin
            PageSelection.parse(p['pages'])
            parse_import_scale(p['scale'] || '1.0')
            lineweight = parse_lineweight_mode(p['lineweight_mode'] || d[:lineweight_mode])
            to_save = {
              last_mode: p['mode'],
              pages: p['pages'], scale: p['scale'],
              text_mode: p['text_mode'], import_text: p['import_text'],
              match_pdf_layers: p['match_pdf_layers'],
              page_arrangement: p['page_arrangement'],
              lineweight_mode: lineweight,
              extrude_to_3d: p['extrude_to_3d'],
              extrude_depth_mm: p['extrude_depth_mm']
            }
            # While BC_PDF_AUDIT=1 forces Audit on, the box shows Yes but is
            # not the user's choice: keep the saved setting, so Audit does
            # not stay on after the variable is removed.
            to_save[:audit] = audit_choice(p['audit']) unless audit_env_on?
            save_prefs(to_save)
            mode_raw = MODES[p['mode'] || 'Auto'] || MODES['Auto']
            result = build_opts(
              import_mode: mode_raw['import_mode'],
              pages: p['pages'], scale: p['scale'],
              layer_name: 'PDF Import',
              group_per_page: 'Yes',
              group_by_color: 'Yes',
              text_mode: p['text_mode'],
              import_text: p['import_text'],
              match_pdf_layers: p['match_pdf_layers'],
              page_arrangement: p['page_arrangement'],
              lineweight_mode: lineweight,
              extrude_to_3d: p['extrude_to_3d'],
              extrude_depth_mm: p['extrude_depth_mm'],
              audit: audit_choice(p['audit'])
            )
            dlg.close
          rescue ArgumentError => error
            UI.messagebox(error.message)
          end
        end

        dlg.add_action_callback('on_cancel') do |_ctx, _p|
          result = nil
          dlg.close
        end
        dlg.show_modal
        result
      end

      # SketchUp before 2019 ignores the width/height arguments once the
      # preferences_key has a saved size, so set the size explicitly.
      def self.apply_dialog_size(dlg, kind)
        return unless dlg.respond_to?(:set_size)
        width, height = DIALOG_SIZES.fetch(kind)
        dlg.set_size(width, height)
      rescue StandardError => e
        Logger.warn('ImportDialog', "set_size failed: #{e.message}")
      end

      def self.text_mode_hint_html
        lines = TEXT_MODE_HINT_LINES.map { |line| esc(line) }.join('<br>')
        "<p class=\"hint hint-block\">#{lines}</p>"
      end

      # ---- HTML generators ------------------------------------------
      DIALOG_CSS = <<-CSS.freeze
        *{box-sizing:border-box;margin:0;padding:0}
        body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Helvetica,Arial,sans-serif;
             font-size:13px;color:#1a1a1a;background:#fff;padding:20px;padding-bottom:64px}
        h2{font-size:14px;font-weight:600;margin-bottom:4px}
        .sub{font-size:11px;color:#666;margin-bottom:16px;
             white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
        label{display:block;font-size:12px;font-weight:500;color:#444;margin-bottom:3px}
        select,input[type=text]{width:100%;border:1px solid #ccc;border-radius:3px;
            padding:6px 8px;font-size:13px;color:#1a1a1a;background:#fff;outline:none}
        select:focus,input:focus{border-color:#0078d7}
        .row{margin-bottom:12px}
        .row2{margin-bottom:10px;font-size:0}
        .row2>div{display:inline-block;width:48%;vertical-align:top;font-size:13px}
        .row2>div+div{margin-left:4%}
        .section{border-top:1px solid #e4e4e4;padding-top:10px;margin-top:4px;
                 font-size:11px;font-weight:600;color:#888;text-transform:uppercase;
                 letter-spacing:.6px;margin-bottom:8px}
        .actions{position:fixed;left:0;right:0;bottom:0;background:#fff;padding:10px 20px;margin:0;
                 text-align:right;border-top:1px solid #e4e4e4}
        .btn+.btn{margin-left:8px}
        .btn{padding:7px 18px;border-radius:3px;font-size:13px;
             font-weight:500;cursor:pointer;border:1px solid transparent}
        .btn-primary{background:#0078d7;color:#fff;border-color:#0078d7}
        .btn-primary:hover{background:#005fa3}
        .btn-secondary{background:#fff;color:#333;border-color:#ccc}
        .btn-secondary:hover{background:#f3f3f3}
        .hint{font-size:11px;color:#888;margin-top:2px}
        .hint-block{margin:-4px 0 12px}
        .audit-on{color:#8a4b00;font-weight:600}
      CSS

      def self.basic_html(filename, _mode, pages, scale, text_mode, import_text, match_pdf_layers,
                          audit_on = false, lineweight_mode = 'Ignore')
        lineweight_mode = effective_lineweight_mode(:lineweight_mode => lineweight_mode)
        lineweight_label = LINEWIDTH_CHOICES.assoc(lineweight_mode)[1]
        text_opts = TEXT_MODE_CHOICES.map { |v|
          sel = v == text_mode ? ' selected' : ''
          "<option value=\"#{v}\"#{sel}>#{v}</option>"
        }.join

        itext_yes = import_text == 'Yes' ? ' selected' : ''
        itext_no  = import_text == 'No'  ? ' selected' : ''
        match_yes = match_pdf_layers == 'Yes' ? ' selected' : ''
        match_no  = match_pdf_layers == 'No'  ? ' selected' : ''
        audit_note_html = audit_on ? "<p class=\"hint hint-block audit-on\" id=\"audit-note\">#{esc(AUDIT_ON_NOTE)}</p>" : ''

        <<-HTML
          <!DOCTYPE html><html><head><meta charset="utf-8">
          <style>#{DIALOG_CSS}</style></head><body>
          <h2>Import PDF Vectors</h2>
          <p class="sub">#{esc(filename)}</p>
          <p class="hint" style="margin-bottom:14px">#{esc(AUTO_MODE_HINT)}</p>
          #{audit_note_html}
          <p class="hint hint-block" id="line-width-note">Line widths: #{esc(lineweight_label)}. Change in Advanced. #{esc(LINEWIDTH_HINT)}</p>
          <div class="row"><label>Pages</label>
            <input type="text" id="pages" value="#{esc(pages)}" placeholder="All">
            <p class="hint">e.g. All &nbsp;&bull;&nbsp; 1 &nbsp;&bull;&nbsp; 2-5 &nbsp;&bull;&nbsp; 1,3,7</p>
          </div>
          <div class="row"><label>Scale Factor</label>
            <input type="text" id="scale" value="#{esc(scale)}" placeholder="1.0"></div>
          <div class="row2">
            <div><label>Import Text</label>
              <select id="import_text">
                <option value="Yes"#{itext_yes}>Yes</option>
                <option value="No"#{itext_no}>No</option>
              </select></div>
            <div><label>Text Rendering</label>
              <select id="text_mode">#{text_opts}</select></div>
          </div>
          #{text_mode_hint_html}
          <div class="row"><label>Match PDF Layers</label>
            <select id="match_pdf_layers">
              <option value="Yes"#{match_yes}>Yes — create SketchUp Tags from PDF layers</option>
              <option value="No"#{match_no}>No — single import layer</option>
            </select>
            <p class="hint">Yes: each PDF layer becomes a SketchUp Tag with the same name.</p>
          </div>
          <div class="actions">
            <button class="btn btn-secondary" onclick="cancel()">Cancel</button>
            <button class="btn btn-secondary" onclick="advanced()">Advanced...</button>
            <button class="btn btn-primary" onclick="doImport()">Import</button>
          </div>
          <script>
          function payload(){return {
            pages:document.getElementById('pages').value.trim()||'All',
            scale:document.getElementById('scale').value.trim()||'1.0',
            import_text:document.getElementById('import_text').value,
            text_mode:document.getElementById('text_mode').value,
            lineweight_mode:'#{lineweight_mode}',
            match_pdf_layers:document.getElementById('match_pdf_layers').value};}
          function doImport(){sketchup.on_import(payload());}
          function advanced(){sketchup.on_advanced(payload());}
          function cancel(){sketchup.on_cancel({});}
          document.addEventListener('keydown',function(e){
            if(e.key==='Enter' && e.target && e.target.tagName!=='BUTTON'){e.preventDefault();doImport();}
            if(e.key==='Escape')cancel();});
          </script></body></html>
        HTML
      end

      def self.advanced_html(filename, d)
        selected_mode = dialog_mode_name(d[:mode])
        mode_opts = MODE_CHOICE_LABELS.map { |m, lbl|
          sel = selected_mode == m ? ' selected' : ''
          "<option value=\"#{esc(m)}\"#{sel}>#{esc(lbl)}</option>"
        }.join

          text_opts = [['Text','Text'],['Labels','Labels'],['3D Text','3D Text'],['Glyphs','Glyphs'],['Geometry','Geometry'],['Raster','Raster']].map{|v,lbl|
          sel = d[:text_mode] == v ? ' selected' : ''
          "<option value=\"#{v}\"#{sel}>#{lbl}</option>"
        }.join

        yn = lambda { |key|
          yes = d[key] == 'Yes' ? ' selected' : ''
          no  = d[key] == 'No'  ? ' selected' : ''
          "<option value=\"Yes\"#{yes}>Yes</option><option value=\"No\"#{no}>No</option>"
        }

        page_arrangement_opts = PAGE_ARRANGEMENT_CHOICES.split('|').map{|v|
          sel = d[:page_arrangement] == v ? ' selected' : ''
          "<option value=\"#{esc(v)}\"#{sel}>#{esc(v)}</option>"
        }.join
        lineweight_mode = effective_lineweight_mode(d)
        linewidth_opts = LINEWIDTH_CHOICES.map { |value, label|
          selected = lineweight_mode == value ? ' selected' : ''
          "<option value=\"#{esc(value)}\"#{selected}>#{esc(label)}</option>"
        }.join

        audit_forced = audit_env_on?
        audit_on = audit_forced || audit_choice(d[:audit]) == 'Yes'
        audit_opts = "<option value=\"No\"#{audit_on ? '' : ' selected'}>No (recommended)</option>" \
                     "<option value=\"Yes\"#{audit_on ? ' selected' : ''}>Yes</option>"
        audit_forced_html = audit_forced ? "<p class=\"hint hint-block audit-on\">#{esc(AUDIT_FORCED_NOTE)}</p>" : ''
        # Forced on: the box shows Yes but cannot be changed here.
        audit_select_attrs = audit_forced ? ' disabled' : ''

        <<-HTML
          <!DOCTYPE html><html><head><meta charset="utf-8">
          <style>#{DIALOG_CSS}</style></head><body>
          <h2>Advanced Import Settings</h2>
          <p class="sub">#{esc(filename)}</p>
          <div class="row2">
            <div><label>Mode</label>
              <select id="mode">#{mode_opts}</select></div>
            <div><label>Pages</label>
              <input type="text" id="pages" value="#{esc(d[:pages])}" placeholder="All"></div>
          </div>
          <p class="hint hint-block">#{esc(AUTO_MODE_HINT)}</p>
          <div class="row2">
            <div><label>Scale Factor</label>
              <input type="text" id="scale" value="#{esc(d[:scale])}" placeholder="1.0"></div>
            <div><label>#{esc(AUDIT_LABEL)}</label>
              <select id="audit"#{audit_select_attrs}>#{audit_opts}</select></div>
          </div>
          <p class="hint hint-block">#{esc(AUDIT_HINT)}</p>
          #{audit_forced_html}
          <div class="section">Text</div>
          <div class="row2">
            <div><label>Import Text</label>
              <select id="import_text">#{yn.call(:import_text)}</select></div>
            <div><label>Text Rendering</label>
              <select id="text_mode">#{text_opts}</select></div>
          </div>
          #{text_mode_hint_html}
          <div class="section">Lines</div>
          <div class="row"><label>Line widths</label>
            <select id="lineweight_mode">#{linewidth_opts}</select>
            <p class="hint">#{esc(LINEWIDTH_HINT)}</p>
          </div>
          <div class="section">Layers</div>
          <div class="row"><label>Match PDF Layers</label>
            <select id="match_pdf_layers">
              <option value="Yes"#{' selected' if d[:match_pdf_layers] == 'Yes'}>Yes</option>
              <option value="No"#{' selected' if d[:match_pdf_layers] == 'No'}>No</option>
            </select>
            <p class="hint">Yes: each PDF layer becomes a SketchUp Tag with the same name.</p>
          </div>
          <div class="section">Layout</div>
          <div class="row"><label>Page Arrangement</label>
            <select id="page_arrangement">#{page_arrangement_opts}</select>
            <p class="hint">#{esc(GROUPING_HINT)}</p>
          </div>
          <!-- Closed-shape 3D Model controls intentionally disabled; source-glyph 3D Text remains available. -->
          <div class="actions">
            <button class="btn btn-secondary" onclick="cancel()">Cancel</button>
            <button class="btn btn-primary" onclick="doImport()">Import</button>
          </div>
          <script>
          function doImport(){sketchup.on_import({
            mode:document.getElementById('mode').value,
            pages:document.getElementById('pages').value.trim()||'All',
            scale:document.getElementById('scale').value.trim()||'1.0',
            import_text:document.getElementById('import_text').value,
            text_mode:document.getElementById('text_mode').value,
            lineweight_mode:document.getElementById('lineweight_mode').value,
            match_pdf_layers:document.getElementById('match_pdf_layers').value,
            page_arrangement:document.getElementById('page_arrangement').value,
            audit:document.getElementById('audit').value,
            extrude_to_3d:'No',
            extrude_depth_mm:''});}
          function cancel(){sketchup.on_cancel({});}
          document.addEventListener('keydown',function(e){
            if(e.key==='Enter' && e.target && e.target.tagName!=='BUTTON'){e.preventDefault();doImport();}
            if(e.key==='Escape')cancel();});
          </script></body></html>
        HTML
      end

      def self.esc(str)
        str.to_s.gsub('&','&amp;').gsub('"','&quot;').gsub("'",'&#39;').gsub('<','&lt;').gsub('>','&gt;')
      end

      # ---- UI.inputbox fallbacks (headless / pre-2017 SU) ----------
      def self.show_inputbox_basic(filename, saved)
        prompts   = ["Pages (1, 1-5, or All):","Scale Factor:",
                     "Import Text:","Text Rendering:","Match PDF Layers:",
                     "Line widths (limits use reported centerlines):"]
        linewidth = effective_lineweight_mode(saved)
        defaults  = ['All', saved[:scale]||'1.0',
                     saved[:import_text]||'Yes', effective_text_mode(saved),
                     effective_match_pdf_layers(saved), LINEWIDTH_CHOICES.assoc(linewidth)[1]]
        dropdowns = ['', '', YES_NO, TEXT_MODES, YES_NO, LINEWIDTH_CHOICES.map(&:last).join('|')]
        result = UI.inputbox(prompts, defaults, dropdowns, "Import PDF \u2014 #{filename}")
        return nil unless result
        pages_str, scale_str, import_text_str, text_mode_str, match_layers_str, lineweight_str = result
        lineweight_str ||= linewidth
        return nil unless valid_page_input?(pages_str)
        return nil unless valid_scale_input?(scale_str)
        return nil unless valid_lineweight_input?(lineweight_str)
        linewidth = parse_lineweight_mode(lineweight_str)
        save_prefs(last_mode: 'Auto', pages: pages_str,
                   scale: scale_str, import_text: import_text_str,
                   text_mode: text_mode_str, match_pdf_layers: match_layers_str, lineweight_mode: linewidth)
        mode_raw = MODES['Auto']
        sym_attrs = {}
        mode_raw.each { |k, v| sym_attrs[k.to_sym] = v }
        build_opts(sym_attrs.merge(pages: pages_str, scale: scale_str,
                                   import_text: import_text_str,
                                   text_mode: text_mode_str,
                                   match_pdf_layers: match_layers_str, lineweight_mode: linewidth))
      end

      def self.show_inputbox_advanced(filename, pages_str, scale_str, text_mode_str, saved)
        prompts = [
          "Mode:","Pages:","Scale Factor:",
          "Import Text:","Text Rendering:","Match PDF Layers:",
          "Page Arrangement:","Line widths (limits use reported centerlines):"
        ]
        defaults = [
          valid_mode_name(saved[:last_mode]),
          pages_str||'All', scale_str||saved[:scale]||'1.0',
          saved[:import_text]||'Yes',
          text_mode_str||effective_text_mode(saved),
          effective_match_pdf_layers(saved),
          saved[:page_arrangement]||'Spread (20% gap)',
          LINEWIDTH_CHOICES.assoc(effective_lineweight_mode(saved))[1]
        ]
        # A saved 'Hybrid' is the same as Auto, which is what the list offers.
        defaults[0] = dialog_mode_name(defaults[0])
        dropdowns = [MODE_CHOICES,'','',YES_NO,TEXT_MODES,YES_NO,PAGE_ARRANGEMENT_CHOICES,
          LINEWIDTH_CHOICES.map(&:last).join('|')]
        result = UI.inputbox(prompts, defaults, dropdowns, "Advanced Import \u2014 #{filename}")
        return nil unless result
        p_mode,p_pages,p_scale,p_import_text,p_text_mode,
        p_match_layers,p_page_arrangement,p_lineweight = result
        p_lineweight ||= effective_lineweight_mode(saved)
        return nil unless valid_page_input?(p_pages)
        return nil unless valid_scale_input?(p_scale)
        return nil unless valid_lineweight_input?(p_lineweight)
        linewidth = parse_lineweight_mode(p_lineweight)
        save_prefs(last_mode:p_mode,pages:p_pages,scale:p_scale,
                   import_text:p_import_text,text_mode:p_text_mode,
                   match_pdf_layers:p_match_layers,
                   page_arrangement:p_page_arrangement,lineweight_mode:linewidth)
        mode_raw = MODES[p_mode] || MODES['Auto']
        build_opts(import_mode:mode_raw['import_mode'],
                   pages:p_pages,scale:p_scale,
                   layer_name:'PDF Import',
                   group_per_page:'Yes',
                   group_by_color:'Yes',
                   import_text:p_import_text,text_mode:p_text_mode,
                   match_pdf_layers:p_match_layers,
                   page_arrangement:p_page_arrangement,lineweight_mode:linewidth)
      end

      def self.valid_page_input?(value)
        PageSelection.parse(value)
        true
      rescue ArgumentError => error
        UI.messagebox(error.message)
        false
      end

      def self.valid_scale_input?(value)
        parse_import_scale(value)
        true
      rescue ArgumentError => error
        UI.messagebox(error.message)
        false
      end

      def self.valid_lineweight_input?(value)
        parse_lineweight_mode(value)
        true
      rescue ArgumentError => error
        UI.messagebox(error.message)
        false
      end

      private

      def self.build_opts(raw)
        scale = parse_import_scale(raw[:scale] || '1.0')
        case (raw[:units] || '')
        when /Feet/i   then scale *= 12.0
        when /Points/i then scale /= 72.0
        end
        scale = parse_import_scale(scale)

        pages = PageSelection.parse(raw[:pages])

        # Requested text representation identities remain distinct end to end.
        # Import Text checkbox is the orthogonal on/off control.
        import_text_flag = (raw[:import_text] || 'Yes') == 'Yes'
        text_mode_raw = (raw[:text_mode] || FIRST_RUN_TEXT_MODE).to_s.strip
        text_mode_key = text_mode_raw.downcase.gsub(/\s+/, '_')
        text_mode = case text_mode_key
                    when 'no_text', 'none'     then :none
                    when 'text', 'flat_text',
                         'editable_text'      then :text
                    when 'labels', 'label',
                         'add_text'           then :labels
                    when '3d_text', 'text3d'  then :text3d
                    when 'glyphs'             then :glyphs
                    when 'geometry'           then :geometry
                    when 'raster', 'image'    then :raster
                    else
                      case text_mode_raw
                      when /No text/i           then :none
                      when /\AText\z/i         then :text
                      when /\ALabels?\z/i      then :labels
                      when /\A3D\s*Text\z/i     then :text3d
                      when /Glyphs/i            then :glyphs
                      when /Geometry/i          then :geometry
                      when /Raster|Image/i      then :raster
                      else                            :geometry
                      end
                    end
        # If the user disables Import Text, force the pipeline to :none.
        text_mode = :none unless import_text_flag
        import_text = (text_mode != :none)
        use_3d_text = (text_mode == :text3d)

        # BCS-ARCH-001 mode resolver. Accepts either a mode string
        # ('auto'|'vector'|'raster'|'hybrid') or defaults to 'auto'.
        mode_str = (raw[:import_mode] || 'auto').to_s.downcase
        mode_str = 'auto' unless %w[auto vector raster hybrid].include?(mode_str)

        # Mode-specific quality consolidation per BCS-ARCH-001:
        # Raster mode skips arcs / dashes / fills; everything else is on.
        is_raster = (mode_str == 'raster')
        group_per_page = (raw[:group_per_page] || 'Yes') == 'Yes'
        resumable = !is_raster && import_text && group_per_page &&
          [:text, :labels, :text3d, :glyphs, :geometry].include?(text_mode)

        # Shared sampling defaults from the parameter table in import_config.
        # Text representation and line-width output are explicit choices;
        # centerlines and reported bounded step-downs do not claim exact widths.
        {
          scale:            scale,
          pages:            pages,
          bezier_segments:  32,
          import_as:        is_raster ? :edges : :both,
          layer_name:       (raw[:layer_name] || 'PDF Import').to_s.strip,
          group_per_page:   group_per_page,
          resumable:        resumable,
          flatten_to_2d:    true,
          merge_tolerance:  0.0005,
          import_fills:     !is_raster,
          group_by_color:   (raw[:group_by_color] || 'Yes') == 'Yes',
          detect_arcs:      !is_raster,
          map_dashes:       !is_raster,
          import_text:      import_text,
          text_mode:        text_mode,
          use_3d_text:      use_3d_text,
          hatch_mode:       is_raster ? :skip : :group,
          # Raster is an explicit requested representation, never an implicit
          # substitute for an Auto/Vector/Hybrid extraction failure.
          raster_fallback:  false,
          force_raster:     is_raster,
          raster_dpi:       300,
          page_arrangement: (raw[:page_arrangement] || 'Spread (20% gap)').to_s,
          page_gap_ratio:   ((raw[:page_arrangement] || '').to_s =~ /compact/i) ? 0.05 : 0.20,
          cleanup_geometry: true,
          recognition_mode: :auto,
          arc_mode:         'Auto',
          cleanup_level:    'Balanced',
          # 'Preserve visually' builds a width footprint (about 97 one-face
          # groups) per round-capped line, so it stays an explicit choice. As
          # the default it made a dense sheet run for tens of minutes.
          lineweight_mode:  is_raster ? 'Ignore' : parse_lineweight_mode(raw[:lineweight_mode]),
          grouping_mode:    (raw[:grouping_mode] || 'Group per page').to_s,
          import_mode:      mode_str,
          match_pdf_layers: (raw[:match_pdf_layers] || 'Yes') == 'Yes',
          extrude_to_3d: SHAPE_EXTRUSION_UI_ENABLED && (raw[:extrude_to_3d] || 'No') == 'Yes',
          extrude_depth_mm: SHAPE_EXTRUSION_UI_ENABLED ? parse_extrude_depth_mm(raw[:extrude_depth_mm] || raw[:extrude_depth]) : nil,
          # Audit import (slow self-checks), default off. It changes how much
          # the importer re-proves, never what it builds.
          audit:            audit_requested?(raw)
        }
      end

      AUDIT_LABEL = 'Audit import (slow self-checks)'.freeze
      AUDIT_HINT = 'Audit: Yes double-checks every page as it is built. It is slower; ' \
                   'turn it on only when asked for a detailed report.'.freeze
      AUDIT_ENV = 'BC_PDF_AUDIT'.freeze
      AUDIT_ON_NOTE = 'Audit is on, so imports are slower. To turn it off, click ' \
                      'Advanced... and set Audit to No.'.freeze
      AUDIT_FORCED_NOTE = 'Audit is on for every import on this computer because ' \
                          'BC_PDF_AUDIT=1 is set; this box cannot turn it off.'.freeze
      AUDIT_ON_BATCH_NOTE = 'Audit is on, so these imports are slower. To turn it off, use ' \
                            'Import PDF..., click Advanced... and set Audit to No.'.freeze

      # The Advanced window's Audit choice ('Yes' or 'No') from a saved
      # setting or the window's own value. Anything not clearly on is 'No'.
      def self.audit_choice(value)
        value == true || value.to_s.strip =~ /\A(?:yes|true|1|on)\z/i ? 'Yes' : 'No'
      end

      # On when BC_PDF_AUDIT=1 (CI, host harness), when the caller passes
      # audit: 'Yes'/true (dialog, --audit), or when the saved setting says
      # Yes. Anything else is off.
      def self.audit_requested?(raw)
        return true if audit_env_on?
        value = raw.is_a?(Hash) && raw.key?(:audit) ? raw[:audit] : saved_audit_setting
        value == true || value.to_s.strip =~ /\A(?:yes|true|1|on)\z/i ? true : false
      end

      # BC_PDF_AUDIT=1 (CI, host harness) turns Audit on whatever is saved.
      def self.audit_env_on?
        ENV[AUDIT_ENV].to_s.strip =~ /\A(?:1|true|yes|on)\z/i ? true : false
      end

      def self.saved_audit_setting
        return nil unless defined?(Sketchup) && Sketchup.respond_to?(:read_default)
        Sketchup.read_default(PREF_KEY, 'audit', nil)
      rescue StandardError
        nil
      end

      def self.parse_import_scale(value)
        scale = Float(value)
        raise ArgumentError unless scale.finite? && scale > 0.0
        scale
      rescue ArgumentError, TypeError
        raise ArgumentError, 'Scale must be a positive, finite number, such as 1.0 or 0.5.'
      end

      def self.parse_extrude_depth_mm(value)
        return nil if value.nil?
        str = value.to_s.strip
        return nil if str.empty?
        num = str.to_f
        num > 0.0 ? num : nil
      end

      PREF_KEY = 'BlueCollarSystems_PDFVectorImporter'.freeze

      # Dialog default: last-used text mode from save_prefs; 3D Text on first run.
      def self.effective_text_mode(prefs)
        mode = prefs[:text_mode].to_s
        return mode if TEXT_MODE_CHOICES.include?(mode)
        return 'Labels' if mode =~ /\ALabel\z/i
        return 'Text' if mode =~ /\A(?:Flat|Editable)[ _]?Text\z/i

        FIRST_RUN_TEXT_MODE
      end

      def self.effective_match_pdf_layers(prefs)
        val = prefs[:match_pdf_layers].to_s
        return val if %w[Yes No].include?(val)

        FIRST_RUN_MATCH_PDF_LAYERS
      end

      def self.parse_lineweight_mode(value)
        return 'Ignore' if value.nil?
        choice = LINEWIDTH_CHOICES.find { |mode, label| value.to_s == mode || value.to_s == label }
        raise ArgumentError, 'Choose one of the listed Line widths options.' unless choice
        choice[0]
      end

      def self.effective_lineweight_mode(prefs)
        parse_lineweight_mode(prefs[:lineweight_mode])
      rescue ArgumentError
        'Ignore'
      end

      def self.load_prefs
        prefs = {}
        begin
          %w[last_mode last_preset scale layer_name
             group_per_page group_by_color
             import_text text_mode match_pdf_layers
             grouping_mode lineweight_mode
             page_arrangement import_mode extrude_to_3d extrude_depth_mm
             audit
          ].each do |key|
            val = Sketchup.read_default(PREF_KEY, key, nil)
            prefs[key.to_sym] = val if val
          end
          if prefs[:last_mode] && !MODES.key?(prefs[:last_mode].to_s)
            prefs[:last_mode] = 'Auto'
            Sketchup.write_default(PREF_KEY, 'last_mode', 'Auto')
          end
          if prefs[:last_preset]
            Sketchup.write_default(PREF_KEY, 'last_preset', 'Auto')
          end
        rescue StandardError => e
          Logger.warn("ImportDialog", "load_prefs failed: #{e.message}")
        end
        prefs
      end

      def self.save_prefs(hash)
        begin
          hash.each do |key, val|
            next if key.to_s == 'pages'
            stored = case key.to_s
                     when 'text_mode'
                       effective_text_mode(text_mode: val)
                     when 'match_pdf_layers'
                       effective_match_pdf_layers(match_pdf_layers: val)
                     when 'lineweight_mode'
                       effective_lineweight_mode(lineweight_mode: val)
                     else
                       val.to_s
                     end
            Sketchup.write_default(PREF_KEY, key.to_s, stored)
          end
        rescue StandardError => e
          Logger.warn("ImportDialog", "save_prefs failed: #{e.message}")
        end
      end

      def self.valid_mode_name(name)
        MODES.key?(name.to_s) ? name.to_s : 'Auto'
      end

      # The mode a dialog shows selected. 'Hybrid' is the same as Auto, so a
      # saved 'Hybrid' shows as Auto.
      def self.dialog_mode_name(name)
        mode = valid_mode_name(name)
        mode == 'Hybrid' ? 'Auto' : mode
      end

    end
  end
end
