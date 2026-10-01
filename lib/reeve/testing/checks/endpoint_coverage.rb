# frozen_string_literal: true

module Reeve
  module Testing
    module Checks
      # Whether the run covered the endpoint, or only the tools reeve was told about.
      #
      # Every other check walks a population reeve assembled itself: the classes that
      # included `Reeve::Guard`. A server that dispatches some tools without ever handing
      # them to reeve leaves them out of that population, and the run goes green on the
      # subset it could see. This check compares the run against the host's own list of
      # registered names (`config.inventory`), so a green run can only mean the endpoint.
      #
      # Four answers, and only one of them is a pass:
      #
      # * **no inventory declared** — skipped. Reeve cannot know what the server registers
      #   unless told, and a pass here would be the green that means "did not look".
      # * **a subset** — skipped, when the host narrowed the run with `compliance_tools` or
      #   `tools:`. That is the incremental-adoption path; the run says what it certified
      #   and that it is not the endpoint, without turning the build red mid-retrofit.
      # * **incomplete** — failed: a registered tool bypasses reeve or reaches it unguarded,
      #   and the run claimed to cover everything.
      # * **complete** — passed.
      #
      #   Reeve::Checks::EndpointCoverage.new.call
      #   Reeve::Checks::EndpointCoverage.new(inventory: McpInventory).call
      class EndpointCoverage < Base
        def initialize(inventory: :configured, tools: nil, ledger: nil)
          super(ledger: ledger)
          @inventory = inventory == :configured ? Reeve.config.inventory : inventory
          @tools = tools
        end

        def call
          return unverified if inventory.nil?

          report = inventory.report
          if narrowed?
            subset(report)
          elsif report.complete?
            complete(report)
          else
            incomplete(report)
          end
        rescue StandardError => e
          failed("the endpoint inventory could not be read, so its coverage is unknown: " \
                 "#{e.class}: #{e.message}", coverage: :unknown)
        end

        private

        attr_reader :inventory

        def narrowed?
          !@tools.nil? || Testing.compliance_tools_narrowed?
        end

        def certified
          @certified ||= @tools || Testing.compliance_tools
        end

        def unverified
          skipped(
            "no endpoint inventory is declared, so this run certifies the " \
            "#{pluralize(certified.size, 'tool')} reeve knows about and cannot say whether " \
            "the server dispatches others outside it — set config.inventory to a " \
            "Reeve::Inventory to verify the endpoint",
            coverage: :unverified
          )
        end

        def complete(report)
          passed(
            "every one of the #{pluralize(report.registered.size, 'tool')} the server " \
            "registers is protected and guarded (#{report.guarded.size}) or exempted " \
            "(#{report.exempted.size})",
            coverage: :complete
          )
        end

        def incomplete(report)
          failed(
            "expected every tool the server registers to be protected by reeve or " \
            "exempted, but #{gaps(report)}\n\n#{report}",
            coverage: :incomplete
          )
        end

        # Complete coverage with a narrowed run is still a subset: the inventory is sound,
        # but this run did not certify all of it.
        def subset(report)
          routed = report.routed_tools
          missing = routed - certified
          lines = [
            "this run certifies a subset, not the endpoint: " \
            "#{(routed - missing).size} of the #{pluralize(routed.size, 'tool')} routed " \
            "through reeve (compliance_tools or tools: narrowed it)"
          ]
          lines << "not certified: #{missing.map { |tool| tool.name || tool.inspect }.join(', ')}" \
            unless missing.empty?
          lines << "" << report.to_s unless report.complete?

          skipped(lines.join("\n"), coverage: :subset)
        end

        def gaps(report)
          [
            gap(report.bypassing, "bypasses it", "bypass it"),
            gap(report.unguarded, "is routed through it unguarded",
                "are routed through it unguarded"),
            gap(report.unregistered_entries, "declared in the inventory is not registered",
                "declared in the inventory are not registered")
          ].compact.join(", ")
        end

        def gap(entries, one, many)
          return nil if entries.empty?

          "#{entries.size} #{entries.size == 1 ? one : many}"
        end

        # Only this check can come back with nothing established either way.
        def skipped(message, details = {})
          Result.skipped(check: check_name, message: message, details: details)
        end

        def base_details
          {}
        end
      end
    end
  end
end
