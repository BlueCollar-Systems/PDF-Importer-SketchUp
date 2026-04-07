# bc_pdf_vector_importer/import_dialog.rb
# Import dialog v4 — HtmlDialog with Modus styling (Trimble design system).
# Basic and Advanced modes, preset profiles, plain-English labels.
#
# Falls back to UI.inputbox when HtmlDialog is unavailable (headless / test).
#
# Copyright 2024-2026 BlueCollar Systems — BUILT. NOT BOUGHT.

module BlueCollarSystems
  module PDFVectorImporter
    module ImportDialog

      PRESETS = {
        'Fast' => {
          scale: '1.0', bezier_segments: '8', import_as: 'Edges Only',
          import_fills: 'No', group_by_color: 'No', detect_arcs: 'No',
          map_dashes: 'No', text_mode: 'No text', hatch_mode: 'Skip',
          strict_text_fidelity: 'No',
          cleanup_geometry: 'No', recognition_mode: 'None',
          merge_tolerance: '0.005', units: 'Inches',
          force_raster: 'No', raster_dpi: '300'
        },
        'Full' => {
          scale: '1.0', bezier_segments: '24', import_as: 'Edges and Faces',
          import_fills: 'Yes', group_by_color: 'Yes', detect_arcs: 'Yes',
          map_dashes: 'Yes', text_mode: 'Geometry', hatch_mode: 'Group',
          strict_text_fidelity: 'No',
          cleanup_geometry: 'Yes', recognition_mode: 'None',
          merge_tolerance: '0.001', units: 'Inches',
          force_raster: 'No', raster_dpi: '300'
        },
        'Raster Image' => {
          scale: '1.0', bezier_segments: '8', import_as: 'Edges Only',
          import_fills: 'No', group_by_color: 'No', detect_arcs: 'No',
          map_dashes: 'No', text_mode: 'No text', hatch_mode: 'Skip',
          strict_text_fidelity: 'No',
          cleanup_geometry: 'No', recognition_mode: 'None',
          merge_tolerance: '0.005', units: 'Inches',
          force_raster: 'Yes', raster_dpi: '300'
        },
        'Custom...' => nil
      }.freeze

      YES_NO       = 'Yes|No'
      PRESET_NAMES = PRESETS.keys.join('|')
      TEXT_MODES   = 'Labels|3D Text|Geometry|No text'
      HATCH_MODES  = 'Import|Group|Skip'

      # Phase 2 dropdown choices
      ARC_MODE_CHOICES       = 'Auto|Preserve curves|Rebuild arcs|Polyline only'
      CLEANUP_LEVEL_CHOICES  = 'Conservative|Balanced|Aggressive'
      LINEWEIGHT_CHOICES     = 'Ignore|Preserve visually|Group by lineweight|Map to tags'
      GROUPING_CHOICES       = 'Single group|Group per page|Group per layer|Group per color|Nested: page > layer|Nested: page > lineweight'

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
          width: 440, height: 310, resizable: false
        )

        preset    = saved[:last_preset] || 'Full'
        pages_val = saved[:pages]       || 'All'
        scale_val = saved[:scale]       || '1.0'
        text_val  = saved[:text_mode]   || 'Labels'

        dlg.set_html(basic_html(filename, preset, pages_val, scale_val, text_val))

        dlg.add_action_callback('on_import') do |_ctx, p|
          preset_name = p['preset']    || 'Full'
          pages_str   = p['pages']     || 'All'
          scale_str   = p['scale']     || '1.0'
          text_mode   = p['text_mode'] || 'Labels'
          save_prefs(last_preset: preset_name, pages: pages_str,
                     scale: scale_str, text_mode: text_mode)
          if preset_name == 'Custom...'
            dlg.close
            result = show_html_advanced(filename, pages_str, scale_str,
                                        text_mode, load_prefs)
          else
            pr = PRESETS[preset_name] || PRESETS['Full']
            result = build_opts(pr.merge(pages: pages_str, scale: scale_str,
                                         text_mode: text_mode))
            dlg.close
          end
        end

        dlg.add_action_callback('on_cancel') { |_ctx, _p| dlg.close }
        dlg.show_modal
        result
      end

      # ---- HtmlDialog: Advanced -------------------------------------
      def self.show_html_advanced(filename, pages_str, scale_str, text_mode_str, saved)
        result = nil
        dlg = UI::HtmlDialog.new(
          dialog_title: "Custom Import \u2014 #{filename}",
          preferences_key: 'BC_PDFImport_Advanced',
          width: 480, height: 560, resizable: true
        )

        d = {
          pages:            pages_str      || saved[:pages]            || 'All',
          scale:            scale_str      || saved[:scale]            || '1.0',
          bezier_segments:  saved[:bezier_segments]                    || '24',
          text_mode:        text_mode_str  || saved[:text_mode]        || 'Geometry',
          hatch_mode:       saved[:hatch_mode]                         || 'Group',
          strict_text_fidelity: saved[:strict_text_fidelity]           || 'No',
          detect_arcs:      saved[:detect_arcs]                        || 'Yes',
          map_dashes:       saved[:map_dashes]                         || 'Yes',
          import_fills:     saved[:import_fills]                       || 'Yes',
          cleanup_geometry: saved[:cleanup_geometry]                   || 'Yes',
          force_raster:     saved[:force_raster]                       || 'No',
          raster_dpi:       saved[:raster_dpi]                         || '300',
          arc_mode:         saved[:arc_mode]                           || 'Auto',
          cleanup_level:    saved[:cleanup_level]                      || 'Balanced',
          lineweight_mode:  saved[:lineweight_mode]                    || 'Ignore',
          grouping_mode:    saved[:grouping_mode]                      || 'Group per page'
        }

        dlg.set_html(advanced_html(filename, d))

        dlg.add_action_callback('on_import') do |_ctx, p|
          save_prefs(
            pages: p['pages'], scale: p['scale'],
            bezier_segments: p['bezier_segments'],
            text_mode: p['text_mode'], hatch_mode: p['hatch_mode'],
            strict_text_fidelity: p['strict_text_fidelity'],
            detect_arcs: p['detect_arcs'], map_dashes: p['map_dashes'],
            import_fills: p['import_fills'],
            cleanup_geometry: p['cleanup_geometry'],
            force_raster: p['force_raster'], raster_dpi: p['raster_dpi'],
            arc_mode: p['arc_mode'], cleanup_level: p['cleanup_level'],
            lineweight_mode: p['lineweight_mode'], grouping_mode: p['grouping_mode'],
            last_preset: 'Custom...'
          )
          import_as = p['import_fills'] == 'Yes' ? 'Edges and Faces' : 'Edges Only'
          result = build_opts(
            pages: p['pages'], scale: p['scale'],
            bezier_segments: p['bezier_segments'],
            import_as: import_as, layer_name: 'PDF Import',
            group_per_page: 'Yes', import_fills: p['import_fills'],
            group_by_color: 'Yes', detect_arcs: p['detect_arcs'],
            map_dashes: p['map_dashes'], text_mode: p['text_mode'],
            hatch_mode: p['hatch_mode'], strict_text_fidelity: p['strict_text_fidelity'],
            raster_fallback: 'Yes', cleanup_geometry: p['cleanup_geometry'],
            force_raster: p['force_raster'], raster_dpi: p['raster_dpi'],
            recognition_mode: 'None', merge_tolerance: '0.001', units: 'Inches',
            arc_mode: p['arc_mode'], cleanup_level: p['cleanup_level'],
            lineweight_mode: p['lineweight_mode'], grouping_mode: p['grouping_mode']
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

      def self.basic_html(filename, preset, pages, scale, text_mode)
        preset_opts = PRESETS.keys.map { |p|
          sel = p == preset ? ' selected' : ''
          "<option value=\"#{esc(p)}\"#{sel}>#{esc(p)}</option>"
        }.join

        text_opts = [
          ['Labels', 'Labels'],
          ['3D Text', '3D Text'],
          ['Geometry', 'Geometry'],
          ['No text', 'No text']
        ].map { |v, label|
          sel = v == text_mode ? ' selected' : ''
          "<option value=\"#{v}\"#{sel}>#{label}</option>"
        }.join

        <<-HTML
          <!DOCTYPE html><html><head><meta charset="utf-8">
          <style>#{DIALOG_CSS}</style></head><body>
          <h2>Import PDF Vectors</h2>
          <p class="sub">#{esc(filename)}</p>
          <div class="row"><label>Preset</label>
            <select id="preset">#{preset_opts}</select></div>
          <div class="row"><label>Pages</label>
            <input type="text" id="pages" value="#{esc(pages)}" placeholder="All">
            <p class="hint">e.g. All &nbsp;&bull;&nbsp; 1 &nbsp;&bull;&nbsp; 2-5 &nbsp;&bull;&nbsp; 1,3,7</p>
          </div>
          <div class="row"><label>Scale Factor</label>
            <input type="text" id="scale" value="#{esc(scale)}" placeholder="1.0"></div>
          <div class="row"><label>Import Text</label>
            <select id="text_mode">#{text_opts}</select></div>
          <div class="actions">
            <button class="btn btn-secondary" onclick="cancel()">Cancel</button>
            <button class="btn btn-primary" onclick="doImport()">Import</button>
          </div>
          <script>
          function doImport(){sketchup.on_import({
            preset:document.getElementById('preset').value,
            pages:document.getElementById('pages').value.trim()||'All',
            scale:document.getElementById('scale').value.trim()||'1.0',
            text_mode:document.getElementById('text_mode').value});}
          function cancel(){sketchup.on_cancel({});}
          document.addEventListener('keydown',function(e){
            if(e.key==='Enter')doImport();
            if(e.key==='Escape')cancel();});
          </script></body></html>
        HTML
      end

      def self.advanced_html(filename, d)
        yn = lambda { |key|
          yes = d[key] == 'Yes' ? ' selected' : ''
          no  = d[key] == 'No'  ? ' selected' : ''
          "<option value=\"Yes\"#{yes}>Yes</option><option value=\"No\"#{no}>No</option>"
        }

        text_opts = [['Labels','Labels'],['3D Text','3D Text'],['Geometry','Geometry'],['No text','No text']].map{|v,lbl|
          sel = d[:text_mode] == v ? ' selected' : ''
          "<option value=\"#{v}\"#{sel}>#{lbl}</option>"
        }.join

        hatch_opts = [['Import','Import'],['Group','Group'],['Skip','Skip']].map{|v,lbl|
          sel = d[:hatch_mode] == v ? ' selected' : ''
          "<option value=\"#{v}\"#{sel}>#{lbl}</option>"
        }.join

        arc_mode_opts = ARC_MODE_CHOICES.split('|').map{|v|
          sel = d[:arc_mode] == v ? ' selected' : ''
          "<option value=\"#{esc(v)}\"#{sel}>#{esc(v)}</option>"
        }.join

        cleanup_level_opts = CLEANUP_LEVEL_CHOICES.split('|').map{|v|
          sel = d[:cleanup_level] == v ? ' selected' : ''
          "<option value=\"#{esc(v)}\"#{sel}>#{esc(v)}</option>"
        }.join

        lineweight_opts = LINEWEIGHT_CHOICES.split('|').map{|v|
          sel = d[:lineweight_mode] == v ? ' selected' : ''
          "<option value=\"#{esc(v)}\"#{sel}>#{esc(v)}</option>"
        }.join

        grouping_opts = GROUPING_CHOICES.split('|').map{|v|
          sel = d[:grouping_mode] == v ? ' selected' : ''
          "<option value=\"#{esc(v)}\"#{sel}>#{esc(v)}</option>"
        }.join

        <<-HTML
          <!DOCTYPE html><html><head><meta charset="utf-8">
          <style>#{DIALOG_CSS}body{overflow-y:auto}</style></head><body>
          <h2>Custom Import Settings</h2>
          <p class="sub">#{esc(filename)}</p>
          <div class="row2">
            <div><label>Pages</label>
              <input type="text" id="pages" value="#{esc(d[:pages])}" placeholder="All"></div>
            <div><label>Scale Factor</label>
              <input type="text" id="scale" value="#{esc(d[:scale])}" placeholder="1.0"></div>
          </div>
          <div class="section">Geometry</div>
          <div class="row2">
            <div><label>Curve Smoothness</label>
              <input type="text" id="bezier_segments" value="#{esc(d[:bezier_segments])}" placeholder="24">
              <p class="hint">4=fast &bull; 48=smooth</p></div>
            <div><label>Rebuild Arcs</label>
              <select id="detect_arcs">#{yn.call(:detect_arcs)}</select></div>
          </div>
          <div class="row2">
            <div><label>Import Filled Regions</label>
              <select id="import_fills">#{yn.call(:import_fills)}</select></div>
            <div><label>Auto-Clean Geometry</label>
              <select id="cleanup_geometry">#{yn.call(:cleanup_geometry)}</select></div>
          </div>
          <div class="section">Styling</div>
          <div class="row2">
            <div><label>Map Dashed Lines</label>
              <select id="map_dashes">#{yn.call(:map_dashes)}</select></div>
          </div>
          <div class="section">Text &amp; Hatching</div>
          <div class="row2">
            <div><label>Import Text</label>
              <select id="text_mode">#{text_opts}</select></div>
            <div><label>Hatching</label>
              <select id="hatch_mode">#{hatch_opts}</select></div>
          </div>
          <div class="row2">
            <div><label>Strict Text Fidelity</label>
              <select id="strict_text_fidelity">#{yn.call(:strict_text_fidelity)}</select>
              <p class="hint">Preserve exact extracted text spans; disables aggressive text cleanup.</p>
            </div>
          </div>
          <div class="section">Advanced Controls</div>
          <div class="row2">
            <div><label>Arc Mode</label>
              <select id="arc_mode">#{arc_mode_opts}</select></div>
            <div><label>Cleanup Level</label>
              <select id="cleanup_level">#{cleanup_level_opts}</select></div>
          </div>
          <div class="row2">
            <div><label>Lineweight Handling</label>
              <select id="lineweight_mode">#{lineweight_opts}</select></div>
            <div><label>Grouping Mode</label>
              <select id="grouping_mode">#{grouping_opts}</select></div>
          </div>
          <div class="section">Raster Fallback</div>
          <div class="row2">
            <div><label>Force Raster</label>
              <select id="force_raster">#{yn.call(:force_raster)}</select></div>
            <div><label>Raster DPI (200&ndash;600)</label>
              <input type="text" id="raster_dpi" value="#{esc(d[:raster_dpi])}" placeholder="300"></div>
          </div>
          <div class="actions">
            <button class="btn btn-secondary" onclick="cancel()">Cancel</button>
            <button class="btn btn-primary" onclick="doImport()">Import</button>
          </div>
          <script>
          function doImport(){sketchup.on_import({
            pages:document.getElementById('pages').value.trim()||'All',
            scale:document.getElementById('scale').value.trim()||'1.0',
            bezier_segments:document.getElementById('bezier_segments').value.trim()||'24',
            text_mode:document.getElementById('text_mode').value,
            hatch_mode:document.getElementById('hatch_mode').value,
            strict_text_fidelity:document.getElementById('strict_text_fidelity').value,
            detect_arcs:document.getElementById('detect_arcs').value,
            map_dashes:document.getElementById('map_dashes').value,
            import_fills:document.getElementById('import_fills').value,
            cleanup_geometry:document.getElementById('cleanup_geometry').value,
            force_raster:document.getElementById('force_raster').value,
            raster_dpi:document.getElementById('raster_dpi').value.trim()||'300',
            arc_mode:document.getElementById('arc_mode').value,
            cleanup_level:document.getElementById('cleanup_level').value,
            lineweight_mode:document.getElementById('lineweight_mode').value,
            grouping_mode:document.getElementById('grouping_mode').value});}
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
        prompts   = ["Preset:","Pages (1, 1-5, or All):","Scale Factor:","Import Text:"]
        last_p    = saved[:last_preset] || 'Full'
        defaults  = [last_p, saved[:pages]||'All', saved[:scale]||'1.0', saved[:text_mode]||'Labels']
        dropdowns = [PRESET_NAMES, '', '', TEXT_MODES]
        result = UI.inputbox(prompts, defaults, dropdowns, "Import PDF \u2014 #{filename}")
        return nil unless result
        preset_name, pages_str, scale_str, text_mode_str = result
        save_prefs(last_preset: preset_name, pages: pages_str,
                   scale: scale_str, text_mode: text_mode_str)
        return show_inputbox_advanced(filename, pages_str, scale_str, text_mode_str, saved) \
          if preset_name == 'Custom...'
        pr = PRESETS[preset_name] || PRESETS['Full']
        build_opts(pr.merge(pages: pages_str, scale: scale_str, text_mode: text_mode_str))
      end

      def self.show_inputbox_advanced(filename, pages_str, scale_str, text_mode_str, saved)
        prompts = [
          "Pages:","Scale Factor:","Curve Smoothness (4=fast, 48=smooth):",
          "Import Text:","Hatchings:","Strict Text Fidelity:",
          "Rebuild Arcs from Curves:",
          "Map Dashed/Hidden Lines:","Import Filled Regions:",
          "Auto-Clean Geometry:","Force Raster Image (skip vectors):","Raster DPI (200-600):",
          "Arc Mode:","Cleanup Level:","Lineweight Handling:","Grouping Mode:"
        ]
        defaults = [
          pages_str||saved[:pages]||'All', scale_str||saved[:scale]||'1.0',
          saved[:bezier_segments]||'24',
          text_mode_str||saved[:text_mode]||'Geometry',
          saved[:hatch_mode]||'Group', saved[:strict_text_fidelity]||'No',
          saved[:detect_arcs]||'Yes',
          saved[:map_dashes]||'Yes',   saved[:import_fills]||'Yes',
          saved[:cleanup_geometry]||'Yes', saved[:force_raster]||'No',
          saved[:raster_dpi]||'300',
          saved[:arc_mode]||'Auto', saved[:cleanup_level]||'Balanced',
          saved[:lineweight_mode]||'Ignore', saved[:grouping_mode]||'Group per page'
        ]
        dropdowns = ['','','',TEXT_MODES,HATCH_MODES,YES_NO,YES_NO,YES_NO,YES_NO,YES_NO,YES_NO,'',
                     ARC_MODE_CHOICES,CLEANUP_LEVEL_CHOICES,LINEWEIGHT_CHOICES,GROUPING_CHOICES]
        result = UI.inputbox(prompts, defaults, dropdowns, "Custom Import \u2014 #{filename}")
        return nil unless result
        p_pages,p_scale,p_bezier,p_text_mode,p_hatch,p_strict_text,
        p_arcs,p_dashes,p_fills,p_cleanup,p_force_raster,p_raster_dpi,
        p_arc_mode,p_cleanup_level,p_lineweight_mode,p_grouping_mode = result
        save_prefs(pages:p_pages,scale:p_scale,bezier_segments:p_bezier,
                   text_mode:p_text_mode,hatch_mode:p_hatch,
                   strict_text_fidelity:p_strict_text,
                   detect_arcs:p_arcs,map_dashes:p_dashes,import_fills:p_fills,
                   cleanup_geometry:p_cleanup,force_raster:p_force_raster,
                   raster_dpi:p_raster_dpi,arc_mode:p_arc_mode,
                   cleanup_level:p_cleanup_level,lineweight_mode:p_lineweight_mode,
                   grouping_mode:p_grouping_mode,last_preset:'Custom...')
        import_as = p_fills == 'Yes' ? 'Edges and Faces' : 'Edges Only'
        build_opts(pages:p_pages,scale:p_scale,bezier_segments:p_bezier,
                   import_as:import_as,layer_name:'PDF Import',
                   group_per_page:'Yes',import_fills:p_fills,
                   group_by_color:'Yes',detect_arcs:p_arcs,
                   map_dashes:p_dashes,text_mode:p_text_mode,hatch_mode:p_hatch,
                   strict_text_fidelity:p_strict_text,
                   raster_fallback:'Yes',cleanup_geometry:p_cleanup,
                   force_raster:p_force_raster,raster_dpi:p_raster_dpi,
                   recognition_mode:'None',merge_tolerance:'0.001',units:'Inches',
                   arc_mode:p_arc_mode,cleanup_level:p_cleanup_level,
                   lineweight_mode:p_lineweight_mode,grouping_mode:p_grouping_mode)
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

        bezier = (raw[:bezier_segments] || '16').to_i
        bezier = [[bezier, 4].max, 64].min

        import_mode = case (raw[:import_as] || '')
                      when /Faces Only/i      then :faces
                      when /Edges and Faces/i then :both
                      else :edges
                      end

        recog = case (raw[:recognition_mode] || '')
                when /None/i    then :none
                when /Generic/i then :generic
                else :auto
                end

        text_mode_raw = (raw[:text_mode] || 'Labels').to_s
        text_mode = if text_mode_raw =~ /No text/i
                      :none
                    elsif text_mode_raw =~ /\A3D\s*Text\z/i
                      :text3d
                    elsif text_mode_raw =~ /Geometry/i
                      :geometry
                    else
                      :labels
                    end
        import_text = (text_mode != :none)
        use_3d_text = (text_mode == :text3d)

        hatch = case (raw[:hatch_mode] || 'Group')
                when /Skip/i  then :skip
                when /Group/i then :group
                else :import
                end

        {
          scale:            scale,
          pages:            pages,
          bezier_segments:  bezier,
          import_as:        import_mode,
          layer_name:       (raw[:layer_name] || 'PDF Import').to_s.strip,
          group_per_page:   (raw[:group_per_page] || 'Yes') == 'Yes',
          flatten_to_2d:    true,
          merge_tolerance:  (raw[:merge_tolerance] || '0.001').to_f.abs,
          import_fills:     (raw[:import_fills] || 'Yes') == 'Yes',
          group_by_color:   (raw[:group_by_color] || 'Yes') == 'Yes',
          detect_arcs:      (raw[:detect_arcs] || 'Yes') == 'Yes',
          map_dashes:       (raw[:map_dashes] || 'Yes') == 'Yes',
          import_text:      import_text,
          text_mode:        text_mode,
          strict_text_fidelity: (raw[:strict_text_fidelity] || 'No') == 'Yes',
          use_3d_text:      use_3d_text,
          hatch_mode:       hatch,
          raster_fallback:  (raw[:raster_fallback] || 'Yes') == 'Yes',
          force_raster:     (raw[:force_raster] || 'No') == 'Yes',
          raster_dpi:       [[((raw[:raster_dpi] || '300').to_i), 200].max, 600].min,
          cleanup_geometry: (raw[:cleanup_geometry] || 'Yes') == 'Yes',
          recognition_mode: recog,
          arc_mode:         (raw[:arc_mode] || 'Auto').to_s,
          cleanup_level:    (raw[:cleanup_level] || 'Balanced').to_s,
          lineweight_mode:  (raw[:lineweight_mode] || 'Ignore').to_s,
          grouping_mode:    (raw[:grouping_mode] || 'Group per page').to_s
        }
      end

      PREF_KEY = 'BlueCollarSystems_PDFVectorImporter'.freeze

      def self.load_prefs
        prefs = {}
        begin
          %w[last_preset pages scale bezier_segments import_as layer_name
             group_per_page import_fills group_by_color detect_arcs
             map_dashes text_mode strict_text_fidelity hatch_mode raster_fallback force_raster
             raster_dpi cleanup_geometry recognition_mode merge_tolerance units
             arc_mode cleanup_level lineweight_mode grouping_mode
          ].each do |key|
            val = Sketchup.read_default(PREF_KEY, key, nil)
            prefs[key.to_sym] = val if val
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

    end
  end
end
