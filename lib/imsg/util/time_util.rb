module Imsg
  module Util
    module TimeUtil
      module_function

      # Returns a human day label like "Today", "Yesterday", or "Month DD, YYYY"
      def day_label(timestamp, now: Time.now)
        return '' unless timestamp
        t = Time.parse(timestamp)
        if t.to_date == now.to_date
          'Today'
        elsif t.to_date == (now - 86_400).to_date
          'Yesterday'
        else
          t.strftime('%B %d, %Y')
        end
      end

      # Returns "H:MM AM/PM" matching existing exports
      def time_human(timestamp)
        return '' unless timestamp
        Time.parse(timestamp).strftime('%l:%M %p').strip
      end

      # ISO-8601 string for <time datetime="...">
      def iso(timestamp)
        return '' unless timestamp
        Time.parse(timestamp).iso8601
      end

      APPLE_EPOCH_OFFSET = 978_307_200

      # Convert Apple epoch seconds (or nanoseconds) to local time string
      # "YYYY-MM-DD HH:MM:SS"
      def apple_to_local_string(apple_time)
        return nil unless apple_time
        t = apple_time
        t = t / 1_000_000_000.0 if t > 1_000_000_000_000
        unix = t + APPLE_EPOCH_OFFSET
        Time.at(unix).strftime('%Y-%m-%d %H:%M:%S')
      end

      # Convert ISO8601 to Apple epoch seconds (float)
      def apple_from_iso(iso)
        t = Time.parse(iso) rescue nil
        return nil unless t
        (t.to_f - APPLE_EPOCH_OFFSET)
      end
    end
  end
end
