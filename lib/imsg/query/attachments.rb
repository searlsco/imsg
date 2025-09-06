module Imsg
  module Query
    module Attachments
      module_function

      # Returns { message_id(Integer) => [attachment_hash, ...] }
      def fetch(db, message_ids)
        return {} if message_ids.nil? || message_ids.empty?
        result = Hash.new { |h, k| h[k] = [] }
        batch_size = 800
        message_ids.each_slice(batch_size) do |batch|
          placeholders = (['?'] * batch.length).join(',')
          query = <<-SQL
            SELECT maj.message_id,
                   a.guid,
                   a.filename,
                   a.transfer_name,
                   a.mime_type
            FROM message_attachment_join maj
            JOIN attachment a ON a.ROWID = maj.attachment_id
            WHERE maj.message_id IN (#{placeholders})
          SQL
          db.execute(query, batch).each do |att|
            result[att['message_id']] << att
          end
        end
        result
      end
    end
  end
end

