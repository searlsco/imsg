require 'time'
require_relative '../util/time_util'
require_relative '../util/handle_util'
require_relative 'chats'

module Imsg
  module Query
    module Threads
      module_function

      # Contacts (1:1) aggregated per handle
      def contacts_list(db, options, apply_row_level_date_filter: true)
        one_to_one = db.execute(<<-SQL)
          SELECT chat_id
          FROM chat_handle_join
          GROUP BY chat_id
          HAVING COUNT(DISTINCT handle_id) = 1
        SQL
        one_to_one_ids = one_to_one.map { |r| r['chat_id'] }
        return [] if one_to_one_ids.empty?

        placeholders = (['?'] * one_to_one_ids.length).join(',')
        from_apple = options[:from_date] && Imsg::Util::TimeUtil.apple_from_iso(options[:from_date])
        to_apple   = options[:to_date] && Imsg::Util::TimeUtil.apple_from_iso(options[:to_date])
        contacts_rows = db.execute(<<-SQL, one_to_one_ids)
          SELECT h.ROWID AS handle_rowid,
                 h.id AS handle,
                 MAX(m.date) AS last_date_raw,
                 MIN(m.date) AS first_date_raw,
                 COUNT(*) AS message_count
          FROM chat_handle_join chj
          JOIN handle h ON h.ROWID = chj.handle_id
          JOIN chat_message_join cmj ON cmj.chat_id = chj.chat_id
          JOIN message m ON m.ROWID = cmj.message_id
          WHERE chj.chat_id IN (#{placeholders})
            #{from_apple ? "AND (CASE WHEN m.date > 1000000000000 THEN m.date/1000000000.0 ELSE m.date END) >= #{from_apple}" : ''}
            #{to_apple   ? "AND (CASE WHEN m.date > 1000000000000 THEN m.date/1000000000.0 ELSE m.date END) <= #{to_apple}" : ''}
          GROUP BY h.ROWID, h.id
        SQL
        name_rows = db.execute(<<-SQL, one_to_one_ids)
          SELECT h.ROWID AS handle_rowid, c.display_name, c.ROWID AS chat_rowid
          FROM chat_handle_join chj
          JOIN handle h ON h.ROWID = chj.handle_id
          JOIN chat c ON c.ROWID = chj.chat_id
          WHERE chj.chat_id IN (#{placeholders}) AND c.display_name IS NOT NULL AND c.display_name != ''
          ORDER BY h.ROWID ASC, c.ROWID ASC
        SQL
        best_name = {}
        name_rows.each { |r| best_name[r['handle_rowid']] ||= r['display_name'] }

        rows = []
        contacts_rows.each do |c|
          name = best_name[c['handle_rowid']] || c['handle']
          name = Imsg::Util::HandleUtil.cap_handle_name(name)
          rows << {
            'name' => name,
            'id' => "c:#{c['handle_rowid']}",
            'last_date_raw' => c['last_date_raw'],
            'first_date_raw' => c['first_date_raw'],
            'first_message_at_local' => c['first_date_raw'] ? Imsg::Util::TimeUtil.apple_to_local_string(c['first_date_raw']) : nil,
            'last_message_at_local' => c['last_date_raw'] ? Imsg::Util::TimeUtil.apple_to_local_string(c['last_date_raw']) : nil,
            'message_count' => c['message_count'].to_i,
            'type' => 'contact'
          }
        end

        sort_rows!(rows, options)
        if apply_row_level_date_filter
          filter_rows_by_window!(rows, options)
        end
        rows = rows.first(options[:limit]) if options[:limit]
        rows
      end

      # Contacts via AddressBook coalescing (one row per human)
      def contacts_list_from_address_book(db, ab, options, apply_row_level_date_filter: true)
        from_apple = options[:from_date] && Imsg::Util::TimeUtil.apple_from_iso(options[:from_date])
        to_apple   = options[:to_date] && Imsg::Util::TimeUtil.apple_from_iso(options[:to_date])
        stats = db.execute(<<-SQL)
          SELECT chj.chat_id,
                 MAX(m.date) AS last_date_raw,
                 MIN(m.date) AS first_date_raw,
                 COUNT(*) AS message_count
          FROM chat_message_join cmj
          JOIN message m ON m.ROWID = cmj.message_id
          JOIN chat_handle_join chj ON chj.chat_id = cmj.chat_id
          WHERE 1=1
            #{from_apple ? "AND (CASE WHEN m.date > 1000000000000 THEN m.date/1000000000.0 ELSE m.date END) >= #{from_apple}" : ''}
            #{to_apple   ? "AND (CASE WHEN m.date > 1000000000000 THEN m.date/1000000000.0 ELSE m.date END) <= #{to_apple}" : ''}
          GROUP BY chj.chat_id
        SQL
        stats_by_chat = {}
        stats.each { |r| stats_by_chat[r['chat_id']] = { 'last_date_raw' => r['last_date_raw'], 'first_date_raw' => r['first_date_raw'], 'message_count' => r['message_count'].to_i } }
        return [] if stats_by_chat.empty?

        handle_rows = db.execute(<<-SQL)
          SELECT chj.chat_id,
                 LOWER(h.id) AS handle_id,
                 h.uncanonicalized_id AS uncanon
          FROM chat_handle_join chj
          JOIN handle h ON h.ROWID = chj.handle_id
        SQL
        handles_by_chat = Hash.new { |h,k| h[k] = [] }
        handle_rows.each { |r| handles_by_chat[r['chat_id']] << [r['handle_id'], r['uncanon']] }

        id_index, digits_index = Imsg::Query::Chats.build_contact_indexes(ab)
        per_contact = {}
        handles_by_chat.each do |chat_id, arr|
          mapped = arr.map { |handle_id, uncanon| Imsg::Query::Chats.map_handle_to_contact_key(handle_id, uncanon, [id_index, digits_index]) || :unmapped }
          next if mapped.include?(:unmapped)
          keys = mapped.uniq
          next unless keys.length == 1
          key = keys.first
          st = (per_contact[key] ||= { 'last_date_raw' => nil, 'first_date_raw' => nil, 'message_count' => 0 })
          if (s = stats_by_chat[chat_id])
            st['message_count'] += s['message_count']
            st['last_date_raw'] = [st['last_date_raw'].to_f, s['last_date_raw'].to_f].max
            st['first_date_raw'] = [st['first_date_raw'] ? st['first_date_raw'].to_f : Float::INFINITY, s['first_date_raw'].to_f].min
          end
        end

        rows = []
        per_contact.each do |key, st|
          contact = ab.contacts[key]
          next unless contact
          name = (contact.name && !contact.name.strip.empty?) ? contact.name : (contact.emails.first || contact.phones.first || key)
          name = Imsg::Util::HandleUtil.cap_handle_name(name)
          ab_id = if contact.link_id && !contact.link_id.to_s.empty?
                    "ab:#{contact.link_id}"
                  else
                    "ab:pk:#{contact.pk}"
                  end
          rows << {
            'name' => name,
            'id' => ab_id,
            'last_date_raw' => st['last_date_raw'],
            'first_date_raw' => st['first_date_raw'],
            'first_message_at_local' => st['first_date_raw'] ? Imsg::Util::TimeUtil.apple_to_local_string(st['first_date_raw']) : nil,
            'last_message_at_local' => st['last_date_raw'] ? Imsg::Util::TimeUtil.apple_to_local_string(st['last_date_raw']) : nil,
            'message_count' => st['message_count'],
            'type' => 'contact'
          }
        end

        sort_rows!(rows, options)
        if apply_row_level_date_filter
          filter_rows_by_window!(rows, options)
        end
        rows = rows.first(options[:limit]) if options[:limit]
        rows
      end

      # Groups list, with optional coalescing via participant set signatures
      def groups_list(db, ab: nil, coalesce:, options:, apply_row_level_date_filter: true)
        from_apple = options[:from_date] && Imsg::Util::TimeUtil.apple_from_iso(options[:from_date])
        to_apple   = options[:to_date] && Imsg::Util::TimeUtil.apple_from_iso(options[:to_date])
        rows = db.execute(<<-SQL)
          SELECT c.ROWID AS chat_id,
                 c.display_name AS display_name,
                 MAX(m.date) AS last_date_raw,
                 MIN(m.date) AS first_date_raw,
                 COUNT(m.ROWID) AS message_count
          FROM chat c
          JOIN chat_message_join cmj ON cmj.chat_id = c.ROWID
          JOIN message m ON m.ROWID = cmj.message_id
          WHERE 1=1
            #{from_apple ? "AND (CASE WHEN m.date > 1000000000000 THEN m.date/1000000000.0 ELSE m.date END) >= #{from_apple}" : ''}
            #{to_apple   ? "AND (CASE WHEN m.date > 1000000000000 THEN m.date/1000000000.0 ELSE m.date END) <= #{to_apple}" : ''}
          GROUP BY c.ROWID
          HAVING (SELECT COUNT(DISTINCT chj.handle_id) FROM chat_handle_join chj WHERE chj.chat_id = c.ROWID) > 1
        SQL

        parts = db.execute(<<-SQL)
          SELECT chj.chat_id, LOWER(h.id) AS handle_id, h.uncanonicalized_id AS uncanon
          FROM chat_handle_join chj
          JOIN handle h ON h.ROWID = chj.handle_id
        SQL
        by_chat_handles = Hash.new { |h,k| h[k] = [] }
        parts.each { |r| by_chat_handles[r['chat_id']] << [r['handle_id'], r['uncanon']] }

        groups = []
        if coalesce
          id_index = digits_index = nil
          if ab
            id_index, digits_index = Imsg::Query::Chats.build_contact_indexes(ab)
          end
          buckets = {}
          rows.each do |r|
            participants = by_chat_handles[r['chat_id']] || []
            keys = participants.map do |hid, uncanon|
              if ab
                id_lc = hid.to_s.downcase
                digits = hid.to_s.gsub(/\D+/, '')
                uncanon_digits = uncanon.to_s.gsub(/\D+/, '')
                id_index[id_lc] || digits_index[digits] || digits_index[uncanon_digits] || digits_index[digits[-10..-1]] || hid
              else
                Imsg::Query::Chats.canonicalize_handle_for_group(hid, uncanon)
              end
            end.uniq.sort
            sig = Digest::SHA1.hexdigest(keys.join(','))[0,12]
            b = (buckets[sig] ||= { 'sig' => sig, 'keys' => keys, 'last_date_raw' => nil, 'first_date_raw' => nil, 'message_count' => 0, 'chat_ids' => [], 'names' => [] })
            b['chat_ids'] << r['chat_id']
            b['message_count'] += r['message_count'].to_i
            b['last_date_raw'] = [b['last_date_raw'].to_f, r['last_date_raw'].to_f].max
            b['first_date_raw'] = [b['first_date_raw'] ? b['first_date_raw'].to_f : Float::INFINITY, r['first_date_raw'].to_f].min
            dn = r['display_name']
            b['names'] << [dn, r['last_date_raw'].to_f] if dn && !dn.strip.empty?
          end
          buckets.each_value do |b|
            name = Imsg::Query::Chats.choose_group_display_name(b['names']) || Imsg::Query::Chats.build_group_display_name(b['keys'], ab)
            groups << {
              'name' => name,
              'id' => "grp:#{b['sig']}",
              'last_date_raw' => b['last_date_raw'],
              'first_date_raw' => b['first_date_raw'],
              'first_message_at_local' => b['first_date_raw'] ? Imsg::Util::TimeUtil.apple_to_local_string(b['first_date_raw']) : nil,
              'last_message_at_local' => b['last_date_raw'] ? Imsg::Util::TimeUtil.apple_to_local_string(b['last_date_raw']) : nil,
              'message_count' => b['message_count'],
              'type' => 'group'
            }
          end
        else
          rows.each do |r|
            participants = by_chat_handles[r['chat_id']] || []
            keys = participants.map { |hid, uncanon| Imsg::Query::Chats.canonicalize_handle_for_group(hid, uncanon) }.uniq
            name = r['display_name'] && !r['display_name'].strip.empty? ? r['display_name'] : Imsg::Query::Chats.build_group_display_name(keys.sort, ab)
            groups << {
              'name' => name,
              'id' => "g:#{r['chat_id']}",
              'last_date_raw' => r['last_date_raw'],
              'first_date_raw' => r['first_date_raw'],
              'first_message_at_local' => r['first_date_raw'] ? Imsg::Util::TimeUtil.apple_to_local_string(r['first_date_raw']) : nil,
              'last_message_at_local' => r['last_date_raw'] ? Imsg::Util::TimeUtil.apple_to_local_string(r['last_date_raw']) : nil,
              'message_count' => r['message_count'].to_i,
              'type' => 'group'
            }
          end
        end

        sort_rows!(groups, options)
        filter_rows_by_window!(groups, options) if apply_row_level_date_filter
        groups = groups.first(options[:limit]) if options[:limit]
        groups
      end

      # Sorting applied consistently across contacts and groups
      def sort_rows!(rows, options)
        rows.sort_by! do |r|
          case (options[:sort] || 'last_message_at')
          when 'name' then [r['name'].to_s.downcase, -(r['message_count'] || 0)]
          when 'message_count' then [r['message_count'] || 0, r['name'].to_s.downcase]
          else [r['last_date_raw'] ? r['last_date_raw'].to_f : -Float::INFINITY]
          end
        end
        rows.reverse! if (options[:order] || 'desc').to_s.downcase == 'desc'
      end

      def filter_rows_by_window!(rows, options)
        from_apple = options[:from_date] && Imsg::Util::TimeUtil.apple_from_iso(options[:from_date])
        to_apple   = options[:to_date] && Imsg::Util::TimeUtil.apple_from_iso(options[:to_date])
        return rows unless from_apple || to_apple
        rows.select! do |r|
          raw = r['last_date_raw'] && r['last_date_raw'].to_f
          next false unless raw
          t = raw > 1_000_000_000_000 ? raw / 1_000_000_000.0 : raw
          ok = true
          ok &&= (t >= from_apple) if from_apple
          ok &&= (t <= to_apple) if to_apple
          ok
        end
      end
    end
  end
end

