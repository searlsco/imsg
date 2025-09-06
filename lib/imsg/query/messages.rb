require 'time'
require 'json'
require_relative '../../message_decoder'

module Imsg
  module Query
    module Messages
      module_function

      APPLE_EPOCH_OFFSET = 978_307_200

      # Fetches message rows for a chat_id with minimal, read-only processing.
      # Returns an array of Hashes matching the legacy IMsgCLI#get_messages fields.
      # options: { from_date: ISO8601, to_date: ISO8601 }
      def fetch(db, chat_id, options = {})
        from_apple = options[:from_date] && apple_time_from_iso(options[:from_date])
        to_apple   = options[:to_date] && apple_time_from_iso(options[:to_date])

        messages = []
        # Probe DB connection
        db.execute('SELECT COUNT(*) FROM chat_message_join WHERE chat_id = ?', chat_id)

        query = <<-SQL
            SELECT m.ROWID as message_id,
                   m.is_from_me,
                   m.handle_id,
                   m.date as date_raw,
                   m.guid as guid,
                   m.text,
                   m.attributedBody,
                   m.associated_message_guid,
                   m.associated_message_type,
                   m.associated_message_emoji,
                   m.item_type,
                   m.is_system_message,
                   m.balloon_bundle_id,
                   m.service
            FROM chat_message_join cmj
            JOIN message m ON m.ROWID = cmj.message_id
            WHERE cmj.chat_id = ?
              #{from_apple ? "AND (CASE WHEN m.date > 1000000000000 THEN m.date/1000000000.0 ELSE m.date END) >= #{from_apple}" : ''}
              #{to_apple   ? "AND (CASE WHEN m.date > 1000000000000 THEN m.date/1000000000.0 ELSE m.date END) <= #{to_apple}" : ''}
            ORDER BY m.date ASC
          SQL
        messages = db.execute(query, chat_id)

        # Build reactions map (tapbacks)
        reaction_rows = messages.select { |m| !m['associated_message_guid'].to_s.empty? && m['associated_message_type'].to_i != 0 }
        reactions_by_guid = Hash.new { |h,k| h[k] = [] }
        reaction_rows.each do |r|
          target_guid = r['associated_message_guid'].to_s.sub(/^p:\d\//, '')
          emoji = (r['associated_message_emoji'] && !r['associated_message_emoji'].to_s.empty?) ? r['associated_message_emoji'] : tapback_emoji(r['associated_message_type'])
          next if emoji.nil? || emoji.to_s.empty?
          reactions_by_guid[target_guid] << { 'emoji' => emoji, 'from_me' => r['is_from_me'].to_i == 1 }
          r['skip_render'] = true
        end

        # Lookup author handles and attach reactions to targets
        guid_index = {}
        text_index = {}
        messages.each do |msg|
          guid_index[msg['guid']] = msg if msg['guid']
          if msg['handle_id']
            begin
              handle = db.execute('SELECT id FROM handle WHERE ROWID = ? LIMIT 1', msg['handle_id']).first
              msg['author_handle'] = handle['id'] if handle
            rescue
              msg['author_handle'] = "handle_#{msg['handle_id']}"
            end
          end
          if msg['guid'] && reactions_by_guid.key?(msg['guid'])
            grouped = reactions_by_guid[msg['guid']].group_by { |r| r['emoji'] }
            msg['reactions'] = grouped.map do |emoji, arr|
              any_them = arr.any? { |r| !r['from_me'] }
              reactor = any_them ? 'them' : 'me'
              { 'emoji' => emoji, 'count' => arr.length, 'reactor' => reactor }
            end
          end
          norm = normalize_text(msg['text'])
          (text_index[norm] ||= []) << msg if norm && !norm.empty?
        end

        # Decode attributedBody to text if needed and clean
        messages.each do |msg|
          msg['sent_at_local'] = convert_apple_time(msg['date_raw'])
          if msg['text'].nil? && msg['attributedBody']
            msg['text'] = MessageDecoder.decode_attributed_body(msg['attributedBody'])
          end
          if msg['text']
            msg['text'] = clean_text(msg['text'])
          end
        end

        # Convert SMS-style reaction text into badges
        messages.each do |msg|
          next unless msg['text'] && msg['associated_message_guid'].to_s.empty?
          emoji, quoted = parse_reaction_text(msg['text'])
          next unless emoji && quoted
          norm = normalize_text(quoted)
          candidates = text_index[norm]
          next unless candidates && !candidates.empty?
          target = candidates.select { |m| m['date_raw'].to_f <= msg['date_raw'].to_f }.max_by { |m| m['date_raw'].to_f }
          target ||= candidates.first
          if target
            target['reactions'] ||= []
            if (existing = target['reactions'].find { |r| r['emoji'] == emoji })
              existing['count'] = (existing['count'] || 1) + 1
            else
              reactor = (msg['is_from_me'].to_i == 1) ? 'me' : 'them'
              target['reactions'] << { 'emoji' => emoji, 'count' => 1, 'reactor' => reactor }
            end
            msg['skip_render'] = true
          end
        end

        messages
      end

      # Helpers (copied from CLI for parity; keep private to this module)
      def apple_time_from_iso(iso)
        t = Time.parse(iso) rescue nil
        return nil unless t
        (t.to_f - APPLE_EPOCH_OFFSET)
      end

      def convert_apple_time(apple_time)
        return nil unless apple_time
        t = apple_time
        t = t / 1_000_000_000.0 if t > 1_000_000_000_000
        unix = t + APPLE_EPOCH_OFFSET
        Time.at(unix).strftime('%Y-%m-%d %H:%M:%S')
      end

      def clean_text(text)
        return nil if text.nil?
        t = text.dup
        t.gsub!("\uFFFC", '')
        t.gsub!(/\)?at_\d+_[A-F0-9-]+/i, '')
        t.gsub!(/[\u0000-\u001F\u007F]/, '')
        t.strip!
        t.empty? ? nil : t
      end

      def normalize_text(text)
        return nil unless text
        text.downcase.gsub(/[\p{Pd}\-\u2010-\u2015]/, '-')
            .gsub(/[\u2018\u2019\u201C\u201D]/, '"')
            .gsub(/\s+/, ' ')
            .strip
      end

      def parse_reaction_text(text)
        return [nil, nil] unless text
        if text =~ /^(Loved|Liked|Disliked|Laughed|Emphasized|Questioned)\s+["\u201C\u201D](.+?)["\u201C\u201D]\s*$/i
          verb = $1.downcase
          quoted = $2
          emoji = case verb
                  when 'loved' then '❤️'
                  when 'liked' then '👍'
                  when 'disliked' then '👎'
                  when 'laughed' then '😆'
                  when 'emphasized' then '‼️'
                  when 'questioned' then '❓'
                  else nil
                  end
          return [emoji, quoted]
        end
        if text =~ /^Reacted\s+(.+?)\s+to\s+["\u201C\u201D](.+?)["\u201C\u201D]\s*$/i
          emoji = $1.strip
          quoted = $2
          return [emoji, quoted]
        end
        [nil, nil]
      end

      def tapback_emoji(type)
        case type.to_i
        when 2000 then '👍'
        when 2001 then '❤️'
        when 2002 then '👎'
        when 2003 then '😆'
        when 2004 then '‼️'
        when 2005 then '❓'
        when 2006 then nil
        else nil
        end
      end
    end
  end
end
