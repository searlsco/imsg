require_relative '../util/attachment_util'
require_relative '../value/attachment'

module Imsg
  module Project
    module Attachment
      module_function

      def project(raw)
        return nil unless raw
        # Determine kind if not already present
        kind = (raw['kind'] || Imsg::Util::AttachmentUtil.kind_for(raw['mime_type'], raw['transfer_name'] || raw['filename'])).to_s
        Imsg::Value::Attachment.new(
          guid: raw['guid'],
          filename: raw['filename'],
          transfer_name: raw['transfer_name'],
          mime_type: raw['mime_type'],
          width: raw['width'],
          height: raw['height'],
          kind: kind,
          missing: !!raw['missing']
        ).to_h
      end
    end
  end
end

