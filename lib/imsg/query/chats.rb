require 'time'
require 'digest'

module Imsg
  module Query
    module Chats
      module_function

      # Minimal helpers for consistency
      def find(db, identifier)
        if identifier.to_s.match?(/^\d+$/)
          row = db.execute('SELECT ROWID as chat_id, guid, display_name FROM chat WHERE ROWID = ? LIMIT 1', identifier.to_i).first
          return row if row
        end
        db.execute('SELECT ROWID as chat_id, guid, display_name FROM chat WHERE guid = ? LIMIT 1', identifier).first
      end

      def metadata(db, chat_id)
        rows = db.execute(<<-SQL, chat_id)
          SELECT h.id AS handle
          FROM chat_handle_join chj
          JOIN handle h ON h.ROWID = chj.handle_id
          WHERE chj.chat_id = ?
        SQL
        handles = rows.map { |r| r['handle'] }.compact
        { 'participant_handles' => handles, 'is_group' => handles.length > 1 }
      end

      # Utility used by export-all to build group coalescing buckets
      def compute_group_buckets(db, id_index: nil, digits_index: nil, ab: nil)
        parts = db.execute(<<-SQL)
          SELECT chj.chat_id, LOWER(h.id) AS handle_id, h.uncanonicalized_id AS uncanon
          FROM chat_handle_join chj
          JOIN handle h ON h.ROWID = chj.handle_id
        SQL
        by_chat_handles = Hash.new { |h,k| h[k] = [] }
        parts.each { |r| by_chat_handles[r['chat_id']] << [r['handle_id'], r['uncanon']] }

        rows = db.execute(<<-SQL)
          SELECT c.ROWID AS chat_id,
                 c.display_name AS display_name
          FROM chat c
          WHERE (SELECT COUNT(DISTINCT chj.handle_id) FROM chat_handle_join chj WHERE chj.chat_id = c.ROWID) > 1
        SQL

        buckets = {}
        rows.each do |r|
          participants = by_chat_handles[r['chat_id']] || []
          keys = participants.map do |hid, uncanon|
            if ab && id_index && digits_index
              id_lc = hid.to_s.downcase
              digits = hid.to_s.gsub(/\D+/, '')
              uncanon_digits = uncanon.to_s.gsub(/\D+/, '')
              id_index[id_lc] || digits_index[digits] || digits_index[uncanon_digits] || digits_index[digits[-10..-1]] || hid
            else
              canonicalize_handle_for_group(hid, uncanon)
            end
          end.uniq.sort
          sig = Digest::SHA1.hexdigest(keys.join(','))[0,12]
          b = (buckets[sig] ||= { 'sig' => sig, 'chat_ids' => [], 'names' => [], 'keys' => keys })
          b['chat_ids'] << r['chat_id']
          dn = r['display_name']
          b['names'] << dn if dn && !dn.strip.empty?
        end
        buckets.values
      end

      def find_one_to_one_chats_for_handle(db, handle_rowid)
        db.execute(<<-SQL, handle_rowid)
          SELECT c.ROWID as chat_id
          FROM chat c
          JOIN chat_handle_join chj ON chj.chat_id = c.ROWID
          GROUP BY c.ROWID
          HAVING COUNT(DISTINCT chj.handle_id) = 1 AND MAX(CASE WHEN chj.handle_id = ? THEN 1 ELSE 0 END) = 1
        SQL
      end

      # Shared helpers copied from CLI for parity
      def canonicalize_handle_for_group(hid, uncanon)
        s = hid.to_s.downcase
        return s if s.include?('@')
        d = (uncanon || s).to_s.gsub(/\D+/, '')
        d = d[-10,10] if d.length > 10
        d.empty? ? s : "+#{d}"
      end

      def choose_group_display_name(name_time_pairs)
        return nil unless name_time_pairs && !name_time_pairs.empty?
        first = name_time_pairs.first
        if !first.is_a?(Array)
          freq = Hash.new(0)
          name_time_pairs.each { |n| freq[n] += 1 if n && !n.to_s.strip.empty? }
          return nil if freq.empty?
          return freq.max_by { |(_n,c)| c }.first
        end
        recent = name_time_pairs.max_by { |(n,t)| t || -Float::INFINITY }
        return recent.first if recent && recent.first && !recent.first.strip.empty?
        freq = Hash.new(0)
        name_time_pairs.each { |(n, _)| freq[n] += 1 if n && !n.strip.empty? }
        return nil if freq.empty?
        freq.max_by { |(_n, c)| c }.first
      end

      # Naming utilities (ported from CLI for parity)
      def build_group_display_name(keys, ab)
        names = keys.map do |k|
          if ab && ab.contacts[k]
            nm = ab.contacts[k].name
            nm && !nm.strip.empty? ? nm : (ab.contacts[k].emails.first || ab.contacts[k].phones.first || k)
          else
            k
          end
        end
        names = names.map { |nm| sanitize_truncate(nm, 13) }
        base = if names.length <= 3
          names.join(', ')
        else
          names.first(3).join(', ')
        end
        suffix = names.length > 3 ? " (+#{names.length-3} more)" : ""
        truncate_total(base, 25) + suffix
      end

      def build_group_full_name(keys, ab)
        names = keys.map do |k|
          if ab && ab.contacts[k]
            nm = ab.contacts[k].name
            nm && !nm.strip.empty? ? nm : (ab.contacts[k].emails.first || ab.contacts[k].phones.first || k)
          else
            k
          end
        end
        names.join(', ')
      end

      def build_contact_indexes(ab)
        id_index = {}
        digits_index = {}
        ab.contacts.each_value do |c|
          key = c.key
          c.emails.each { |e| id_index[e.downcase] = key }
          phone_like = []
          phone_like.concat(c.phones)
          c.im_ids.each do |mid|
            s = mid.to_s.strip
            next if s.empty?
            if s.start_with?('tel:')
              phone_like << s.sub(/^tel:/i, '')
            elsif s =~ /\A\+?\d[\d\s().-]*\z/
              phone_like << s
            else
              id_index[s.downcase] = key
            end
          end
          phone_like.each do |p|
            id_index[p.downcase] = key
            d = p.gsub(/\D+/, '')
            next if d.empty?
            digits_index[d] = key
            1.upto(3) do |drop|
              next if d.length - drop < 7
              digits_index[d[-(d.length - drop)..-1]] ||= key
            end
            digits_index[d[-10..-1]] ||= key if d.length >= 10
          end
        end
        [id_index, digits_index]
      end

      def map_handle_to_contact_key(hid, uncanon, indexes)
        id_index, digits_index = indexes
        id_lc = hid.to_s.downcase
        return id_index[id_lc] if id_index.key?(id_lc)
        digits = hid.to_s.gsub(/\D+/, '')
        uncanon_digits = uncanon.to_s.gsub(/\D+/, '')
        [digits, uncanon_digits].each do |d|
          next if d.nil? || d.empty?
          return digits_index[d] if digits_index.key?(d)
          1.upto(3) do |drop|
            next if d.length - drop < 7
            sfx = d[-(d.length - drop)..-1]
            return digits_index[sfx] if digits_index.key?(sfx)
          end
          return digits_index[d[-10..-1]] if d.length >= 10 && digits_index.key?(d[-10..-1])
        end
        nil
      end

      def sanitize_truncate(str, max)
        s = str.to_s.strip
        g = s.grapheme_clusters
        return s if g.length <= max
        g[0, max].join.rstrip + "\u2026"
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
