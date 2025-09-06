module Imsg
  module Query
    module AddressBook
      module_function

      # Resolve an ab: selector to an AddressBook contact key
      # Supports ab:<link_id> or ab:pk:<primary_key>
      def resolve_selector_to_key(ab, selector)
        return nil unless ab && selector
        if selector =~ /^ab:(.+)$/i
          rest = $1
          if rest.start_with?('pk:')
            pk = rest.sub(/^pk:/, '')
            found = ab.contacts.values.find { |c| c.pk.to_s == pk.to_s }
            return found&.key
          else
            found = ab.contacts.values.find { |c| c.link_id.to_s == rest }
            return found&.key
          end
        end
        nil
      end

      # Slow linear scan fallback
      def find_contact_for_handle(ab, handle)
        return nil unless ab && handle
        s = handle.to_s.downcase
        digits = s.gsub(/\D+/, '')
        ab.contacts.each_value do |c|
          return c if c.emails.any? { |e| e.downcase == s }
          return c if c.phones.any? { |p| p.downcase == s || p.gsub(/\D+/, '') == digits || p.gsub(/\D+/, '')[-10..-1] == digits[-10..-1] }
          return c if c.im_ids.any? { |mid|
            t = mid.to_s.downcase
            t == s || (t.start_with?('tel:') && t.sub(/^tel:/,'').gsub(/\D+/, '') == digits)
          }
        end
        nil
      end
    end
  end
end

