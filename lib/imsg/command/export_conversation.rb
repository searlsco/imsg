require 'sqlite3'
require 'json'
require 'fileutils'
require 'tmpdir'
require 'securerandom'
require 'shellwords'
require 'rbconfig'
require_relative '../../image_dim'
require_relative '../../address_book_resolver'
require_relative '../../html_generator'
require_relative '../../paged_export_generator'
require_relative '../query/messages'
require_relative '../query/attachments'
require_relative '../query/chats'
require_relative '../query/address_book'
require_relative '../query/threads'
require_relative '../util/handle_util'
require_relative '../util/time_util'

module Imsg
  module Command
    class ExportsConversations
      APPLE_EPOCH_OFFSET = 978_307_200

      def initialize(options)
        @options = options || {}
      end

      def export(identifiers)
        ids = (identifiers || []).flat_map { |x| x.split(',') }.map(&:strip).reject(&:empty?)
        return export_all if ids.empty?
        return export_handles_selectors(ids) if ids.any? { |id| id =~ /^(?:c:|c\d+)/i }
        return export_address_book_selector(ids) if ids.any? { |id| id =~ /^ab:(?:pk:)?/i }
        export_single(ids.first)
      end

      # ==== Single chat export ====
      def export_single(chat_id_or_guid)
        input_dir = @options[:messages] || File.expand_path('~/Library/Messages')
        db_path = File.join(input_dir, 'chat.db')
        local_db_path, backup_dir = backup_db_if_needed(input_dir, db_path, @options[:backup])
        raise "Database not found at #{db_path}" unless File.exist?(db_path)

        begin
          db = SQLite3::Database.new(local_db_path, readonly: true)
          db.results_as_hash = true

          chat = Imsg::Query::Chats.find(db, chat_id_or_guid)
          raise "Chat not found with ID or GUID: #{chat_id_or_guid}" unless chat
          meta = Imsg::Query::Chats.metadata(db, chat['chat_id'])
          chat.merge!(meta)

          # Validate flags with early knowledge of single vs multi export
          validate_single_only_flags!(true, one_to_one: !chat['is_group'])

          # Optional flip-perspective address book header adjustment for 1:1
          if @options[:flip] && !chat['is_group']
            ab_path, ab_backup = resolve_address_book_source(@options[:address_book], @options[:backup]) unless @options[:no_address_book]
            begin
              handle = chat['participant_handles'] && chat['participant_handles'].first
              if handle && !handle.to_s.strip.empty?
                pretty = nil
                if ab_path && File.exist?(ab_path)
                  ab = AddressBookResolver.new(ab_path)
                  ab.load!
                  if (c = Imsg::Query::AddressBook.find_contact_for_handle(ab, handle.downcase)) && c.name && !c.name.strip.empty?
                    pretty = c.name
                  end
                end
                pretty ||= Imsg::Util::HandleUtil.cap_handle_name(handle)
                chat['display_name'] = pretty if pretty
              end
            ensure
              begin
                FileUtils.remove_entry(ab_backup) if ab_backup && Dir.exist?(ab_backup)
              rescue
              end
            end
          end

          # Optional explicit display name override (single-chat only)
          if @options[:display_name] && !@options[:display_name].to_s.strip.empty?
            chat['display_name'] = @options[:display_name].to_s
            chat['display_name_full'] = @options[:display_name].to_s
          end

          outdir = @options[:outdir] || generate_output_dir(chat)
          if File.expand_path(outdir).start_with?(File.expand_path(input_dir) + File::SEPARATOR)
            raise "Output directory cannot be inside the input Messages directory (#{input_dir})"
          end
          clean_output_dir(outdir)
          FileUtils.mkdir_p(outdir)
          assets_dir = File.join(outdir, 'assets')
          FileUtils.mkdir_p(assets_dir)

          messages = Imsg::Query::Messages.fetch(db, chat['chat_id'], from_date: @options[:from_date], to_date: @options[:to_date])
          attachment_map = Imsg::Query::Attachments.fetch(db, messages.map { |m| m['message_id'] })

          copied_attachments = if @options[:skip_attachments]
            {}
          else
            copy_attachments(attachment_map, assets_dir, input_dir)
          end

          base = HtmlGenerator.new(chat, [], {})
          paged = PagedExportGenerator.new(chat, messages, copied_attachments, page_size: (@options[:page_size] || 1000), flip: @options[:flip], attachments_included: !@options[:skip_attachments], friendly_names: {})
          paged.write(outdir, base.styles)

          maybe_open_after_export(File.join(outdir, 'index.html'))
      ensure
          db&.close if defined?(db)
          begin
            FileUtils.remove_entry(backup_dir) if backup_dir && Dir.exist?(backup_dir)
          rescue
          end
        end
      end

      # ==== Export-all (library) ====
      def export_all
        # Disallow single-only flags during bulk export
        validate_single_only_flags!(false)
        input_dir = @options[:messages] || File.expand_path('~/Library/Messages')
        db_path = File.join(input_dir, 'chat.db')
        local_db_path, backup_dir = backup_db_if_needed(input_dir, db_path, @options[:backup])
        outdir = @options[:outdir] || './exports/all_chats'
        raise "Database not found at #{db_path}" unless File.exist?(db_path)

        begin
          db = SQLite3::Database.new(local_db_path, readonly: true)
          db.results_as_hash = true

          # Prepare rows similarly to CLI#export_all_conversations
          rows = []
          ab_path = nil
          if !@options[:no_address_book]
            ab_path, _ = resolve_address_book_source(@options[:address_book], @options[:backup])
          end
          if ab_path
            begin
              ab = AddressBookResolver.new(ab_path).tap(&:load!)
              tmp_rows = Imsg::Query::Threads.contacts_list_from_address_book(db, ab, { sort: @options[:sort] || 'message_count', order: @options[:order] || 'asc', from_date: @options[:from_date], to_date: @options[:to_date] }, apply_row_level_date_filter: false)
            rescue SQLite3::Exception, StandardError
              tmp_rows = []
            end
            rows.concat(tmp_rows.nil? || tmp_rows.empty? ? Imsg::Query::Threads.contacts_list(db, { sort: @options[:sort] || 'message_count', order: @options[:order] || 'asc', from_date: @options[:from_date], to_date: @options[:to_date] }, apply_row_level_date_filter: false) : tmp_rows)
          else
            rows.concat(Imsg::Query::Threads.contacts_list(db, { sort: @options[:sort] || 'message_count', order: @options[:order] || 'asc', from_date: @options[:from_date], to_date: @options[:to_date] }, apply_row_level_date_filter: false))
          end
          if ab_path
            ab = AddressBookResolver.new(ab_path).tap(&:load!)
          else
            ab = nil
          end
          rows.concat(Imsg::Query::Threads.groups_list(db, ab: ab, coalesce: true, options: { sort: @options[:sort] || 'last_message_at', order: @options[:order] || 'desc', from_date: @options[:from_date], to_date: @options[:to_date] }, apply_row_level_date_filter: false))

          rows.sort_by! do |r|
            case (@options[:sort] || 'message_count')
            when 'name'
              [r['name'].to_s.downcase, -(r['message_count'] || 0)]
            when 'message_count'
              [r['message_count'] || 0, r['name'].to_s.downcase]
            else
              [r['last_date_raw'] ? r['last_date_raw'].to_f : -Float::INFINITY]
            end
          end
          rows.reverse! if (@options[:order] || 'desc').to_s.downcase == 'desc'

          clean_output_dir(outdir)
          FileUtils.mkdir_p(outdir)
          threads_dir = File.join(outdir, 'threads')
          FileUtils.mkdir_p(threads_dir)

          manifest = []
          used_slugs = {}
          require_relative '../../all_export_generator'
          written = 0

          ab = nil
          id_index = digits_index = nil
          if ab_path && File.exist?(ab_path)
            ab = AddressBookResolver.new(ab_path).tap(&:load!)
            id_index, digits_index = Imsg::Query::Chats.build_contact_indexes(ab)
          end

          one_to_one = db.execute(<<-SQL)
            SELECT chj.chat_id,
                   h.ROWID AS handle_rowid,
                   LOWER(h.id) AS handle_id,
                   h.uncanonicalized_id AS uncanon
            FROM chat_handle_join chj
            JOIN handle h ON h.ROWID = chj.handle_id
          SQL
          handles_by_chat = Hash.new { |h,k| h[k] = [] }
          one_to_one.each { |r| handles_by_chat[r['chat_id']] << [r['handle_rowid'], r['handle_id'], r['uncanon']] }

          from_apple = @options[:from_date] && Imsg::Util::TimeUtil.apple_from_iso(@options[:from_date])
          to_apple   = @options[:to_date] && Imsg::Util::TimeUtil.apple_from_iso(@options[:to_date])
          stats = db.execute(<<-SQL)
            SELECT chj.chat_id, MAX(m.date) AS last_date_raw, COUNT(*) AS message_count
            FROM chat_message_join cmj
            JOIN message m ON m.ROWID = cmj.message_id
            JOIN chat_handle_join chj ON chj.chat_id = cmj.chat_id
            WHERE 1=1
              #{from_apple ? "AND (CASE WHEN m.date > 1000000000000 THEN m.date/1000000000.0 ELSE m.date END) >= #{from_apple}" : ''}
              #{to_apple   ? "AND (CASE WHEN m.date > 1000000000000 THEN m.date/1000000000.0 ELSE m.date END) <= #{to_apple}" : ''}
            GROUP BY chj.chat_id
          SQL
          stats_by_chat = {}
          stats.each { |r| stats_by_chat[r['chat_id']] = { 'last' => r['last_date_raw'], 'count' => r['message_count'].to_i } }

          group_buckets = Imsg::Query::Chats.compute_group_buckets(db, id_index: (ab && Imsg::Query::Chats.build_contact_indexes(ab).first), digits_index: (ab && Imsg::Query::Chats.build_contact_indexes(ab).last), ab: ab)

          rows.each_with_index do |r, _i|
            case r['id']
            when /^ab:/
              next unless ab
              key = Imsg::Query::AddressBook.resolve_selector_to_key(ab, r['id'])
              next unless key
              selected_chat_ids = []
              handles_by_chat.each do |cid, arr|
                mapped = arr.map { |_hid, id_lc, uncanon| Imsg::Query::Chats.map_handle_to_contact_key(id_lc, uncanon, [id_index, digits_index]) || :unmapped }
                next if mapped.include?(:unmapped)
                uniq = mapped.uniq
                selected_chat_ids << cid if uniq.length == 1 && uniq.first == key
              end
              next if selected_chat_ids.empty?
              add_thread_export(db, input_dir, outdir, threads_dir, used_slugs, manifest, stats_by_chat, selected_chat_ids, kind: 'contact', id: r['id'], name: r['name'], ab: ab, local_db_path: local_db_path)
            when /^c:(\d+)/
              hid = $1.to_i
              chats = Imsg::Query::Chats.find_one_to_one_chats_for_handle(db, hid)
              chat_ids = chats.map { |x| x['chat_id'] }
              next if chat_ids.empty?
              add_thread_export(db, input_dir, outdir, threads_dir, used_slugs, manifest, stats_by_chat, chat_ids, kind: 'contact', id: r['id'], name: r['name'], ab: ab, local_db_path: local_db_path)
            when /^grp:([0-9a-f]{12})/
              sig = $1
              bucket = group_buckets.find { |b| b['sig'] == sig }
              next unless bucket
              # Prefer explicit iMessage group name everywhere when available.
              explicit = Imsg::Query::Chats.choose_group_display_name(bucket['names'])
              short_name = explicit || Imsg::Query::Chats.build_group_display_name(bucket['keys'], ab)
              full_name = explicit || Imsg::Query::Chats.build_group_full_name(bucket['keys'], ab)
              add_thread_export(db, input_dir, outdir, threads_dir, used_slugs, manifest, stats_by_chat, bucket['chat_ids'], kind: 'group', id: r['id'], name: short_name, full_name: full_name, ab: ab, local_db_path: local_db_path)
            when /^g:(\d+)/
              add_thread_export(db, input_dir, outdir, threads_dir, used_slugs, manifest, stats_by_chat, [$1.to_i], kind: 'group', id: r['id'], name: r['name'], ab: ab, local_db_path: local_db_path)
            else
              # skip
            end
            if @options[:limit] && manifest.length >= @options[:limit].to_i
              break
            end
          end

          require_relative '../../all_export_generator'
          AllExportGenerator.new(manifest.sort_by { |e| -(e['last'] || 0).to_f }).write(outdir)
          maybe_open_after_export(File.join(outdir, 'index.html'))
      ensure
          db&.close if defined?(db)
          begin
            FileUtils.remove_entry(backup_dir) if backup_dir && Dir.exist?(backup_dir)
          rescue
          end
        end
      end

      # ==== c:<handle> and chat id selectors (merged) ====
      def export_handles_selectors(selectors)
        input_dir = @options[:messages] || File.expand_path('~/Library/Messages')
        db_path = File.join(input_dir, 'chat.db')
        local_db_path, backup_dir = backup_db_if_needed(input_dir, db_path, @options[:backup])
        raise "Database not found at #{db_path}" unless File.exist?(db_path)

        begin
          db = SQLite3::Database.new(local_db_path, readonly: true)
          db.results_as_hash = true

          handle_ids = []
          chat_identifiers = []
          selectors.each do |sel|
            case sel
            when /^c:(\d+)$/i then handle_ids << $1.to_i
            when /^c(\d+)$/i then handle_ids << $1.to_i
            else chat_identifiers << sel
            end
          end
          chats = []
          handle_ids.each { |hid| chats.concat(Imsg::Query::Chats.find_one_to_one_chats_for_handle(db, hid)) }
          chat_identifiers.each do |ident|
            chat = Imsg::Query::Chats.find(db, ident)
            raise "Chat not found: #{ident}" unless chat
            chats << chat
          end
          raise 'No chats found for given selector(s)' if chats.empty?
          chats = chats.map { |c| c.merge(Imsg::Query::Chats.metadata(db, c['chat_id'])) }

          # Single vs multi: treat a single selector as a single conversation
          single_request = (selectors && selectors.length == 1)
          one_to_one = if single_request
            if chat_identifiers.length == 1
              !chats.first['is_group']
            elsif handle_ids.length == 1
              true
            else
              true
            end
          else
            false
          end
          validate_single_only_flags!(single_request, one_to_one: one_to_one)

          header_name = nil
          if single_request && @options[:display_name] && !@options[:display_name].to_s.strip.empty?
            header_name = @options[:display_name].to_s
          end
          header_name ||= begin
            names = chats.map { |c| c['display_name'] }.compact.uniq
            unless names.empty?
              names.first
            else
              nil
            end
          end
          header_name ||= begin
            handles = chats.flat_map { |c| c['participant_handles'] || [] }.uniq
            handles.empty? ? 'Merged Export' : handles.join(', ')
          end
          merged_chat = { 'chat_id' => "merged:#{selectors.join(',')}", 'guid' => nil, 'display_name' => header_name }

          all_messages = []
          chats.each { |c| all_messages.concat(Imsg::Query::Messages.fetch(db, c['chat_id'], from_date: @options[:from_date], to_date: @options[:to_date])) }
          all_messages.sort_by! { |m| m['date_raw'].to_f }
          attachment_map = Imsg::Query::Attachments.fetch(db, all_messages.map { |m| m['message_id'] })

          outdir = @options[:outdir]
          outdir = generate_output_dir(merged_chat) if outdir.nil? || outdir.strip.empty?
          raise "Output directory cannot be inside the input Messages directory (#{input_dir})" if File.expand_path(outdir).start_with?(File.expand_path(input_dir) + File::SEPARATOR)
          clean_output_dir(outdir)
          FileUtils.mkdir_p(outdir)
          assets_dir = File.join(outdir, 'assets')
          FileUtils.mkdir_p(assets_dir)

          copied_attachments = if @options[:skip_attachments]
            {}
          else
            copy_attachments(attachment_map, assets_dir, input_dir)
          end
          base = HtmlGenerator.new(merged_chat, [], {})
          paged = PagedExportGenerator.new(merged_chat, all_messages, copied_attachments, page_size: (@options[:page_size] || 1000), flip: @options[:flip], attachments_included: !@options[:skip_attachments], friendly_names: {})
          paged.write(outdir, base.styles)
          maybe_open_after_export(File.join(outdir, 'index.html'))
      ensure
          db&.close if defined?(db)
          begin
            FileUtils.remove_entry(backup_dir) if backup_dir && Dir.exist?(backup_dir)
          rescue
          end
        end
      end

      # ==== Address-book selectors (ab: or ab:pk:) ====
      def export_address_book_selector(identifiers)
        input_dir = @options[:messages] || File.expand_path('~/Library/Messages')
        db_path = File.join(input_dir, 'chat.db')
        local_db_path, backup_dir = backup_db_if_needed(input_dir, db_path, @options[:backup])
        raise "Database not found at #{db_path}" unless File.exist?(db_path)

        begin
          db = SQLite3::Database.new(local_db_path, readonly: true)
          db.results_as_hash = true

          ab_dir = @options[:address_book]
          ab_backup = nil
          unless ab_dir
            sys_ab_path, sys_backup = resolve_address_book_source(nil, @options[:backup])
            ab_dir = sys_ab_path if sys_ab_path
            ab_backup = sys_backup
          end
          raise 'No Address Book found. Pass --address-book or allow system Contacts access.' unless ab_dir && (File.directory?(ab_dir) || File.file?(ab_dir))
          ab = AddressBookResolver.new(ab_dir).tap(&:load!)

          keys = []
          identifiers.each do |sel|
            if sel =~ /^ab:(.+)$/i
              rest = $1
              key = rest
              if key.start_with?('pk:')
                pk = key.sub(/^pk:/, '')
                found = ab.contacts.values.find { |c| c.pk.to_s == pk.to_s }
                keys << found.key if found
              else
                found = ab.contacts.values.find { |c| c.link_id.to_s == key }
                keys << found.key if found
              end
            end
          end
          raise 'No matching contacts for selector(s)' if keys.empty?

          id_index = {}
          digits_index = {}
          ab.contacts.each_value do |c|
            next unless keys.include?(c.key)
            c.emails.each { |e| id_index[e.downcase] = c.key }
            c.phones.each do |p|
              id_index[p.downcase] = c.key
              d = p.gsub(/\D+/, '')
              digits_index[d] = c.key
              digits_index[d[-10..-1]] = c.key if d.length >= 10
            end
            c.im_ids.each do |mid|
              s = mid.to_s.strip
              next if s.empty?
              if s.start_with?('tel:')
                tel = s.sub(/^tel:/i, '')
                id_index[tel.downcase] = c.key
                d = tel.gsub(/\D+/, '')
                digits_index[d] = c.key if !d.empty?
                digits_index[d[-10..-1]] = c.key if d.length >= 10
              else
                id_index[s.downcase] = c.key
              end
            end
          end

          handle_rows = db.execute(<<-SQL)
            SELECT chj.chat_id,
                   LOWER(h.id) AS handle_id,
                   h.uncanonicalized_id AS uncanon
            FROM chat_handle_join chj
            JOIN handle h ON h.ROWID = chj.handle_id
          SQL
          handles_by_chat = Hash.new { |h,k| h[k] = [] }
          handle_rows.each { |r| handles_by_chat[r['chat_id']] << [r['handle_id'], r['uncanon']] }

          selected_chat_ids = []
          handles_by_chat.each do |cid, arr|
            mapped = arr.map do |hid, uncanon|
              id_lc = hid.to_s.downcase
              digits = hid.to_s.gsub(/\D+/, '')
              uncanon_digits = uncanon.to_s.gsub(/\D+/, '')
              id_index[id_lc] || digits_index[digits] || digits_index[uncanon_digits] || digits_index[digits[-10..-1]] || :unmapped
            end
            next if mapped.include?(:unmapped)
            uniq = mapped.uniq
            selected_chat_ids << cid if uniq.length == 1 && keys.include?(uniq.first)
          end
          raise 'No 1:1 chats found for selected contact(s)' if selected_chat_ids.empty?

          # Consider ab: selectors a single-conversation request when exactly
          # one selector is provided (even if it maps to multiple 1:1 chat_ids).
          single_request = (identifiers && identifiers.length == 1)
          validate_single_only_flags!(single_request, one_to_one: true)

          participant_handles = []
          selected_chat_ids.each_slice(800) do |batch|
            rows = db.execute(<<-SQL, batch)
              SELECT DISTINCT h.id AS handle
              FROM chat_handle_join chj
              JOIN handle h ON h.ROWID = chj.handle_id
              WHERE chj.chat_id IN (#{(['?']*batch.length).join(',')})
            SQL
            participant_handles.concat(rows.map { |r| r['handle'] })
          end
          participant_handles.uniq!
          header_name = nil
          if single_request && @options[:display_name] && !@options[:display_name].to_s.strip.empty?
            header_name = @options[:display_name].to_s
          end
          header_name ||= ab.contacts[keys.first]&.name || participant_handles.join(', ')
          merged_chat = { 'chat_id' => "merged:ab:#{keys.join(',')}", 'guid' => nil, 'display_name' => header_name, 'participant_handles' => participant_handles, 'is_group' => false }

          all_messages = []
          selected_chat_ids.each do |cid|
            all_messages.concat(Imsg::Query::Messages.fetch(db, cid, from_date: @options[:from_date], to_date: @options[:to_date]))
          end
          all_messages.sort_by! { |m| m['date_raw'].to_f }
          attachment_map = Imsg::Query::Attachments.fetch(db, all_messages.map { |m| m['message_id'] })

          outdir = @options[:outdir]
          outdir = generate_output_dir(merged_chat) if outdir.nil? || outdir.strip.empty?
          raise "Output directory cannot be inside the input Messages directory (#{input_dir})" if File.expand_path(outdir).start_with?(File.expand_path(input_dir) + File::SEPARATOR)
          clean_output_dir(outdir)
          FileUtils.mkdir_p(outdir)
          assets_dir = File.join(outdir, 'assets')
          FileUtils.mkdir_p(assets_dir)

          copied_attachments = if @options[:skip_attachments]
            {}
          else
            copy_attachments(attachment_map, assets_dir, input_dir)
          end
          base = HtmlGenerator.new(merged_chat, [], {})
          paged = PagedExportGenerator.new(merged_chat, all_messages, copied_attachments, page_size: (@options[:page_size] || 1000), flip: @options[:flip], attachments_included: !@options[:skip_attachments], friendly_names: {})
          paged.write(outdir, base.styles)
          maybe_open_after_export(File.join(outdir, 'index.html'))
      ensure
          db&.close if defined?(db)
          begin
            FileUtils.remove_entry(backup_dir) if backup_dir && Dir.exist?(backup_dir)
            FileUtils.remove_entry(ab_backup) if defined?(ab_backup) && ab_backup && Dir.exist?(ab_backup)
          rescue
          end
        end
      end

      # ==== Shared helpers (filesystem + time + AB) ====
      def clean_output_dir(dir)
        return unless dir && !dir.to_s.strip.empty?
        FileUtils.remove_entry(dir) if Dir.exist?(dir)
      rescue
      end

      # Centralized validation for flags that only make sense when exporting a
      # single conversation (i.e., generating a single-thread index.html instead
      # of the library-with-sidebar view). Optionally restrict flip to 1:1 only.
      def validate_single_only_flags!(single_request, one_to_one: true)
        unless single_request
          if @options[:flip]
            raise "--flip-perspective only applies when exporting a single conversation."
          end
          if @options[:display_name] && !@options[:display_name].to_s.strip.empty?
            raise "--display-name only applies when exporting a single conversation."
          end
          return
        end
        # For a single conversation that is a group chat, flip doesn't make sense
        if !one_to_one && @options[:flip]
          raise "--flip-perspective only applies to one-to-one conversations."
        end
      end

      def maybe_open_after_export(index_html_path)
        open_pref = @options.key?(:open_after_export) ? @options[:open_after_export] : nil
        interactive = $stdout.tty? || $stdin.tty?
        should_open = open_pref.nil? ? interactive : !!open_pref
        return unless should_open
        if RbConfig::CONFIG['host_os'] =~ /darwin/i
          system('open', index_html_path)
        elsif RbConfig::CONFIG['host_os'] =~ /linux/i
          system('xdg-open', index_html_path)
        elsif RbConfig::CONFIG['host_os'] =~ /mswin|mingw|cygwin/i
          system('start', index_html_path)
        end
      rescue
      end

      def backup_db_if_needed(input_dir, db_path, backup_opt)
        do_backup = backup_opt.nil? ? true : !!backup_opt
        return [db_path, nil] unless do_backup
        backup_dir = Dir.mktmpdir('imsg-backup-')
        backup_db = File.join(backup_dir, 'chat.db')
        cmd = %(sqlite3 #{Shellwords.escape(db_path)} ".backup #{Shellwords.escape(backup_db)}")
        ok = system(cmd)
        if ok && File.exist?(backup_db)
          [backup_db, backup_dir]
        else
          FileUtils.remove_entry(backup_dir) if Dir.exist?(backup_dir)
          [db_path, nil]
        end
      end

      def resolve_address_book_source(user_supplied, backup_opt)
        if user_supplied && !user_supplied.to_s.strip.empty?
          ab_path = File.expand_path(user_supplied)
          if File.file?(ab_path) && File.basename(ab_path) =~ /AddressBook-v\d+\.abcddb\z/
            return backup_address_book_if_needed(ab_path, backup_opt)
          elsif File.directory?(ab_path)
            tmp = AddressBookResolver.new(ab_path)
            db_file = tmp.resolve_db_path(ab_path)
            if db_file && File.file?(db_file)
              return backup_address_book_if_needed(db_file, backup_opt, default_system: false)
            end
            return [ab_path, nil]
          else
            return [ab_path, nil]
          end
        end
        return [nil, nil] unless RbConfig::CONFIG['host_os'] =~ /darwin/i
        base = File.expand_path('~/Library/Application Support/AddressBook')
        return [nil, nil] unless Dir.exist?(base)
        candidates = Dir.glob(File.join(base, 'Sources', '*', 'AddressBook-v*.abcddb'))
        candidates << File.join(base, 'AddressBook-v22.abcddb') if File.exist?(File.join(base, 'AddressBook-v22.abcddb'))
        candidates.select! { |f| File.file?(f) }
        return [nil, nil] if candidates.empty?
        db_path = candidates.max_by { |f| File.size(f) }
        backup_address_book_if_needed(db_path, backup_opt, default_system: true)
      rescue
        [nil, nil]
      end

      def backup_address_book_if_needed(db_path, backup_opt, default_system: false)
        do_backup = backup_opt.nil? ? true : !!backup_opt
        return [db_path, nil] unless do_backup
        backup_dir = Dir.mktmpdir('imsg-ab-backup-')
        backup_db = File.join(backup_dir, File.basename(db_path))
        cmd = %(sqlite3 #{Shellwords.escape(db_path)} ".backup #{Shellwords.escape(backup_db)}")
        ok = system(cmd)
        if ok && File.exist?(backup_db)
          [backup_db, backup_dir]
        else
          FileUtils.remove_entry(backup_dir) if Dir.exist?(backup_dir)
          [db_path, nil]
        end
      end

      def add_thread_export(db, input_dir, outdir, threads_dir, used_slugs, manifest, stats_by_chat, chat_ids, kind:, id:, name:, ab: nil, full_name: nil, local_db_path: nil)
        # Messages + attachments
        all_messages = []
        chat_ids.each { |cid| all_messages.concat(Imsg::Query::Messages.fetch(db, cid, from_date: @options[:from_date], to_date: @options[:to_date])) }
        all_messages.sort_by! { |m| m['date_raw'].to_f }
        attachment_map = Imsg::Query::Attachments.fetch(db, all_messages.map { |m| m['message_id'] })
        # Skip threads that would render empty
        return if renderables_count(all_messages, attachment_map) == 0

        slug = id.to_s.downcase.gsub(/[^a-z0-9]+/, '_').gsub(/^_|_$/, '')
        slug = 'thread' if slug.empty?
        if used_slugs[slug]
          suffix = Digest::SHA256.hexdigest(id.to_s)[0, 6]
          slug = "#{slug}_#{suffix}"
        end
        used_slugs[slug] = true
        thread_dir = File.join(threads_dir, slug)
        clean_output_dir(thread_dir)
        FileUtils.mkdir_p(thread_dir)
        assets_dir = File.join(thread_dir, 'assets')
        FileUtils.mkdir_p(assets_dir)
        copied_attachments = if @options[:skip_attachments]
          {}
        else
          copy_attachments(attachment_map, assets_dir, input_dir)
        end

        friendly = {}
        chat_stub = {
          'chat_id' => id,
          'guid' => nil,
          'display_name' => name,
          'display_name_full' => (full_name || name),
          'is_group' => kind == 'group'
        }
        base = HtmlGenerator.new(chat_stub, [], {}, friendly)
        paged = PagedExportGenerator.new(chat_stub, all_messages, copied_attachments, page_size: (@options[:page_size] || 1000), flip: @options[:flip], attachments_included: !@options[:skip_attachments], friendly_names: friendly)
        paged.write(thread_dir, base.styles)

        last = chat_ids.map { |cid| stats_by_chat[cid] && stats_by_chat[cid]['last'] }.compact.max
        last_local = last ? Imsg::Util::TimeUtil.apple_to_local_string(last.to_f) : nil
        last_date = begin
          last_local ? Time.parse(last_local).strftime('%Y-%m-%d') : nil
        rescue
          nil
        end
        count = chat_ids.map { |cid| stats_by_chat[cid] && stats_by_chat[cid]['count'] }.compact.sum
        pm = all_messages.reverse.find { |m| (!m['skip_render']) && m['text'] && !m['text'].strip.empty? }
        preview = pm ? pm['text'].strip.gsub(/\s+/, ' ') : '[Media]'
        preview = preview[0, 160]
        manifest << {
          'id' => id,
          'name' => name,
          'full_name' => (full_name || name),
          'kind' => kind,
          'path' => "threads/#{slug}/index.html",
          'last' => last,
          'last_local' => last_local,
          'last_date' => last_date,
          'message_count' => count,
          'preview' => preview
        }
      end

      def renderables_count(messages, attachments_map)
        c = 0
        messages.each do |m|
          text = (m['text'] || '').strip
          attachments = (attachments_map[m['message_id']] || []).reject { |a| Imsg::Util::AttachmentUtil.hide?(a) }
          invisible = text.empty? && attachments.empty? && (m['associated_message_guid'].to_s.empty?) && (m['item_type'].to_i != 0 || m['is_system_message'].to_i == 1)
          c += 1 unless invisible
        end
        c
      end

      def copy_attachments(attachment_map, assets_dir, input_dir)
        copied = {}
        by_source = {}
        attachment_map.each do |message_id, attachments|
          copied[message_id] = []
          attachments.each do |att|
            source_path = att['filename']
            if source_path
              if source_path.start_with?('file://')
                source_path = source_path.sub('file://', '')
              end
              if source_path.start_with?('~/Library/Messages/')
                relative_path = source_path.sub(%r{^~/Library/Messages/}, '')
                source_path = File.join(input_dir, relative_path)
              elsif source_path.match?(%r{^/[^/]+/.*/Library/Messages/})
                relative_path = source_path.split('/Library/Messages/', 2)[1]
                source_path = File.join(input_dir, relative_path)
              elsif source_path.match?(%r{/Library/(?:Messages|SMS)/})
                relative_path = source_path.split(%r{/Library/(?:Messages|SMS)/}, 2)[1]
                source_path = File.join(input_dir, relative_path)
              elsif !source_path.start_with?('/')
                source_path = File.join(input_dir, source_path)
              end
            end
            if source_path && File.exist?(source_path)
              transfer_name = att['transfer_name'] || File.basename(source_path)
              ext = extension_for(transfer_name, source_path, att['mime_type'])
              dest_name = by_source[source_path]
              unless dest_name
                dest_name = "#{SecureRandom.uuid}#{ext}"
                dest_path = File.join(assets_dir, dest_name)
                FileUtils.cp(source_path, dest_path)
                by_source[source_path] = dest_name
              end
              width = height = nil
              if att['mime_type'] && att['mime_type'].start_with?('image/')
                if (dim = ImageDim.sniff(source_path, att['mime_type']))
                  width, height = dim
                end
              end
              copied[message_id] << {
                'guid' => att['guid'],
                'filename' => "assets/#{dest_name}",
                'mime_type' => att['mime_type'],
                'transfer_name' => transfer_name,
                'width' => width,
                'height' => height,
                'kind' => infer_attachment_kind(att['mime_type'], transfer_name, dest_name)
              }
            else
              copied[message_id] << {
                'guid' => att['guid'],
                'filename' => nil,
                'mime_type' => att['mime_type'],
                'transfer_name' => att['transfer_name'],
                'missing' => true,
                'kind' => 'missing'
              }
            end
          end
        end
        copied
      end

      def extension_for(transfer_name, source_path, mime_type)
        ext = File.extname(transfer_name.to_s)
        ext = File.extname(source_path.to_s) if ext.nil? || ext.empty?
        if (ext.nil? || ext.empty?) && mime_type
          ext = case mime_type.downcase
                when 'image/jpeg', 'image/jpg' then '.jpg'
                when 'image/png' then '.png'
                when 'image/gif' then '.gif'
                when 'image/heic', 'image/heif' then '.heic'
                when 'image/webp' then '.webp'
                when 'video/quicktime' then '.mov'
                when 'video/mp4' then '.mp4'
                when 'audio/m4a', 'audio/mp4' then '.m4a'
                when 'audio/aac' then '.aac'
                else ''
                end
        end
        ext || ''
      end

      def infer_attachment_kind(mime_type, transfer_name, dest_name)
        name = (transfer_name || dest_name || '').to_s.downcase
        mime = (mime_type || '').to_s.downcase
        is_image = mime.start_with?('image/') || name =~ /\.(jpe?g|png|gif|heic|heif|webp)\z/
        return 'image' if is_image
        is_video = mime.start_with?('video/') || name =~ /\.(mov|mp4|m4v|webm)\z/
        return 'video' if is_video
        is_audio = mime.start_with?('audio/') || name =~ /\.(m4a|aac|mp3|wav|aiff?)\z/
        return 'audio' if is_audio
        'file'
      end

      def generate_output_dir(chat)
        display_name = chat['display_name'] || chat['guid'] || 'unknown_chat'
        safe = display_name.downcase.gsub(/[^a-z0-9]+/, '_').gsub(/^_|_$/, '')
        safe = 'chat' if safe.empty?
        "./exports/#{safe}"
      end
    end
  end
end
