# frozen_string_literal: true

module Reeve
  module Testing
    module Checks
      # What every check shares: a tool, a way to invoke it, a window onto the ledger, and
      # the vocabulary its failure messages are written in.
      #
      # Plain Ruby, deliberately. Nothing under checks/ may reference RSpec or Minitest,
      # because the whole point of this layer is that a rake task, a deploy gate or a
      # boot-time assertion can run it with neither framework installed (FR-026).
      class Base
        # One attempt to call the tool: what came back, or what stopped it, plus the
        # ledger rows the attempt produced.
        Attempt = Struct.new(:principal, :records, :denial, :error, :rows,
                             keyword_init: true) do
          def denied?
            !denial.nil?
          end

          def failed?
            !error.nil?
          end

          def entry
            rows.last
          end
        end

        def self.check_name
          name.to_s.split("::").last
        end

        def initialize(tool: nil, arguments: {}, invoke: nil, ledger: nil)
          @tool      = tool
          @arguments = arguments
          @invoke    = invoke || Reeve.method(:invoke)
          @ledger    = ledger || Ledger.default
        end

        def call
          raise NotImplementedError, "#{self.class} must implement #call"
        end

        def check_name
          self.class.check_name
        end

        private

        attr_reader :tool, :arguments, :invoke, :ledger

        # Runs the tool once and reports rather than raises: a check never blows up on the
        # violation it exists to find.
        def attempt(principal:, arguments: self.arguments)
          marker = ledger.marker
          records = invoke.call(tool: tool, arguments: arguments, principal: principal)
          build_attempt(principal, marker, records: records)
        rescue Reeve::DeniedError => e
          build_attempt(principal, marker, denial: e)
        rescue StandardError => e
          build_attempt(principal, marker, error: e)
        end

        def build_attempt(principal, marker, records: nil, denial: nil, error: nil)
          Attempt.new(
            principal: principal, records: records, denial: denial, error: error,
            rows: ledger.entries_after(marker)
          )
        end

        def passed(message, details = {})
          Result.passed(check: check_name, message: message, details: base_details.merge(details))
        end

        def failed(message, details = {})
          Result.failed(check: check_name, message: message, details: base_details.merge(details))
        end

        def base_details
          { tool: tool_label }
        end

        def ledger_unavailable(what)
          failed("#{what} cannot be verified for #{tool_label}: #{ledger.unavailable_reason}",
                 ledger: :unavailable)
        end

        # The name a developer will recognise in a failure: the constant, not the
        # snake_cased protocol name the ledger stores.
        def tool_label
          return "the ledger" if tool.nil?

          tool.respond_to?(:name) && tool.name ? tool.name : tool.to_s
        end

        def declaration
          return nil if tool.nil?

          Reeve.registry.for_class(tool)
        end

        def guard_label
          guard = declaration
          guard ? guard.policy_name : "none"
        end

        def principal_label(principal)
          return "no principal" if principal.nil?

          identifier = principal.respond_to?(:id) ? principal.id : principal
          "#{principal.class.name}##{identifier}"
        end

        # [["Invoice", "7"], ...] — the type and identity of everything the tool returned
        # that has an identity at all. A derived value (a count, a summary) has none, and
        # is reported as such rather than silently compared.
        def identifiers(records)
          collection(records).filter_map do |record|
            next unless identity?(record)

            [record.class.name, record.id.to_s]
          end
        end

        def collection(records)
          return [] if records.nil?
          return records.to_a if records.respond_to?(:to_a) && !records.is_a?(Hash)

          [records]
        end

        def identity?(record)
          record.respond_to?(:id) && record.class.respond_to?(:name) && !record.class.name.nil?
        end

        def format_identifiers(pairs)
          pairs.map { |type, id| "#{type}##{id}" }.join(", ")
        end

        # "(guard: InvoicePolicy, decision: allow via InvoicePolicy#index)" — the two facts
        # a developer needs next after learning that a tool leaked.
        def provenance(entry)
          parts = ["guard: #{guard_label}"]
          parts << "decision: #{entry.outcome} via #{entry.rule}" if entry
          "(#{parts.join(', ')})"
        end

        def pluralize(count, noun)
          count == 1 ? "1 #{noun}" : "#{count} #{noun}s"
        end
      end
    end
  end
end
