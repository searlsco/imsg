require 'cgi'

module Imsg
  module Util
    module TextUtil
      module_function

      # Convert URLs in plain text into safe anchor tags.
      # Mirrors HtmlGenerator#linkify behavior for byte-for-byte parity.
      def linkify(text)
        return '' unless text && !text.empty?
        url_regex = %r{(?:(?:https?://)|(?:www\.))[^\s<]+}i
        out = []
        last = 0
        text.to_enum(:scan, url_regex).each do
          m = Regexp.last_match
          start_i = m.begin(0)
          end_i = m.end(0)
          out << CGI.escapeHTML(text[last...start_i]) if start_i > last
          raw = m[0]
          trimmed = raw.sub(/[\)\]\.,!?:;]+\z/, '')
          trailer = raw[trimmed.length..-1] || ''
          href = trimmed =~ %r{^https?://}i ? trimmed : "https://#{trimmed}"
          display = trimmed
          out << %Q{<a class="linkified" href="#{CGI.escapeHTML(href)}" target="_blank" rel="noopener noreferrer">#{CGI.escapeHTML(display)}</a>}
          out << CGI.escapeHTML(trailer) unless trailer.empty?
          last = end_i
        end
        out << CGI.escapeHTML(text[last..-1]) if last < text.length
        out.join
      end
    end
  end
end

