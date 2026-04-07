# bc_pdf_vector_importer/scale_tool.rb
# Scale by Reference — pick an edge, type the real-world dimension,
# and all imported geometry scales to match.
#
# Also provides Quick Scale for typing a factor or ratio directly.
#
# Mirrors the FreeCAD PDFScaleTool functionality.
#
# Copyright 2024-2026 BlueCollar Systems — BUILT. NOT BOUGHT.

module BlueCollarSystems
  module PDFVectorImporter
    module ScaleTool

      # ---------------------------------------------------------------
      # Scale by Reference — selection-based workflow
      # ---------------------------------------------------------------
      def self.activate
        model = Sketchup.active_model
        unless model
          UI.messagebox("No active model.")
          return
        end

        sel = model.selection
        edge = nil

        # Look for a selected edge
        sel.each do |e|
          if e.is_a?(Sketchup::Edge)
            edge = e
            break
          end
        end

        if edge
          # Measure the selected edge
          measured_length = edge.length  # inches
          measured_str = format_length(measured_length)

          prompts = [
            "Selected edge measures:",
            "What should it actually be? (e.g. 1'-4, 16in, 406.4mm):",
            "Apply to:"
          ]
          defaults = [
            measured_str,
            "",
            "All Groups"
          ]
          dropdowns = [
            "",
            "",
            "All Groups|Selection Only|Active Group"
          ]

          result = UI.inputbox(prompts, defaults, dropdowns,
                               "Scale by Reference — BlueCollar Systems")
          return unless result

          _measured_display, real_dim_str, scale_target = result

          # Parse the real dimension
          real_inches = UnitParser.parse_model_units(real_dim_str)
          unless real_inches && real_inches > 0
            UI.messagebox("Could not parse dimension: \"#{real_dim_str}\"\n\n" \
                          "Examples: 1'-4, 5' 6 1/2\", 406.4mm, 16in, 2.5ft")
            return
          end

          # Calculate scale factor
          if measured_length <= 0
            UI.messagebox("Selected edge has zero length.")
            return
          end

          factor = real_inches / measured_length

          if factor <= 0 || factor.infinite? || factor.nan?
            UI.messagebox("Invalid scale factor calculated.")
            return
          end

          if factor > 10000 || factor < 0.0001
            warn_choice = UI.messagebox(
              "Scale factor %.6f is extremely %s.\n\n" \
              "This may indicate a unit mismatch. Continue anyway?" %
              [factor, factor > 10000 ? "large" : "small"],
              MB_YESNO)
            return unless warn_choice == IDYES
          end

          apply_scale(model, factor, scale_target, measured_length, real_inches, real_dim_str)

        else
          # No edge selected — show dialog-only workflow
          prompts = [
            "Enter KNOWN real dimension of a feature:",
            "Enter MEASURED dimension in model (or select edge first):",
            "Scale target:"
          ]
          defaults = ["", "", "All Groups"]
          dropdowns = ["", "", "All Groups|Selection Only|Active Group"]

          result = UI.inputbox(prompts, defaults, dropdowns,
                               "Scale by Reference — BlueCollar Systems")
          return unless result

          real_dim_str, measured_str, scale_target = result

          real_inches = UnitParser.parse_model_units(real_dim_str)
          measured_inches = UnitParser.parse_model_units(measured_str)

          unless real_inches && real_inches > 0
            UI.messagebox("Could not parse real dimension: \"#{real_dim_str}\"")
            return
          end
          unless measured_inches && measured_inches > 0
            UI.messagebox("Could not parse measured dimension: \"#{measured_str}\"\n" \
                          "Tip: Select an edge before running this tool.")
            return
          end

          factor = real_inches / measured_inches

          if factor > 10000 || factor < 0.0001
            warn_choice = UI.messagebox(
              "Scale factor %.6f is extremely %s.\n\n" \
              "This may indicate a unit mismatch. Continue anyway?" %
              [factor, factor > 10000 ? "large" : "small"],
              MB_YESNO)
            return unless warn_choice == IDYES
          end

          apply_scale(model, factor, scale_target, measured_inches, real_inches, real_dim_str)
        end
      end

      # ---------------------------------------------------------------
      # Quick Scale — type a factor or ratio directly
      # ---------------------------------------------------------------
      def self.quick_scale
        model = Sketchup.active_model
        unless model
          UI.messagebox("No active model.")
          return
        end

        prompts = [
          "Scale factor or ratio (e.g. 2.0, 1:50, 48, 0.5):",
          "Scale target:"
        ]
        defaults = ["1.0", "All Groups"]
        dropdowns = ["", "All Groups|Selection Only|Active Group"]

        result = UI.inputbox(prompts, defaults, dropdowns,
                             "Quick Scale — BlueCollar Systems")
        return unless result

        factor_str, scale_target = result

        # Parse factor — support "1:50" ratio format
        factor = parse_scale_factor(factor_str)
        unless factor && factor > 0
          UI.messagebox("Could not parse scale factor: \"#{factor_str}\"\n\n" \
                        "Examples: 2.0, 1:50, 48, 0.5")
          return
        end

        if factor > 10000 || factor < 0.0001
          warn_choice = UI.messagebox(
            "Scale factor %.6f is extremely %s.\n\n" \
            "This may indicate a unit mismatch. Continue anyway?" %
            [factor, factor > 10000 ? "large" : "small"],
            MB_YESNO)
          return unless warn_choice == IDYES
        end

        apply_scale(model, factor, scale_target, nil, nil, factor_str)
      end

      private

      # ---------------------------------------------------------------
      # Apply the scale transformation
      # ---------------------------------------------------------------
      def self.apply_scale(model, factor, target_mode, measured, real, dim_str)
        # Confirmation
        factor_display = "%.6f" % factor
        msg = "Scale Factor: #{factor_display}×\n"
        if measured && real
          msg += "Measured: #{format_length(measured)}\n"
          msg += "Real: #{dim_str}\n"
        end
        msg += "\nTarget: #{target_mode}\n"
        msg += "\nProceed?"

        choice = UI.messagebox(msg, MB_YESNO)
        return unless choice == IDYES

        model.start_operation("Scale by Reference", true)

        # Compute bounding box center of target geometry for anchored scaling.
        # Scaling around the geometry center keeps shapes in place instead of
        # displacing them (which happens when scaling around world origin).
        bb = Geom::BoundingBox.new
        case target_mode
        when "Selection Only"
          model.selection.each { |e| bb.add(e.bounds) if e.respond_to?(:bounds) }
        when "Active Group"
          path = model.active_path
          bb.add(path.last.bounds) if path && path.last && path.last.respond_to?(:bounds)
        else
          model.entities.each { |e| bb.add(e.bounds) if e.respond_to?(:bounds) && e.valid? }
        end
        anchor = bb.valid? ? bb.center : ORIGIN

        xform = Geom::Transformation.scaling(anchor, factor)
        scaled_count = 0

        case target_mode
        when "Selection Only"
          # Scale each selected entity (skip locked)
          model.selection.each do |ent|
            next if ent.respond_to?(:locked?) && ent.locked?
            if ent.respond_to?(:transform!)
              ent.transform!(xform)
              scaled_count += 1
            end
          end

        when "Active Group"
          # Scale the active editing context
          active = model.active_entities
          if active != model.entities
            # We're inside a group/component — scale its parent
            path = model.active_path
            if path && path.last
              if path.last.respond_to?(:locked?) && path.last.locked?
                UI.messagebox("The active group/component is locked and cannot be scaled.")
                model.abort_operation
                return
              end
              path.last.transform!(xform)
              scaled_count = 1
            end
          else
            UI.messagebox("Not currently editing a group. Use 'All Groups' instead.")
            model.abort_operation
            return
          end

        else  # "All Groups" — scale everything at the top level
          locked_count = 0
          model.entities.each do |ent|
            if ent.is_a?(Sketchup::Group) || ent.is_a?(Sketchup::ComponentInstance)
              if ent.respond_to?(:locked?) && ent.locked?
                locked_count += 1
                next
              end
              ent.transform!(xform)
              scaled_count += 1
            end
          end
          # If no groups found, scale all edges/faces
          if scaled_count == 0
            model.entities.each do |ent|
              next if ent.respond_to?(:locked?) && ent.locked?
              if ent.respond_to?(:transform!)
                ent.transform!(xform)
                scaled_count += 1
              end
            end
          end
        end

        model.commit_operation

        UI.messagebox("Scaled #{scaled_count} object(s) by #{factor_display}×")

        # Fit view to scaled geometry
        begin
          view = model.active_view
          if view
            cam = view.camera
            bb = model.bounds
            if bb.valid?
              center = bb.center
              eye = Geom::Point3d.new(center.x, center.y, center.z + 1000)
              view.camera = Sketchup::Camera.new(eye, center, Geom::Vector3d.new(0, 1, 0))
              view.camera.perspective = false
            end
            view.zoom_extents
          end
        rescue StandardError => e
          Logger.warn("ScaleTool", "zoom_top_view failed: #{e.message}")
        end
      end

      # ---------------------------------------------------------------
      # Format a length (inches) for display using model units
      # ---------------------------------------------------------------
      def self.format_length(inches)
        # Use SketchUp's formatting
        begin
          return inches.to_l.to_s
        rescue StandardError => e
          Logger.warn("ScaleTool", "format_length failed: #{e.message}")
          return "%.4f\"" % inches
        end
      end

      # ---------------------------------------------------------------
      # Parse scale factor from string — supports "2.0", "1:50", etc.
      # ---------------------------------------------------------------
      def self.parse_scale_factor(text)
        text = text.strip
        # Ratio format: "1:50" → 1/50 = 0.02
        if text =~ /\A(\d+(?:\.\d+)?)\s*:\s*(\d+(?:\.\d+)?)\z/
          num = $1.to_f
          den = $2.to_f
          return nil if den == 0
          return num / den
        end
        # Plain number
        if text =~ /\A[+-]?\d*\.?\d+\z/
          return text.to_f
        end
        nil
      end

    end
  end
end
