require 'CFPropertyList'
require 'stringio'

class MessageDecoder
  # Decode NSKeyedArchiver/NSMutableAttributedString blobs
  def self.decode_attributed_body(blob)
    return nil unless blob

    # 0) Fast-path: extract NSString payload inside the typedstream
    # Reference: community reverse‑engineering notes on iMessage's
    # typedstream for NS(Mutable)AttributedString where the plain string
    # follows an 'NSString' marker with a 1‑ or 2‑byte length prefix.
    text = extract_nsstring_from_typedstream(blob)
    return text unless text.nil? || text.empty?

    # 1) Try to parse as a plist (NSKeyedArchiver) but do not abort on failure
    begin
      plist = CFPropertyList::List.new(data: blob)
      parsed = CFPropertyList.native_types(plist.value)
      if parsed.is_a?(Hash)
        text = parsed['NSString'] ||
               parsed['NS.string'] ||
               parsed['$objects']&.find { |obj| obj.is_a?(String) && !obj.start_with?('$') }
        return text if text && !text.empty?
      end
    rescue StandardError
      # Not a plist/archivable structure; fall through to heuristics
    end

    # 2) Heuristic extraction for 'streamtyped' archives: keep readable UTF‑8 runs
    begin
      readable_text = blob.dup.force_encoding('UTF-8')
                         .encode('UTF-8', invalid: :replace, undef: :replace, replace: '')
      # Remove obvious archive markers but keep punctuation/whitespace
      cleaned = readable_text.gsub(/[\x00-\x1F\x7F]/, ' ')
                             .gsub(/\bstreamtyped\b/i, ' ')
                             .gsub(/\$[a-zA-Z0-9_]+/, ' ')
                             .gsub(/\bNS[A-Za-z0-9_]+\b/, ' ')
                             .gsub(/\b__kIM[A-Za-z0-9_]+\b/, ' ')
                             .gsub(/\s+/, ' ')
                             .strip
      # Prefer most sentence-like chunk
      candidates = cleaned.scan(/[A-Za-z0-9\p{Punct}\s]{6,}/)
      best = candidates.max_by { |s| [s.count('a-zA-Z'), s.length] }
      chosen = (best || cleaned).strip
      # Remove inline attachment placeholders like ")at_0_<GUID>"
      chosen = chosen.gsub(/\)?at_\d+_[A-F0-9-]+/i, '').gsub(/\s+/, ' ').strip
      return chosen unless chosen.empty? || cleaned.start_with?('bplist')
    rescue StandardError
      # fall through
    end

    # 3) Last resort: longest ASCII run that looks like user text
    begin
      strings = blob.scan(/[\x20-\x7E]{4,}/)
                    .reject { |s| s.match?(/^\$|^NS|^IM|^__kIM/) }
                    .select { |s| s.match?(/[a-zA-Z]/) }
      longest = strings.max_by(&:length)
      return longest.strip if longest && longest.length > 3
    rescue StandardError
      # ignore
    end

    nil
  end

  # Pulls the underlying NSString out of Apple's typedstream format.
  # Avoids leaking struct/type markers like "iI", "*", etc.
  def self.extract_nsstring_from_typedstream(blob)
    begin
      data = blob.dup
      marker = 'NSString'.b
      idx = data.index(marker)
      return nil unless idx

      # After 'NSString' there are typically 5 bytes of typedstream
      # metadata before a length-prefixed string payload.
      cursor = idx + marker.bytesize + 5
      return nil if cursor >= data.bytesize

      b0 = data.getbyte(cursor)

      if b0 == 0x81
        # Two‑byte little‑endian length
        len = data.getbyte(cursor + 1) + (data.getbyte(cursor + 2) << 8)
        start = cursor + 3
      else
        # Single‑byte length
        len = b0
        start = cursor + 1
      end

      return nil if start + len > data.bytesize
      raw = data.byteslice(start, len)
      # Ensure UTF‑8 with replacement for any oddities
      str = raw.force_encoding('UTF-8').encode('UTF-8', invalid: :replace, undef: :replace, replace: '')

      # Remove inline attachment placeholders like ")at_0_<GUID>"
      str = str.gsub(/\)?at_\d+_[A-F0-9-]+/i, '').gsub(/\s+/, ' ').strip

      str.empty? ? nil : str
    rescue
      nil
    end
  end
end
