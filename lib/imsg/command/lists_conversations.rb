require 'sqlite3'
require 'fileutils'
require 'tmpdir'
require 'rbconfig'
require 'shellwords'
require_relative '../../address_book_resolver'
require_relative '../query/threads'
require_relative '../util/time_util'
require_relative '../../table'

module Imsg
  module Command
    class ListsConversations
      def initialize(options)
        @options = options || {}
      end

      def list
        input_dir = @options[:messages] || File.expand_path('~/Library/Messages')
        db_path = File.join(input_dir, 'chat.db')
        local_db_path, backup_dir = backup_db_if_needed(input_dir, db_path, @options[:backup])
        raise "Database not found at #{db_path}" unless File.exist?(db_path)

        begin
          db = SQLite3::Database.new(local_db_path, readonly: true)
          db.results_as_hash = true

          rows = []
          ab = nil
          unless @options[:no_address_book]
            ab_path, ab_backup = resolve_address_book_source(@options[:address_book], @options[:backup])
            if ab_path
              begin
                ab = AddressBookResolver.new(ab_path).tap(&:load!)
                tmp = Imsg::Query::Threads.contacts_list_from_address_book(db, ab, @options.merge(sort: @options[:sort] || 'message_count', order: @options[:order] || 'asc'), apply_row_level_date_filter: true)
                rows.concat(tmp)
              rescue
                # ignore and fallback
              ensure
                begin
                  FileUtils.remove_entry(ab_backup) if ab_backup && Dir.exist?(ab_backup)
                rescue
                end
              end
            end
          end
          if rows.empty?
            rows.concat(Imsg::Query::Threads.contacts_list(db, @options.merge(sort: @options[:sort] || 'message_count', order: @options[:order] || 'asc'), apply_row_level_date_filter: true))
          end

          # Always include coalesced groups
          rows.concat(Imsg::Query::Threads.groups_list(db, ab: ab, coalesce: true, options: @options.merge(sort: @options[:sort] || 'last_message_at', order: @options[:order] || 'desc'), apply_row_level_date_filter: true))

          # Unified sort
          Imsg::Query::Threads.sort_rows!(rows, sort: (@options[:sort] || 'last_message_at'), order: (@options[:order] || 'desc'))
          rows = rows.first(@options[:limit]) if @options[:limit]

          if @options[:count]
            puts rows.length
          else
            headings = ['Name', 'ID', 'First Message at', 'Last Message at', 'Message Count']
            table_rows = rows.map { |r| [r['name'], r['id'], r['first_message_at_local'] || '-', r['last_message_at_local'] || '-', (r['message_count'] || 0).to_i] }
            align = [:left, :left, :left, :left, :right]
            puts SimpleTable.render(headings: headings, rows: table_rows, align: align, repeat_header_at_bottom: true)
          end
        ensure
          db&.close if defined?(db)
          begin
            FileUtils.remove_entry(backup_dir) if backup_dir && Dir.exist?(backup_dir)
          rescue
          end
        end
      end

      private
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
    end
  end
end
