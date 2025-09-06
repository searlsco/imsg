# Tiny, dependency-free image dimension sniffer for common formats.
# Supports: PNG, JPEG, GIF, and WebP (VP8/VP8L/VP8X).

module ImageDim
  module_function

  def sniff(path, mime_type = nil)
    return nil unless path && File.file?(path)
    File.open(path, 'rb') do |f|
      header = f.read(64) || ''
      return png(header) if header.start_with?("\x89PNG\r\n\x1A\n")
      return gif(header) if header.start_with?("GIF87a") || header.start_with?("GIF89a")
      return webp(f, header) if header.start_with?('RIFF') && header.byteslice(8,4) == 'WEBP'
      # JPEG needs scanning; start by checking SOI
      if header.byteslice(0,2) == "\xFF\xD8"
        return jpeg(f, header)
      end
    end
    nil
  rescue
    nil
  end

  def png(header)
    return nil unless header.bytesize >= 24
    w = header.byteslice(16,4).unpack1('N')
    h = header.byteslice(20,4).unpack1('N')
    valid_dim(w,h)
  end

  def gif(header)
    return nil unless header.bytesize >= 10
    w, h = header.byteslice(6,4).unpack('v2')
    valid_dim(w,h)
  end

  # Minimal JPEG parser: scan segments until SOF markers with size info.
  def jpeg(io, header)
    # We already read 64 bytes; build a buffer and continue from there
    buf = header.dup
    # Position in io is after header; continue reading as needed
    # Scan for 0xFF marker bytes
    loop do
      # Ensure we have at least 4 bytes ahead
      while buf.bytesize < 4
        chunk = io.read(4096)
        return nil unless chunk
        buf << chunk
      end
      # Find next marker 0xFF, skip fill bytes
      idx = buf.index("\xFF")
      return nil unless idx
      buf = buf.byteslice(idx..-1)
      # Collapse multiple 0xFF bytes without regex (binary safe)
      if buf.getbyte(0) == 0xFF
        k = 1
        k += 1 while k < buf.bytesize && buf.getbyte(k) == 0xFF
        buf = buf.byteslice(0,1) + buf.byteslice(k..-1).to_s
      end
      return nil if buf.bytesize < 2
      marker = buf.getbyte(1)
      # Standalone markers without length (FFD0-FFD9 except D8/D9 handling). We skip them.
      if (0xD0..0xD9).include?(marker) && marker != 0xD8 && marker != 0xD9
        buf = buf.byteslice(2..-1)
        next
      end
      # Read segment length for markers that have it
      while buf.bytesize < 4
        chunk = io.read(4096)
        return nil unless chunk
        buf << chunk
      end
      seg_len = buf.byteslice(2,2).unpack1('n')
      return nil if seg_len.nil? || seg_len < 2
      # SOF markers that define size
      if sof_marker?(marker)
        # Need at least 7 bytes after length: precision(1) height(2) width(2)
        needed = 2 + seg_len
        while buf.bytesize < needed
          chunk = io.read(4096)
          return nil unless chunk
          buf << chunk
        end
        data = buf.byteslice(4, seg_len - 2)
        return valid_dim(*data.byteslice(1,4).unpack('n2').reverse) # Actually height, width; reverse to width,height
      end
      # Skip this segment
      needed = 2 + seg_len
      while buf.bytesize < needed
        chunk = io.read(4096)
        return nil unless chunk
        buf << chunk
      end
      buf = buf.byteslice(needed..-1)
    end
  end

  def sof_marker?(m)
    # SOF0,1,2,3,5,6,7,9,10,11,13,14,15 (exclude DHT/DQT etc.)
    [0xC0,0xC1,0xC2,0xC3,0xC5,0xC6,0xC7,0xC9,0xCA,0xCB,0xCD,0xCE,0xCF].include?(m)
  end

  # Minimal WebP parser: read first chunk after RIFF/WEBP and handle VP8X/VP8/VP8L
  def webp(io, header)
    # header[0,12] = RIFF, size, WEBP
    buf = header.dup
    # Ensure at least first chunk header (8 bytes) beyond 12
    while buf.bytesize < 20
      chunk = io.read(4096)
      return nil unless chunk
      buf << chunk
    end
    chunk_tag = buf.byteslice(12,4)
    chunk_size = buf.byteslice(16,4).unpack1('V') || 0
    # Ensure we have the whole chunk payload available in buffer for small files
    need = 20 + chunk_size
    while buf.bytesize < need
      chunk = io.read([4096, need - buf.bytesize].max)
      break unless chunk
      buf << chunk
    end
    case chunk_tag
    when 'VP8X'
      return nil unless buf.bytesize >= 30
      # VP8X payload: 1 byte flags, 3 bytes reserved, then 3 bytes width-1, 3 bytes height-1 (little-endian, 24-bit)
      w_minus1 = buf.byteslice(24,3).unpack1('V') & 0xFFFFFF
      h_minus1 = buf.byteslice(27,3).unpack1('V') & 0xFFFFFF
      return valid_dim(w_minus1 + 1, h_minus1 + 1)
    when 'VP8 '
      # Key frame header has 3-byte frame tag then 3-byte signature 0x9d 0x01 0x2a, then 2 bytes width, 2 bytes height (little-endian)
      sig = buf.index("\x9D\x01\x2A", 20)
      return nil unless sig
      off = sig + 3
      return nil unless buf.bytesize >= off + 4
      w, h = buf.byteslice(off,4).unpack('v2')
      return valid_dim(w,h)
    when 'VP8L'
      # Lossless: 5 bytes header; width-1 in 14 bits, height-1 in next 14 bits
      return nil unless buf.bytesize >= 25
      b0,b1,b2,b3 = buf.byteslice(21,4).bytes
      w = ((b1 & 0x3F) << 8) | b0
      h = ((b3 & 0x0F) << 10) | (b2 << 2) | ((b1 & 0xC0) >> 6)
      return valid_dim(w + 1, h + 1)
    end
    nil
  end

  def valid_dim(w,h)
    return nil unless w && h && w > 0 && h > 0
    [w,h]
  end
end
