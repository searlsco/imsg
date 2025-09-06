module SimpleTable
  module_function

  def render(headings:, rows:, align: nil, repeat_header_at_bottom: false)
    cols = headings.length
    data = rows || []
    align ||= Array.new(cols, :left)

    # Compute column widths
    widths = Array.new(cols, 0)
    headings.each_with_index { |h, i| widths[i] = [widths[i], str_width(h)].max }
    data.each do |row|
      row.each_with_index do |cell, i|
        widths[i] = [widths[i], str_width(cell.to_s)].max
      end
    end

    # Build helpers
    sep = "+" + widths.map { |w| "-" * (w + 2) }.join("+") + "+"
    fmt_row = lambda do |row|
      "|" + row.each_with_index.map { |cell, i|
        s = cell.to_s
        pad = widths[i] - str_width(s)
        if align[i] == :right
          " " + (" " * pad) + s + " "
        else
          " " + s + (" " * pad) + " "
        end
      }.join("|") + "|"
    end

    out = []
    out << sep
    out << fmt_row.call(headings)
    out << sep
    data.each { |r| out << fmt_row.call(r) }
    if data.any? && repeat_header_at_bottom
      out << sep
      out << fmt_row.call(headings)
    end
    out << sep
    out.join("\n")
  end

  def str_width(s)
    s = s.to_s
    # Strip ANSI escape sequences
    s = s.gsub(/\e\[[0-9;]*m/, '')
    # Sum widths by grapheme cluster: emoji and CJK count as 2, others as 1
    s.grapheme_clusters.inject(0) { |acc, gc| acc + (cluster_wide?(gc) ? 2 : 1) }
  end

  # Heuristic: treat emoji, flags, and CJK/fullwidth blocks as double‑wide in terminals
  def cluster_wide?(gc)
    return false if gc.nil? || gc.empty?
    # Regional indicator flags (🇯🇵, 🇺🇸, etc.) — any cluster containing them renders as wide
    return true if gc.codepoints.any? { |cp| (0x1F1E6..0x1F1FF).include?(cp) }
    # Emoji presentation selector inside cluster
    return true if gc.include?("\u{FE0F}")
    # Common emoji blocks
    return true if gc.codepoints.any? { |cp|
      (0x1F300..0x1FAFF).include?(cp) ||
      (0x1F900..0x1F9FF).include?(cp) ||
      (0x2600..0x27FF).include?(cp)
    }
    # CJK and fullwidth ranges
    return true if gc.match?(/[\p{Han}\p{Katakana}\p{Hiragana}\p{Hangul}\p{InCJKSymbolsAndPunctuation}\p{InHalfwidthAndFullwidthForms}]/)
    false
  end
end
