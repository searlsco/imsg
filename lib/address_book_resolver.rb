require 'sqlite3'

class AddressBookResolver
  Contact = Struct.new(:key, :link_id, :pk, :name, :emails, :phones, :im_ids, keyword_init: true)

  def initialize(ab_dir)
    @ab_dir = ab_dir
    @db_path = resolve_db_path(ab_dir)
    @contacts = {}
  end

  attr_reader :contacts

  def load!
    db = SQLite3::Database.new(@db_path, readonly: true)
    db.results_as_hash = true
    # Pull basic contact identity rows
    rows = db.execute(<<-SQL)
      SELECT Z_PK AS pk, ZLINKID AS link_id,
             COALESCE(NULLIF(ZNAME,''), NULLIF(ZNICKNAME,''),
                      TRIM(COALESCE(ZFIRSTNAME,'') || ' ' || COALESCE(ZLASTNAME,'')),
                      NULLIF(ZORGANIZATION,'')) AS display
      FROM ZABCDRECORD
      WHERE Z_ENT IS NOT NULL
    SQL
    rows.each do |r|
      key = r['link_id'] && !r['link_id'].to_s.empty? ? r['link_id'] : "pk:#{r['pk']}"
      @contacts[key] = Contact.new(key: key, link_id: r['link_id'], pk: r['pk'], name: (r['display'] || '').strip, emails: [], phones: [], im_ids: [])
    end
    # Emails
    db.execute('SELECT COALESCE(ZOWNER, Z22_OWNER) AS owner, ZADDRESS AS addr FROM ZABCDEMAILADDRESS').each do |r|
      c = @contacts.values.find { |ct| ct.pk == r['owner'] }
      next unless c
      email = r['addr'].to_s.strip.downcase
      c.emails << email unless email.empty?
    end
    # Phones
    db.execute('SELECT COALESCE(ZOWNER, Z22_OWNER) AS owner, ZFULLNUMBER AS full, ZCOUNTRYCODE AS cc, ZAREACODE AS ac, ZLOCALNUMBER AS ln FROM ZABCDPHONENUMBER').each do |r|
      c = @contacts.values.find { |ct| ct.pk == r['owner'] }
      next unless c
      e164 = e164_from_components(r['full'], r['cc'], r['ac'], r['ln'])
      c.phones << e164 if e164
    end
    # iMessage/other messaging addresses
    db.execute('SELECT COALESCE(ZOWNER, Z22_OWNER) AS owner, ZADDRESS AS addr FROM ZABCDMESSAGINGADDRESS').each do |r|
      c = @contacts.values.find { |ct| ct.pk == r['owner'] }
      next unless c
      v = r['addr'].to_s.strip
      next if v.empty?
      c.im_ids << v
    end
    @contacts
  ensure
    db&.close
  end

  # Accept either a directory (root of .abbu) or a direct path to AddressBook-v22.abcddb.
  # Prefer Sources/*/AddressBook-v22.abcddb if present (those contain the actual records).
  def resolve_db_path(path)
    p = File.expand_path(path.to_s)
    return p if File.file?(p) && File.basename(p) =~ /AddressBook-v\d+\.abcddb\z/
    # Candidates from likely roots near the provided directory, plus common system locations
    candidates = []
    if File.directory?(p)
      ancestors = [p, File.dirname(p), File.dirname(File.dirname(p))].uniq
      roots = []
      ancestors.each do |anc|
        roots << anc
        roots << File.join(anc, 'Application Support', 'AddressBook')
        roots << File.join(anc, 'Library', 'Application Support', 'AddressBook')
        roots << File.join(anc, 'Data', 'Library', 'Application Support', 'AddressBook')
        roots << File.join(anc, 'Containers', 'com.apple.AddressBook', 'Data', 'Library', 'Application Support', 'AddressBook')
        roots << File.join(anc, 'Group Containers', 'group.com.apple.addressbook', 'Library', 'Application Support', 'AddressBook')
      end
      # Always include canonical home-based roots as a last resort
      home = File.expand_path('~')
      roots << File.join(home, 'Library', 'Application Support', 'AddressBook')
      roots << File.join(home, 'Library', 'Containers', 'com.apple.AddressBook', 'Data', 'Library', 'Application Support', 'AddressBook')
      roots.uniq!
      roots.select! { |r| File.directory?(r) }
      roots.each do |root|
        candidates << File.join(root, 'AddressBook-v22.abcddb')
        Dir.glob(File.join(root, 'AddressBook-v*.abcddb')).each { |f| candidates << f }
        Dir.glob(File.join(root, 'Sources', '*', 'AddressBook-v*.abcddb')).each { |f| candidates << f }
      end
    end
    # Pick the largest existing file as heuristic for the real one
    candidates = candidates.select { |f| File.file?(f) }
    return candidates.max_by { |f| File.size(f) } if candidates.any?
    # Fallback to provided path (likely to error later, but better message)
    File.join(p, 'AddressBook-v22.abcddb')
  end

  # Return a canonical digits-only representation if available, without
  # assuming or prepending any default country code. Prefer the supplied
  # full number; else join CC/area/local when present. If nothing usable,
  # return nil.
  def e164_from_components(full, cc, ac, ln)
    if full && !full.to_s.strip.empty?
      s = full.to_s.gsub(/\D+/, '')
      return "+#{s}" unless s.empty?
    end
    digits = ''
    digits << cc.to_s.gsub(/\D+/, '') if cc && !cc.to_s.empty?
    if ac && ln
      digits = digits + ac.to_s.gsub(/\D+/, '') + ln.to_s.gsub(/\D+/, '')
    end
    return nil if digits.empty?
    "+#{digits}"
  end
end
