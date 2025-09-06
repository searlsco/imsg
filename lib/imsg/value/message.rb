module Imsg
  module Value
    # Lightweight immutable value for a render-ready message
    Message = Struct.new(
      :message_id,
      :is_from_me,
      :author_handle,
      :author_name,
      :sent_at_local,
      :sent_at_iso,
      :sent_at_human,
      :day_label,
      :sent_at_label,
      :text,
      :text_html,
      :reactions,
      :attachments,
      :payment,
      :payment_amount,
      keyword_init: true
    )
  end
end

