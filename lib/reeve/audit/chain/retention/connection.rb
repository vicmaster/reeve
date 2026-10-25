# frozen_string_literal: true

module Reeve
  module Audit
    class Chain
      module Retention
        # The guard on config.ledger_retention_connection (specs/005 FR-006; constitution II,
        # 1.1.0): the purge deletes only through a connection that reaches the ledger's own
        # database and is not the application's.
        #
        # "Not the application's" is told by the username, which is all a connection config
        # says about the role behind it. SQLite has no roles at all, so there the guard can
        # only say so.
        class Connection
          SQLITE_WARNING = "SQLite has no database roles, so the retention connection cannot be " \
                           "told apart from the application's; on a server database it must be"

          SAME_DATABASE = %i[adapter database host port].freeze

          def initialize(retention, entry_class:)
            @retention = retention
            @entry_class = entry_class
          end

          # nil, or why the purge must refuse: :no_retention_connection, :other_database,
          # :application_role.
          def problem
            return :no_retention_connection if @retention.nil?
            return :other_database unless same_database?

            if roles? && retention_config[:username].to_s == ledger_config[:username].to_s
              :application_role
            end
          end

          def warnings
            !@retention.nil? && !roles? ? [SQLITE_WARNING] : []
          end

          def pool
            @retention.connection_pool
          end

          private

          def same_database?
            SAME_DATABASE.all? { |key| retention_config[key].to_s == ledger_config[key].to_s }
          end

          def roles?
            !ledger_config[:adapter].to_s.include?("sqlite")
          end

          def retention_config
            @retention.connection_db_config.configuration_hash
          end

          def ledger_config
            @entry_class.connection_db_config.configuration_hash
          end
        end
      end
    end
  end
end
