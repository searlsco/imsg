require 'yaml'

module Imsg
  module Value
    class Config
      # Allowed option keys for validation/merge
      KEYS = [
        :messages,
        :address_book,
        :no_address_book,
        :backup,
        :limit,
        :from_date,
        :to_date,
        :outdir,
        :page_size,
        :skip_attachments,
        :open_after_export,
        :display_name,
        :flip,
        :sort,
        :order,
        :count
      ].freeze

      # Baseline defaults (command-specific fallbacks applied later)
      DEFAULTS = {
        messages: nil,
        address_book: nil,
        no_address_book: false,
        backup: true,
        limit: nil,
        from_date: nil,
        to_date: nil,
        outdir: nil,
        page_size: 1000,
        skip_attachments: false,
        open_after_export: nil, # nil -> infer by TTY
        display_name: nil,
        flip: false,
        sort: nil,
        order: nil,
        count: false
      }.freeze

      def self.merge(defaults: DEFAULTS, flags: {})
        (defaults || {}).merge(flags || {}).slice(*KEYS)
      end

      def self.symbolize_keys(h)
        h.each_with_object({}) do |(k, v), acc|
          key = k.respond_to?(:to_sym) ? k.to_sym : k
          acc[key] = v.is_a?(Hash) ? symbolize_keys(v) : v
        end
      end
    end
  end
end
