require_relative 'imsg/cli/argv_parser'

# Back-compat shim
module IMsg
  class ArgvParser
    def self.run(argv)
      Imsg::Cli::ArgvParser.run(argv)
    end
  end
end
