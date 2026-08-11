# frozen_string_literal: true

# A minimal ActiveRecord world for the authorization specs: two owners, two record types,
# and a policy per type. ActiveRecord is a development dependency only — this file is
# required by the specs that need it, never by the library.
require "active_record"
require "logger"
require "tmpdir"

ActiveRecord::Base.logger = nil

# A file database rather than :memory: — sqlite gives every connection its own in-memory
# database, so the concurrency specs, which run each invocation on its own thread, would
# otherwise find an empty schema.
REEVE_SPEC_DATABASE = File.join(Dir.tmpdir, "reeve-spec-#{Process.pid}.sqlite3")

unless ActiveRecord::Base.connected?
  ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: REEVE_SPEC_DATABASE)
  at_exit { FileUtils.rm_f(REEVE_SPEC_DATABASE) }
end

ActiveRecord::Schema.verbose = false
ActiveRecord::Schema.define do
  create_table :invoices, force: true do |t|
    t.string :number
    t.integer :owner_id
    t.boolean :overdue, default: false
  end

  create_table :memos, force: true do |t|
    t.string :body
    t.integer :owner_id
  end
end

class Invoice < ActiveRecord::Base; end
class Memo < ActiveRecord::Base; end

# A principal is anything with an id; these specs use a plain struct to make the point
# that reeve never requires a particular user model.
Owner = Struct.new(:id)

# Plain policy objects — the adapter that is always available.
class InvoicePolicy
  def self.authorize(principal, _action, record)
    return false if principal.nil?
    return true if record.nil?

    record.owner_id == principal.id
  end

  def self.scope(principal, relation)
    relation.where(owner_id: principal.id)
  end
end

class MemoPolicy
  def self.authorize(principal, _action, record)
    return false if principal.nil?
    return true if record.nil?

    record.owner_id == principal.id
  end

  def self.scope(principal, relation)
    relation.where(owner_id: principal.id)
  end
end

# A type nothing governs, for the unpoliced-type path.
class Unpoliced
  attr_reader :id

  def initialize(id) = @id = id
end
