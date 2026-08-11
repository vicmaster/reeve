# frozen_string_literal: true

module Reeve
  module Audit
    # One ledger row: who called what, for whom, with what, and what came back.
    class Entry < ActiveRecord::Base
      self.table_name = TABLE_NAME
    end
  end
end
