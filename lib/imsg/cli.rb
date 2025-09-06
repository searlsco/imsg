require_relative 'app'

module Imsg
  class CLI
    def initialize(options = {})
      @options = options || {}
    end

    def list
      Imsg::App.new(@options).list
    end

    def export(*ids)
      Imsg::App.new(@options).export(*ids)
    end
  end
end
