require 'optparse'
require_relative '../value/config'

module Imsg
  module Cli
    class ArgvParser
      def self.apply_common_options(o, opts)
        o.on('-m DIR', '--messages DIR', 'macOS Messages database directory. Default: ~/Library/Messages') { |v| opts[:messages] = v }
        o.on('-a PATH', '--address-book PATH', 'Contacts database or export (.abbu or .abcddb). Default: reads from ~/Library/Contacts') { |v| opts[:address_book] = v }
        o.on('--no-address-book', 'Do not cross-reference Contacts; list threads by email or phone') { opts[:no_address_book] = true }
        o.on('--[no-]backup', 'Read via a SQLite backup copy for integrity. Default: on') { |v| opts[:backup] = v }
        o.on('--limit N', Integer, 'Limit number of conversations. Default: all') { |v| opts[:limit] = v }
        o.on('--from-date ISO8601', 'Only include messages on/after this timestamp (e.g., 2022-01-01T00:00:00)') { |v| opts[:from_date] = v }
        o.on('--to-date ISO8601', 'Only include messages on/before this date (e.g., 2024-12-15)') { |v| opts[:to_date] = v }
      end

      def self.parse(argv)
        return [:help, {}, []] if argv.nil? || argv.empty?
        cmd = argv.shift
        case cmd
        when 'list' then parse_list(argv)
        when 'export' then parse_export(argv)
        when '-h', '--help', 'help' then [:help, {}, []]
        else
          [:help, {}, []]
        end
      end

      def self.parse_list(argv)
        opts = Imsg::Value::Config.merge
        parser = OptionParser.new do |o|
          o.banner = 'Usage: imsg list [options]'
          apply_common_options(o, opts)
          o.on('--sort FIELD', ['last_message_at','name','message_count'], 'Sort by: last_message_at|name|message_count') { |v| opts[:sort] = v }
          o.on('--asc', 'Sort ascending') { opts[:order] = 'asc' }
          o.on('--desc', 'Sort descending') { opts[:order] = 'desc' }
          o.on('--count', 'Print only the number of rows and exit') { opts[:count] = true }
        end
        begin
          parser.parse!(argv)
        rescue OptionParser::ParseError => e
          return [:error, { message: e.message, usage: parser.to_s }, []]
        end
        opts[:sort]  ||= 'message_count'
        opts[:order] ||= 'asc'
        [:list, opts, []]
      end

      def self.parse_export(argv)
        opts = Imsg::Value::Config.merge
        parser = OptionParser.new do |o|
          o.banner = 'Usage: imsg export [options] [CHAT_IDS...]'
          apply_common_options(o, opts)
          o.on('-o DIR', '--outdir DIR', 'Output directory') { |v| opts[:outdir] = v }
          o.on('--page-size N', Integer, 'Messages per page (default: 1000)') { |v| opts[:page_size] = v }
          o.on('--skip-attachments', 'Do not copy or render attachments') { opts[:skip_attachments] = true }
          o.on('--[no-]open-after-export', 'Open export in browser after completion (default: on for interactive TTY only)') { |v| opts[:open_after_export] = v }
          # New: --display-name (single-chat export only)
          o.on('--display-name NAME', 'Override display name (single chat export only)') { |v| opts[:display_name] = v }
          # Back-compat: accept --name but map to display_name
          o.on('--name NAME', 'Deprecated: use --display-name NAME') { |v| opts[:display_name] = v }
          o.on('--flip-perspective', 'Invert sender/recipient roles in the viewer (me<->them)') { opts[:flip] = true }
          o.on('--sort FIELD', ['last_message_at','name','message_count'], 'Sort processing/limit order by: last_message_at|name|message_count') { |v| opts[:sort] = v }
          o.on('--asc', 'Sort processing/limit in ascending order') { opts[:order] = 'asc' }
          o.on('--desc', 'Sort processing/limit in descending order') { opts[:order] = 'desc' }
        end
        begin
          parser.parse!(argv)
        rescue OptionParser::ParseError => e
          return [:error, { message: e.message, usage: parser.to_s }, []]
        end
        opts[:sort]  ||= 'last_message_at'
        opts[:order] ||= 'desc'
        chats = argv.dup
        [:export, opts, chats]
      end

      def self.run(argv)
        cmd, opts, rest = parse(argv.dup)
        case cmd
        when :list
          require_relative '../..//imsg/cli'
          Imsg::CLI.new(opts).list
          0
        when :export
          require_relative '../..//imsg/cli'
          Imsg::CLI.new(opts).export(*rest)
          0
        when :help
          puts <<~USAGE
            imsg list [options]
            imsg export [options] [CHAT_IDS...]

            Use --help with a subcommand for options.
          USAGE
          0
        when :error
          $stderr.puts("Error: #{opts[:message]}")
          $stderr.puts
          $stderr.puts(opts[:usage])
          1
        else
          1
        end
      end
    end
  end
end
