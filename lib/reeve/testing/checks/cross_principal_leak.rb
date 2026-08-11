# frozen_string_literal: true

module Reeve
  module Testing
    module Checks
      # FR-016, FR-003. The check the whole kit exists for: does this tool hand one
      # principal another principal's records?
      #
      # It answers by construction rather than by introspection. The contract's host-setup
      # rule is two fixture principals with *disjoint* records, so invoking the tool once
      # per principal and intersecting the identifiers that come back is decisive: a
      # non-empty intersection is a leak, and no policy needs to be read to know it.
      # A denial contributes an empty set — nothing returned is nothing leaked.
      #
      #   Reeve::Checks::CrossPrincipalLeak.new(
      #     tool: InvoiceSearchTool, principals: [alice, bob], arguments: { query: "AC" }
      #   ).call
      #
      # Two expectations, because two questions are worth asking:
      #
      #   :disjoint (default) — no identifier reaches two principals. The compliance
      #                         question, and the one FR-016 is written about.
      #   :nothing            — none of these principals may receive any record at all.
      #                         What `deny_access_for(stranger)` asserts.
      class CrossPrincipalLeak < Base
        EXPECTATIONS = %i[disjoint nothing].freeze

        def initialize(tool:, principals:, arguments: {}, expect: :disjoint, invoke: nil,
                       ledger: nil)
          unless EXPECTATIONS.include?(expect)
            raise ArgumentError,
                  "expect must be one of #{EXPECTATIONS.map(&:inspect).join(', ')}, " \
                  "got #{expect.inspect}"
          end

          super(tool: tool, arguments: arguments, invoke: invoke, ledger: ledger)
          @principals = Array(principals)
          @expect = expect
        end

        def call
          return no_principals if principals.empty?

          attempts = principals.map { |principal| attempt(principal: principal) }
          @expect == :nothing ? verify_nothing(attempts) : verify_disjoint(attempts)
        end

        private

        attr_reader :principals

        def no_principals
          failed("#{tool_label} cannot be checked for cross-principal leaks: no principals " \
                 "were supplied (the compliance suite needs two, with disjoint records)",
                 leaked: [])
        end

        # ---- :nothing -------------------------------------------------------------

        def verify_nothing(attempts)
          offenders = attempts.reject { |attempt| identifiers(attempt.records).empty? }
          return nothing_held(attempts) if offenders.empty?

          failed(nothing_message(offenders), leaked_details(offenders))
        end

        def nothing_held(attempts)
          passed(
            "#{tool_label} returned no records to " \
            "#{attempts.map { |a| principal_label(a.principal) }.join(', ')}",
            leaked: [], denials: attempts.filter_map { |a| a.denial&.rule }
          )
        end

        def nothing_message(offenders)
          offenders.map do |attempt|
            leaked = identifiers(attempt.records)
            "expected #{tool_label} to deny access for #{principal_label(attempt.principal)}, " \
              "but it returned #{pluralize(leaked.size, 'record')} that principal may not " \
              "see: #{format_identifiers(leaked)} #{provenance(attempt.entry)}"
          end.join("; ")
        end

        # ---- :disjoint ------------------------------------------------------------

        def verify_disjoint(attempts)
          leak = first_overlap(attempts)
          return disjoint_held(attempts) if leak.nil?

          owner, other, shared = leak
          failed(disjoint_message(owner, other, shared),
                 leaked: shared, rule: owner.entry&.rule,
                 principals: [principal_label(owner.principal),
                              principal_label(other.principal)])
        end

        def disjoint_message(owner, other, shared)
          "expected #{tool_label} to return no records belonging to another principal, " \
            "but it returned #{pluralize(shared.size, 'record')} to " \
            "#{principal_label(owner.principal)} that also belong to " \
            "#{principal_label(other.principal)}: #{format_identifiers(shared)} " \
            "#{provenance(owner.entry)}"
        end

        def first_overlap(attempts)
          attempts.combination(2).each do |owner, other|
            shared = identifiers(owner.records) & identifiers(other.records)
            return [owner, other, shared] unless shared.empty?
          end
          nil
        end

        def disjoint_held(attempts)
          total = attempts.sum { |attempt| identifiers(attempt.records).size }
          passed(
            "#{tool_label} returned no records belonging to another principal " \
            "(#{pluralize(attempts.size, 'principal')}, #{pluralize(total, 'record')})",
            leaked: [], denials: attempts.filter_map { |a| a.denial&.rule }
          )
        end

        def leaked_details(offenders)
          {
            leaked: offenders.flat_map { |attempt| identifiers(attempt.records) },
            rule: offenders.first.entry&.rule,
            principals: offenders.map { |attempt| principal_label(attempt.principal) }
          }
        end
      end
    end
  end
end
