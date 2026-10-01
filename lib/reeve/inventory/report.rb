# frozen_string_literal: true

module Reeve
  class Inventory
    # Every registered name, in one of four states, plus whatever the inventory declares
    # that the server does not register.
    #
    # The output names tools, tool classes and exemption reasons, and nothing else. It is
    # built before any invocation and knows no arguments, principals or records, so it is
    # safe to print in a CI log or a boot failure — there is nothing in it to redact.
    #
    #   reeve inventory: 6 registered
    #     4 protected and guarded
    #     1 routed through reeve but unguarded
    #     1 bypasses reeve
    #     0 exempted
    #   coverage: incomplete
    class Report
      attr_reader :entries

      def initialize(registered, routes, reasons)
        @entries = (classify(registered, routes, reasons) +
                    unregistered(registered, routes, reasons)).freeze
        freeze
      end

      # Every registered name is either guarded or deliberately exempt, and the inventory
      # names nothing the server does not register.
      #
      # That last part is not tidiness. A route for a name the server does not register is
      # almost always a rename or a typo — and the real name, the one being dispatched, is
      # then the one with no route.
      def complete?
        unguarded.empty? && bypassing.empty? && unregistered_entries.empty?
      end

      def registered
        entries.reject { |entry| entry.status == :unregistered }
      end

      def guarded
        select(:guarded)
      end

      def unguarded
        select(:unguarded)
      end

      def bypassing
        select(:bypass)
      end

      def exempted
        select(:exempt)
      end

      def unregistered_entries
        select(:unregistered)
      end

      # The classes routed to a registered name.
      def routed_tools
        entries.filter_map(&:tool).uniq
      end

      def to_s
        [summary, *entries.filter_map { |entry| detail(entry) }].join("\n")
      end

      def inspect
        "#<Reeve::Inventory::Report #{registered.size} registered, " \
          "coverage: #{complete? ? 'complete' : 'incomplete'}>"
      end

      private

      def select(status)
        entries.select { |entry| entry.status == status }
      end

      def classify(registered, routes, reasons)
        registered.map do |name|
          tool = routes[name]
          if tool
            status = Reeve.registry.for_class(tool) ? :guarded : :unguarded
            Entry.new(name: name, status: status, tool: tool)
          elsif reasons.key?(name)
            Entry.new(name: name, status: :exempt, reason: reasons[name])
          else
            Entry.new(name: name, status: :bypass)
          end
        end
      end

      def unregistered(registered, routes, reasons)
        (routes.keys | reasons.keys).reject { |name| registered.include?(name) }.map do |name|
          Entry.new(name: name, status: :unregistered, tool: routes[name],
                    reason: reasons[name])
        end
      end

      def summary
        ["reeve inventory: #{registered.size} registered", *counts.map { |line| "  #{line}" },
         "coverage: #{complete? ? 'complete' : 'incomplete'}"].join("\n")
      end

      def counts
        lines = [
          "#{guarded.size} protected and guarded",
          "#{unguarded.size} routed through reeve but unguarded",
          "#{bypassing.size} #{bypassing.size == 1 ? 'bypasses' : 'bypass'} reeve",
          "#{exempted.size} exempted"
        ]
        return lines if unregistered_entries.empty?

        lines << "#{unregistered_entries.size} declared but not registered"
      end

      # One line saying what is wrong and one saying what to do, for everything but a
      # guarded tool — which needs neither. Exemptions are listed even when coverage is
      # complete: a deliberate hole is still a hole, and it should be read every time.
      def detail(entry)
        case entry.status
        when :unguarded
          "\nUNGUARDED #{entry.name}\n  routed to #{label(entry.tool)}, which has no " \
          "guard_with declaration — reeve denies it, or runs it unscoped under " \
          ":allow_with_warning"
        when :bypass
          "\nBYPASS #{entry.name}\n  registered with the server but neither routed " \
          "through reeve nor exempted — route it to a guarded tool, or exempt it with a " \
          "reason"
        when :exempt
          "\nEXEMPT #{entry.name}\n  #{entry.reason}"
        when :unregistered
          what = entry.tool ? "routed to #{label(entry.tool)}" : "exempted"
          "\nNOT REGISTERED #{entry.name}\n  #{what}, but the server registers no tool " \
            "by that name — if it was renamed, the new name is unbound"
        end
      end

      def label(tool)
        tool.name || tool.inspect
      end
    end
  end
end
