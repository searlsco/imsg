require 'set'

class ContactsResolver
  def self.load(path)
    return nil unless path && File.exist?(path)
    resolver = new
    resolver.load_vcard(File.read(path))
    resolver
  end

  def initialize
    @map = {}
  end

  # Very small vCard reader for common fields: FN, EMAIL, TEL
  def load_vcard(text)
    current_name = nil
    text.each_line do |line|
      line = line.strip
      next if line.empty?
      case line
      when /^BEGIN:VCARD/i
        current_name = nil
      when /^FN[:;](.+)$/i
        current_name = decode_value($1)
      when /EMAIL[^:]*:(.+)$/i
        email = $1.strip.downcase
        next if email.empty?
        name = current_name || email
        @map[email] = name
      when /TEL[^:]*:(.+)$/i
        raw = $1.strip
        next if raw.empty?
        phone = normalize_phone(raw)
        next unless phone
        name = current_name || phone
        @map[phone] = name
      when /^END:VCARD/i
        current_name = nil
      end
    end
  end

  def lookup(handle)
    return nil unless handle
    key = if handle.include?('@')
            handle.downcase
          else
            normalize_phone(handle)
          end
    key ? @map[key] : nil
  end

  private

  def decode_value(v)
    v.to_s.gsub('\\n', ' ').gsub('\\,', ',').strip
  end

  def normalize_phone(s)
    digits = s.to_s.gsub(/\D+/, '')
    return nil if digits.empty?
    digits = digits.sub(/^1(\d{10})$/, '\\1')
    "+#{digits}"
  end
end

