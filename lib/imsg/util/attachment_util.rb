module Imsg
  module Util
    module AttachmentUtil
      module_function

      # Decide whether an attachment record should be hidden entirely from renderers.
      def hide?(att)
        return false unless att
        name = att['transfer_name'] || (att['filename'] && File.basename(att['filename']))
        mime = att['mime_type']
        return true if name && name.to_s.downcase.end_with?('.pluginpayloadattachment')
        return true if mime && mime.to_s.downcase.include?('pluginpayload')
        false
      end

      # Infer coarse kind from mime and filename: image | video | audio | file
      def kind_for(mime_type, name)
        n = (name || '').to_s.downcase
        m = (mime_type || '').to_s.downcase
        return 'image' if m.start_with?('image/') || n =~ /\.(jpe?g|png|gif|heic|heif|webp)\z/
        return 'video' if m.start_with?('video/') || n =~ /\.(mov|mp4|m4v|webm)\z/
        return 'audio' if m.start_with?('audio/') || n =~ /\.(m4a|aac|mp3|wav|aiff?)\z/
        'file'
      end
    end
  end
end

