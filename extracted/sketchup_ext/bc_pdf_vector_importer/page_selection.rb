# Compact, strict page selections shared by the dialog, CLI and host pipelines.
# Ruby 2.2 compatible. Ranges are expanded only after the PDF count is known.
module BlueCollarSystems
  module PDFVectorImporter
    module PageSelection
      module_function

      def parse(spec)
        return :all if spec.nil? || spec == :all
        if spec.is_a?(Array)
          raise ArgumentError, 'The page selection is empty; enter All or pages such as 1,3-5.' if spec.empty?
          return spec.map { |value| parse_item(value) }
        end
        text = spec.to_s.strip
        return :all if text.empty? || text.downcase == 'all'
        text = text.gsub(/\s*-\s*/, '-')
        unless text =~ /\A\d+(?:-\d+)?(?:[\s,;]+\d+(?:-\d+)?)*\z/ &&
               text !~ /[,;]\s*[,;]/
          raise ArgumentError, 'Invalid page selection; use All or positive pages such as 1,3-5.'
        end
        text.split(/[,;\s]+/).map do |part|
          if part.include?('-')
            first, last = part.split('-', 2).map { |value| value.to_i }
            parse_item(first..last)
          else
            parse_item(part)
          end
        end
      end

      def parse_item(value)
        if value.is_a?(Range)
          first, last = value.begin, value.end
          unless first.is_a?(Integer) && last.is_a?(Integer) &&
                 !value.exclude_end? && first >= 1 && last >= first
            raise ArgumentError, "Invalid page range #{value}; use ascending positive pages such as 1-5."
          end
          return value
        end
        unless value.is_a?(Integer) || value.is_a?(String) && value =~ /\A\d+\z/
          raise ArgumentError, "Invalid page number #{value.inspect}; the first valid page is 1."
        end
        page = value.to_i
        raise ArgumentError, 'The first valid page number is 1.' if page < 1
        page
      end

      def resolve(spec, page_count)
        total = page_count.to_i
        return [] if total <= 0
        values = parse(spec)
        return (1..total).to_a if values == :all
        # Validate the entire request before allocating a range or importing a
        # valid peer page. A typo must never turn into a full-document import.
        values.each do |value|
          first = value.is_a?(Range) ? value.begin : value
          last = value.is_a?(Range) ? value.end : value
          if first > total || last > total
            raise ArgumentError, "Requested page #{value} is outside this #{total}-page PDF; choose pages 1-#{total} or All."
          end
        end
        pages = {}
        values.each do |value|
          if value.is_a?(Range)
            value.each { |page| pages[page] = true }
          else
            pages[value] = true
          end
        end
        pages.keys.sort
      end
    end
  end
end
