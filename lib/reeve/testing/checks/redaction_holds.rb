# frozen_string_literal: true

require "securerandom"

module Reeve
  module Testing
    module Checks
      # FR-011: a value declared sensitive appears in no ledger entry.
      #
      # Proved rather than inspected. The check calls the tool with a unique sentinel in
      # each declared-sensitive argument and then looks for that sentinel in every column
      # of the row that was written — including nested structures, since the redactor
      # recurses and so must the check.
      #
      # It also catches the quieter bug: `redact :ssn` on a tool whose argument is
      # actually named `customer_ssn`. That declaration compiles, registers, and redacts
      # nothing at all, and no amount of looking at written rows would reveal it.
      #
      #   Reeve::Checks::RedactionHolds.new(tool: InvoiceSearchTool, principal: alice).call
      class RedactionHolds < Base
        FILLER = "reeve-check"

        def initialize(tool:, principal:, arguments: {}, invoke: nil, ledger: nil)
          super(tool: tool, arguments: arguments, invoke: invoke, ledger: ledger)
          @principal = principal
        end

        def call
          return ledger_unavailable("redaction") unless ledger.available?

          inert = declared_names - accepted_names
          return inert_declaration(inert.first) unless inert.empty? || accepts_anything?

          names = names_to_probe
          return nothing_declared if names.empty?

          probe(names)
        end

        private

        def probe(names)
          sentinels = names.to_h { |name| [name, "reeve-sentinel-#{SecureRandom.hex(8)}"] }
          made = attempt(principal: @principal, arguments: probe_arguments(sentinels))
          return no_entry(names) if made.rows.empty?

          leak = first_leak(made.rows, sentinels)
          return held(names) if leak.nil?

          name, entry, column = leak
          failed(
            "expected #{tool_label} to redact #{name}, but the value passed for it appears " \
            "in audit entry #{entry.id}, in column #{column}",
            redacted: names, leaked: name, entry: entry.id, column: column
          )
        end

        def first_leak(entries, sentinels)
          entries.each do |entry|
            sentinels.each do |name, sentinel|
              column = column_containing(entry, sentinel)
              return [name, entry, column] if column
            end
          end
          nil
        end

        def column_containing(entry, sentinel)
          entry.attributes.each do |column, value|
            return column if value.to_s.include?(sentinel)
          end
          nil
        end

        def held(names)
          passed("#{tool_label} keeps #{names.join(', ')} out of the ledger entirely",
                 redacted: names)
        end

        def nothing_declared
          passed("#{tool_label} declares no redacted argument that it also accepts, so " \
                 "there is nothing for the ledger to expose",
                 redacted: [])
        end

        def no_entry(names)
          failed("expected #{tool_label} to redact #{names.join(', ')}, but the invocation " \
                 "wrote no audit entry to look in",
                 redacted: names)
        end

        def inert_declaration(name)
          failed(
            "expected #{tool_label} to redact #{name}, but #call accepts no such argument " \
            "(it accepts #{accepted_names.join(', ')}), so the declaration redacts nothing",
            redacted: declared_names, inert: name
          )
        end

        # Sentinels for the sensitive names, filler for anything else #call insists on.
        def probe_arguments(sentinels)
          required = call_parameters.filter_map { |type, name| name if type == :keyreq }
          filler = required.to_h { |name| [name, FILLER] }
          filler.merge(arguments).merge(sentinels)
        end

        def names_to_probe
          candidates = (declared_names + global_names).uniq
          accepts_anything? ? candidates : candidates & accepted_names
        end

        # Only the tool's own declaration is treated as a promise about *this* tool. The
        # process-wide list is a safety net, and is probed only where the tool happens to
        # take an argument by that name.
        def declared_names
          guard = declaration
          guard ? guard.redacted_arguments.dup : []
        end

        def global_names
          Array(Reeve.config.redact_arguments)
        end

        def accepted_names
          call_parameters.filter_map { |type, name| name if %i[key keyreq].include?(type) }
        end

        def accepts_anything?
          call_parameters.any? { |type, _| type == :keyrest }
        end

        def call_parameters
          return [] unless tool.respond_to?(:instance_method)

          tool.instance_method(:call).parameters
        rescue NameError
          []
        end
      end
    end
  end
end
