require 'time'
require_relative '../util/time_util'
require_relative '../util/text_util'
require_relative '../util/handle_util'
require_relative '../util/attachment_util'
require_relative 'attachment'
require_relative '../value/message'

module Imsg
  module Project
    module Message
      module_function

      # Returns a Hash (render-ready) or nil if the message should be skipped
      def project(row, attachments_for_row, is_group:, friendly_names: {})
        return nil unless row

        # Filter invisible attachments (pluginpayload)
        visible_atts = (attachments_for_row || []).reject { |a| Imsg::Util::AttachmentUtil.hide?(a) }

        # Visibility: hide system/placeholder with no text and no visible attachments
        txt = (row['text'] || '').to_s.strip
        invisible = txt.empty? && visible_atts.empty? && (row['associated_message_guid'].to_s.empty?) && (row['item_type'].to_i != 0 || row['is_system_message'].to_i == 1)
        return nil if invisible

        # Payment heuristic (conservative)
        is_payment = false
        amt = nil
        begin
          bb = row['balloon_bundle_id'].to_s
          if bb =~ /(applepay|passkit|cash|payment)/i
            is_payment = true
          end
          if !is_payment && (row['text'].to_s =~ /apple\s*cash/i)
            is_payment = true
          end
          if row['text']
            if (md = row['text'].match(/\$\s*([0-9][0-9,]*(?:\.[0-9]{2})?)/))
              amt = "$#{md[1]}"
            end
          end
        rescue
        end

        sent_local = row['sent_at_local']
        iso = Imsg::Util::TimeUtil.iso(sent_local)
        human = Imsg::Util::TimeUtil.time_human(sent_local)
        day = Imsg::Util::TimeUtil.day_label(sent_local)
        label = [day, human].reject { |s| s.nil? || s.empty? }.join(' ')
        author_name = is_group && row['is_from_me'].to_i != 1 ? Imsg::Util::HandleUtil.resolve_author_name(friendly_names, row['author_handle']) : nil

        Imsg::Value::Message.new(
          message_id: row['message_id'],
          is_from_me: row['is_from_me'],
          author_handle: row['author_handle'],
          author_name: author_name,
          sent_at_local: sent_local,
          sent_at_iso: iso,
          sent_at_human: human,
          day_label: day,
          sent_at_label: label,
          text: txt,
          text_html: Imsg::Util::TextUtil.linkify(txt),
          reactions: (row['reactions'] || []),
          attachments: visible_atts.map { |a| Imsg::Project::Attachment.project(a) },
          payment: is_payment,
          payment_amount: amt
        ).to_h
      end
    end
  end
end

