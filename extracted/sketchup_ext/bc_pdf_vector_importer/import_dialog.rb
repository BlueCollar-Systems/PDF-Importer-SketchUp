# bc_pdf_vector_importer/import_dialog.rb
# Import dialog v6 — BCS-ARCH-001 4-mode system + Rule 5 sweep.
# HtmlDialog with Modus styling (Trimble design system).
#
# BCS-ARCH-001 Rule 5 sweep: every quality-tier dial has been removed
# from the UI. Users see exactly:
#   1. Mode selector (Auto, Vector, Raster, Hybrid)
#   2. Text rendering selector (Labels, 3D Text, Glyphs, Geometry)
#   3. Import text Yes/No toggle
# Plus legitimate workflow controls: pages, scale, grouping, page
# arrangement. Quality parameters are consolidated to the values in
# import_config.rb defaults — they are no longer adjustable.
#
# Falls back to UI.inputbox when HtmlDialog is unavailable (headless / test).
#
# Copyright 2024-2026 BlueCollar Systems — BUILT. NOT BOUGHT.

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
      TEXT_MODES   = 'Labels|3D Text|Glyphs|Geometry'

      # Workflow choices kept after the Rule 5 sweep
      GROUPING_CHOICES         = 'Single group|Group per page|Group per layer|Group per color|Nested: page > layer|Nested: page > lineweight'
      PAGE_ARRANGEMENT_CHOICES = 'Spread (20% gap)|Compact gap|Touching pages|Overlay pages'

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
          width: 440, height: 340, resizable: false
        )

        mode_val    = valid_mode_name(saved[:last_mode])
        pages_val   = saved[:pages]       || 'All'
        scale_val   = saved[:scale]       || '1.0'
        text_val    = saved[:text_mode]   || '3D Text'
        itext_val   = saved[:import_text] || 'Yes'

        dlg.set_html(basic_html(filename, mode_val, pages_val, scale_val, text_val, itext_val))

        dlg.add_action_callback('on_import') do |_ctx, p|
          mode_name   = p['mode']        || 'Auto'
          pages_str   = p['pages']       || 'All'
          scale_str   = p['scale']       || '1.0'
          text_mode   = p['text_mode']   || '3D Text'
          import_text = p['import_text'] || 'Yes'
          save_prefs(last_mode: mode_name, pages: pages_str,
                     scale: scale_str, text_mode: text_mode,
                     import_text: import_text)
          mode_raw = MODES[mode_name] || MODES['Auto']
          mode_sym = {}
          mode_raw.each { |k, v| mode_sym[k.to_sym] = v }
          result = build_opts(mode_sym.merge(pages: pages_str,
                                             scale: scale_str,
                                             text_mode: text_mode,
                                             import_text: import_text))
          dlg.close
        end

        dlg.add_action_callback('on_cancel') { |_ctx, _p| dlg.close }
        dlg.add_action_callback('on_advanced') do |_ctx, p|
          # User clicked "Advanced" — save the selected mode and open advanced dialog.
          save_prefs(last_mode: p['mode'] || 'Auto',
                     pages: p['pages']     || 'All',
                     scale: p['scale']     || '1.0',
                     text_mode: p['text_mode'] || '3D Text',
                     import_text: p['import_text'] || 'Yes')
          dlg.close
          result = show_html_advanced(filename, p['pages'] || 'All',
                                      p['scale'] || '1.0',
                                      p['text_mode'] || '3D Text',
                                      load_prefs)
        end
        dlg.show_modal
        result
      end

      # ---- HtmlDialog: Advanced (workflow only — quality dials gone) ---
      def self.show_html_advanced(filename, pages_str, scale_str, text_mode_str, saved)
        result = nil
        dlg = UI::HtmlDialog.new(
          dialog_title: "Advanced Import \u2014 #{filename}",
          preferences_key: 'BC_PDFImport_Advanced',
          width: 460, height: 380, resizable: false
        )

        d = {
          mode:             valid_mode_name(saved[:last_mode]),
          pages:            pages_str      || saved[:pages]            || 'All',
          scale:            scale_str      || saved[:scale]            || '1.0',
          text_mode:        text_mode_str  || saved[:text_mode]        || '3D Text',
          import_text:      saved[:import_text]                        || 'Yes',
          grouping_mode:    saved[:grouping_mode]                      || 'Group per page',
          page_arrangement: saved[:page_arrangement]                   || 'Spread (20% gap)',
        }

        dlg.set_html(advanced_html(filename, d))

        dlg.add_action_callback('on_import') do |_ctx, p|
          save_prefs(
            last_mode: p['mode'],
            pages: p['pages'], scale: p['scale'],
            text_mode: p['text_mode'], import_text: p['import_text'],
            grouping_mode: p['grouping_mode'],
            page_arrangement: p['page_arrangement']
          )
          mode_raw = MODES[p['mode'] || 'Auto'] || MODES['Auto']
          result = build_opts(
            import_mode: mode_raw['import_mode'],
            pages: p['pages'], scale: p['scale'],
            layer_name: 'PDF Import',
            group_per_page: 'Yes',
            group_by_color: 'Yes',
            text_mode: p['text_mode'],
            import_text: p['import_text'],
            grouping_mode: p['grouping_mode'],
            page_arrangement: p['page_arrangement']
          )
          dlg.close
        end

        dlg.add_action_callback('on_cancel') { |_ctx, _p| dlg.close }
        dlg.show_modal
        result
      end

      # ---- HTML generators ------------------------------------------
      DIALOG_CSS = <<-CSS.freeze
        *{box-sizing:border-box;margin:0;padding:0}
        body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Helvetica,Arial,sans-serif;
             font-size:13px;color:#1a1a1a;background:#fff;padding:20px}
        h2{font-size:14px;font-weight:600;margin-bottom:4px}
        .sub{font-size:11px;color:#666;margin-bottom:16px;
             white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
        label{display:block;font-size:12px;font-weight:500;color:#444;margin-bottom:3px}
        select,input[type=text]{width:100%;border:1px solid #ccc;border-radius:3px;
            padding:6px 8px;font-size:13px;color:#1a1a1a;background:#fff;outline:none}
        select:focus,input:focus{border-color:#0078d7}
        .row{margin-bottom:12px}
        .row2{display:grid;grid-template-columns:1fr 1fr;gap:10px;margin-bottom:10px}
        .section{border-top:1px solid #e4e4e4;padding-top:10px;margin-top:4px;
                 font-size:11px;font-weight:600;color:#888;text-transform:uppercase;
                 letter-spacing:.6px;margin-bottom:8px}
        .actions{display:flex;justify-content:flex-end;gap:8px;margin-top:16px;
                 padding-top:14px;border-top:1px solid #e4e4e4}
        .btn{padding:7px 18px;border-radius:3px;font-size:13px;
             font-weight:500;cursor:pointer;border:1px solid transparent}
        .btn-primary{background:#0078d7;color:#fff;border-color:#0078d7}
        .btn-primary:hover{background:#005fa3}
        .btn-secondary{background:#fff;color:#333;border-color:#ccc}
        .btn-secondary:hover{background:#f3f3f3}
        .hint{font-size:11px;color:#888;margin-top:2px}
      CSS

      def self.basic_html(filename, mode, pages, scale, text_mode, import_text)
        mode_opts = MODES.keys.map { |m|
          sel = m == mode ? ' selected' : ''
          "<option value=\"#{esc(m)}\"#{sel}>#{esc(m)}</option>"
        }.join

        text_opts = [
          ['Labels',   'Labels'],
          ['3D Text',  '3D Text'],
          ['Glyphs',   'Glyphs'],
          ['Geometry', 'Geometry']
        ].map { |v, label|
          sel = v == text_mode ? ' selected' : ''
          "<option value=\"#{v}\"#{sel}>#{label}</option>"
        }.join

        itext_yes = import_text == 'Yes' ? ' selected' : ''
        itext_no  = import_text == 'No'  ? ' selected' : ''

        <<-HTML
          <!DOCTYPE html><html><head><meta charset="utf-8">
          <style>#{DIALOG_CSS}</style></head><body>
          <h2>Import PDF Vectors</h2>
          <p class="sub">#{esc(filename)}</p>
          <div class="row"><label>Mode</label>
            <select id="mode">#{mode_opts}</select>
            <p class="hint">Maximum fidelity in every mode. Auto picks per page &bull; Vector &bull; Raster &bull; Hybrid (vectors + embedded images)</p>
          </div>
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
          <div class="actions">
            <button class="btn btn-secondary" onclick="cancel()">Cancel</button>
            <button class="btn btn-secondary" onclick="advanced()">Advanced...</button>
            <button class="btn btn-primary" onclick="doImport()">Import</button>
          </div>
          <script>
          function payload(){return {
            mode:document.getElementById('mode').value,
            pages:document.getElementById('pages').value.trim()||'All',
            scale:document.getElementById('scale').value.trim()||'1.0',
            import_text:document.getElementById('import_text').value,
            text_mode:document.getElementById('text_mode').value};}
          function doImport(){sketchup.on_import(payload());}
          function advanced(){sketchup.on_advanced(payload());}
          function cancel(){sketchup.on_cancel({});}
          document.addEventListener('keydown',function(e){
            if(e.key==='Enter')doImport();
            if(e.key==='Escape')cancel();});
          </script></body></html>
        HTML
      end

      def self.advanced_html(filename, d)
        mode_opts = MODES.keys.map { |m|
          sel = d[:mode] == m ? ' selected' : ''
          "<option value=\"#{esc(m)}\"#{sel}>#{esc(m)}</option>"
        }.join

        text_opts = [['Labels','Labels'],['3D Text','3D Text'],['Glyphs','Glyphs'],['Geometry','Geometry']].map{|v,lbl|
          sel = d[:text_mode] == v ? ' selected' : ''
          "<option value=\"#{v}\"#{sel}>#{lbl}</option>"
        }.join

        yn = lambda { |key|
          yes = d[key] == 'Yes' ? ' selected' : ''
          no  = d[key] == 'No'  ? ' selected' : ''
          "<option value=\"Yes\"#{yes}>Yes</option><option value=\"No\"#{no}>No</option>"
        }

        grouping_opts = GROUPING_CHOICES.split('|').map{|v|
          sel = d[:grouping_mode] == v ? ' selected' : ''
          "<option value=\"#{esc(v)}\"#{sel}>#{esc(v)}</option>"
        }.join

        page_arrangement_opts = PAGE_ARRANGEMENT_CHOICES.split('|').map{|v|
          sel = d[:page_arrangement] == v ? ' selected' : ''
          "<option value=\"#{esc(v)}\"#{sel}>#{esc(v)}</option>"
        }.join

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
          <div class="row2">
            <div><label>Scale Factor</label>
              <input type="text" id="scale" value="#{esc(d[:scale])}" placeholder="1.0"></div>
          </div>
          <div class="section">Text</div>
          <div class="row2">
            <div><label>Import Text</label>
              <select id="import_text">#{yn.call(:import_text)}</select></div>
            <div><label>Text Rendering</label>
              <select id="text_mode">#{text_opts}</select></div>
          </div>
          <div class="section">Layout</div>
          <div class="row2">
            <div><label>Grouping Mode</label>
              <select id="grouping_mode">#{grouping_opts}</select></div>
            <div><label>Page Arrangement</label>
              <select id="page_arrangement">#{page_arrangement_opts}</select></div>
          </div>
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
            grouping_mode:document.getElementById('grouping_mode').value,
            page_arrangement:document.getElementById('page_arrangement').value});}
          function cancel(){sketchup.on_cancel({});}
          document.addEventListener('keydown',function(e){if(e.key==='Escape')cancel();});
          </script></body></html>
        HTML
      end

      def self.esc(str)
        str.to_s.gsub('&','&amp;').gsub('"','&quot;').gsub("'",'&#39;').gsub('<','&lt;').gsub('>','&gt;')
      end

      # ---- UI.inputbox fallbacks (headless / pre-2017 SU) ----------
      def self.show_inputbox_basic(filename, saved)
        prompts   = ["Mode:","Pages (1, 1-5, or All):","Scale Factor:",
                     "Import Text:","Text Rendering:"]
        last_m    = valid_mode_name(saved[:last_mode])
        defaults  = [last_m, saved[:pages]||'All', saved[:scale]||'1.0',
                     saved[:import_text]||'Yes', saved[:text_mode]||'3D Text']
        dropdowns = [MODE_NAMES, '', '', YES_NO, TEXT_MODES]
        result = UI.inputbox(prompts, defaults, dropdowns, "Import PDF \u2014 #{filename}")
        return nil unless result
        mode_name, pages_str, scale_str, import_text_str, text_mode_str = result
        save_prefs(last_mode: mode_name, pages: pages_str,
                   scale: scale_str, import_text: import_text_str,
                   text_mode: text_mode_str)
        mode_raw = MODES[mode_name] || MODES['Auto']
        sym_attrs = {}
        mode_raw.each { |k, v| sym_attrs[k.to_sym] = v }
        build_opts(sym_attrs.merge(pages: pages_str, scale: scale_str,
                                   import_text: import_text_str,
                                   text_mode: text_mode_str))
      end

      def self.show_inputbox_advanced(filename, pages_str, scale_str, text_mode_str, saved)
        prompts = [
          "Mode:","Pages:","Scale Factor:",
          "Import Text:","Text Rendering:",
          "Grouping Mode:","Page Arrangement:"
        ]
        defaults = [
          valid_mode_name(saved[:last_mode]),
          pages_str||saved[:pages]||'All', scale_str||saved[:scale]||'1.0',
          saved[:import_text]||'Yes',
          text_mode_str||saved[:text_mode]||'3D Text',
          saved[:grouping_mode]||'Group per page',
          saved[:page_arrangement]||'Spread (20% gap)'
        ]
        dropdowns = [MODE_NAMES,'','',YES_NO,TEXT_MODES,GROUPING_CHOICES,PAGE_ARRANGEMENT_CHOICES]
        result = UI.inputbox(prompts, defaults, dropdowns, "Advanced Import \u2014 #{filename}")
        return nil unless result
        p_mode,p_pages,p_scale,p_import_text,p_text_mode,
        p_grouping_mode,p_page_arrangement = result
        save_prefs(last_mode:p_mode,pages:p_pages,scale:p_scale,
                   import_text:p_import_text,text_mode:p_text_mode,
                   grouping_mode:p_grouping_mode,
                   page_arrangement:p_page_arrangement)
        mode_raw = MODES[p_mode] || MODES['Auto']
        build_opts(import_mode:mode_raw['import_mode'],
                   pages:p_pages,scale:p_scale,
                   layer_name:'PDF Import',
                   group_per_page:'Yes',
                   group_by_color:'Yes',
                   import_text:p_import_text,text_mode:p_text_mode,
                   grouping_mode:p_grouping_mode,
                   page_arrangement:p_page_arrangement)
      end

      private

      def self.build_opts(raw)
        scale = (raw[:scale] || '1.0').to_f
        scale = 1.0 if scale <= 0
        case (raw[:units] || '')
        when /Feet/i   then scale *= 12.0
        when /Points/i then scale /= 72.0
        end

        pages_str = (raw[:pages] || 'All').strip
        if pages_str.downcase == 'all' || pages_str.empty?
          pages = :all
        else
          pages = []
          pages_str.split(/[,;\s]+/).each do |part|
            if part =~ /\A(\d+)\s*-\s*(\d+)\z/
              ($1.to_i..$2.to_i).each { |p| pages << p }
            else
              p = part.to_i; pages << p if p > 0
            end
          end
          pages = pages.uniq.sort
          pages = :all if pages.empty?
        end

        # BCS-ARCH-001 text resolver: Labels|3D Text|Glyphs|Geometry
        # Import Text checkbox is the orthogonal on/off control.
        import_text_flag = (raw[:import_text] || 'Yes') == 'Yes'
        text_mode_raw = (raw[:text_mode] || '3D Text').to_s
        text_mode = case text_mode_raw
                    when /No text/i           then :labels   # legacy string — treated as labels, gated by import_text_flag
                    when /\A3D\s*Text\z/i     then :text3d
                    when /Glyphs/i            then :glyphs
                    when /Geometry/i          then :geometry
                    else                            :labels
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

        # Consolidated defaults (BCS-ARCH-001 Rule 5 — every mode targets
        # identical "indistinguishable from source" quality; quality dials
        # are never user-adjustable). These values come from the
        # parameter table in import_config.rb.
        {
          scale:            scale,
          pages:            pages,
          bezier_segments:  32,
          import_as:        is_raster ? :edges : :both,
          layer_name:       (raw[:layer_name] || 'PDF Import').to_s.strip,
          group_per_page:   (raw[:group_per_page] || 'Yes') == 'Yes',
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
          raster_fallback:  (mode_str == 'auto' || mode_str == 'hybrid' || is_raster),
          force_raster:     is_raster,
          raster_dpi:       300,
          page_arrangement: (raw[:page_arrangement] || 'Spread (20% gap)').to_s,
          page_gap_ratio:   0.20,
          cleanup_geometry: true,
          recognition_mode: :auto,
          arc_mode:         'Auto',
          cleanup_level:    'Balanced',
          lineweight_mode:  is_raster ? 'Ignore' : 'Preserve visually',
          grouping_mode:    (raw[:grouping_mode] || 'Group per page').to_s,
          import_mode:      mode_str
        }
      end

      PREF_KEY = 'BlueCollarSystems_PDFVectorImporter'.freeze
      PREF_MIGRATE_TEXT_DEFAULT_KEY = 'text_mode_default_migrated_v372'.freeze

      def self.load_prefs
        prefs = {}
        begin
          %w[last_mode last_preset pages scale layer_name
             group_per_page group_by_color
             import_text text_mode
             grouping_mode
             page_arrangement import_mode
          ].each do |key|
            val = Sketchup.read_default(PREF_KEY, key, nil)
            prefs[key.to_sym] = val if val
          end
          # v3.7.2: migrate the old Labels default once. SketchUp labels are
          # screen-facing annotations, so dense steel sheets can look wildly
          # oversized compared with the PDF. Users can still choose Labels
          # after migration; the flag prevents repeated overrides.
          migrated = Sketchup.read_default(PREF_KEY, PREF_MIGRATE_TEXT_DEFAULT_KEY, nil)
          if prefs[:text_mode].to_s == 'Labels' && migrated.to_s != 'Yes'
            prefs[:text_mode] = '3D Text'
            Sketchup.write_default(PREF_KEY, 'text_mode', '3D Text')
            Sketchup.write_default(PREF_KEY, PREF_MIGRATE_TEXT_DEFAULT_KEY, 'Yes')
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
          hash.each { |key, val| Sketchup.write_default(PREF_KEY, key.to_s, val.to_s) }
        rescue StandardError => e
          Logger.warn("ImportDialog", "save_prefs failed: #{e.message}")
        end
      end

      def self.valid_mode_name(name)
        MODES.key?(name.to_s) ? name.to_s : 'Auto'
      end

    end
  end
end
