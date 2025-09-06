require_relative 'command/export_conversation'
require_relative 'command/lists_conversations'

module Imsg
  class App
    def initialize(options = {})
      @options = options || {}
    end

    def list
      Imsg::Command::ListsConversations.new(@options).list
    end

    def export(*ids)
      Imsg::Command::ExportsConversations.new(@options).export(ids)
    end
  end
end

