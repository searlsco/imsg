module Imsg
  module Util
    module HandleUtil
      module_function

      # Pretty-print a handle (email/phone) for display when no contact name is available
      def format_handle(handle)
        return '' unless handle
        s = handle.to_s
        if s.match?(/^\+\d+$/)
          # +1 (XXX) XXX-XXXX style grouping
          s.gsub(/(\+\d)(\d{3})(\d{3})(\d{4})/, '\\1 (\\2) \\3-\\4')
        else
          s
        end
      end

      # Resolve an author label from a friendly map with several fallbacks
      def resolve_author_name(friendly_map, handle)
        return '' unless handle
        h = handle.to_s.downcase
        name = (friendly_map || {})[h]
        return name if name && !name.strip.empty?
        format_handle(handle)
      end

      # Cap long raw handles used as names (mirrors IMsgCLI#cap_handle_name)
      def cap_handle_name(name)
        s = name.to_s
        return s if s.empty?
        if s.include?('@')
          truncate_total(s, 20)
        elsif s =~ /\A\+?[\d\s().-]+\z/
          truncate_total(s, 16)
        else
          s
        end
      end

      def truncate_total(str, max)
        s = str.to_s.rstrip
        g = s.grapheme_clusters
        return s if g.length <= max
        g[0, max].join.rstrip + "\u2026"
      end
    end
  end
end

