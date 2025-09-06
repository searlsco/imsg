module Imsg
  module Value
    # Lightweight immutable value for a render-ready attachment
    Attachment = Struct.new(
      :guid,
      :filename,
      :transfer_name,
      :mime_type,
      :width,
      :height,
      :kind,
      :missing,
      keyword_init: true
    )
  end
end

