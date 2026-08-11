# frozen_string_literal: true

require "active_record"
require "logger"
require "tmpdir"
require "fileutils"

# The one database connection the ActiveRecord-backed specs share.
#
# It exists because there are two such harnesses — the authorization records and the
# audit ledger — and `establish_connection` is process-wide: whichever ran second used to
# drop the other's schema on the floor.
#
# A file database rather than :memory:, because sqlite gives every *connection* its own
# in-memory database, and the concurrency specs run invocations on their own threads,
# which check out their own connections.
module SpecDatabase
  PATH = File.join(Dir.tmpdir, "reeve-spec-#{Process.pid}.sqlite3")

  def self.connect!
    return if @connected

    ActiveRecord::Base.logger = nil
    ActiveRecord::Migration.verbose = false
    ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: PATH)
    at_exit { FileUtils.rm_f(PATH) }
    @connected = true
  end
end

SpecDatabase.connect!
