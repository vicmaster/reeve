# frozen_string_literal: true

module Reeve
  # The host's whole tool inventory, stated against what reeve was told about.
  #
  # Reeve only sees an invocation that reaches `Reeve.invoke`. A server that registers its
  # tools as names and handler blocks can route some of them through the envelope and
  # dispatch the rest directly, and the direct ones are invisible: neither guarded nor
  # reported as unguarded. Every guarantee reeve makes — deny by default, scoping, the
  # ledger — is skipped together for them, and nothing anywhere says so. The registry
  # cannot answer "is every tool this endpoint dispatches protected?" because the tools
  # that are not are, by construction, the ones it never heard of.
  #
  # The inventory makes the host's list of registered names the thing being checked:
  #
  #   McpInventory = Reeve::Inventory.new(
  #     registered: -> { McpServer.tool_names },
  #     routed: -> { { "search_invoices" => InvoiceSearchTool } },
  #     exemptions: { "healthcheck" => { reason: "returns no application data" } }
  #   )
  #
  #   McpInventory.verify!   # at boot, or in CI
  #
  # and, optionally, the place the host dispatches through, so that a name it has no
  # entry for is refused rather than run:
  #
  #   McpInventory.dispatch(name, arguments: args) { handlers.fetch(name).call(args) }
  #
  # Every part takes a value or a callable returning one. A Rails initializer cannot
  # reference application constants, and a server registers its tools after the
  # initializer runs, so the lists are read when asked for rather than when declared.
  #
  # Nothing here depends on an MCP library. A list of names is the whole protocol.
  class Inventory
    # One registered name, classified. +tool+ is the class it is routed to, if any;
    # +reason+ is the stated reason for an exemption.
    Entry = Struct.new(:name, :status, :tool, :reason, keyword_init: true)

    def initialize(registered:, routed: {}, exemptions: {})
      @registered = registered
      @routed     = routed
      @exemptions = exemptions

      # Literal values are checked now, so a blank exemption reason fails on the line that
      # declared it. Callables cannot be until they are asked; #report checks those.
      resolve unless [registered, routed, exemptions].any? { |part| part.respond_to?(:call) }
    end

    # The classification, read fresh. Raises ArgumentError if the inventory is malformed:
    # a report built from a list it could not read would be a report about nothing.
    def report
      Report.new(*resolve)
    end

    # The strict gate: the report when coverage is complete, IncompleteInventoryError
    # otherwise. Call it where failing is what you want — boot, a deploy step, CI.
    def verify!
      report.tap do |result|
        raise IncompleteInventoryError, result unless result.complete?
      end
    end

    # The tool classes the inventory routes through reeve. The testing kit certifies these.
    def routed_tools
      routes.values.uniq
    end

    # The dispatch boundary. A host that sends every tool call through here cannot have a
    # tool that bypasses reeve, because the three answers are exhaustive:
    #
    # * **routed** — runs through `Reeve.invoke` with the class it is routed to. A handler
    #   block, if given, is the body, so a registry of blocks needs one guarded class per
    #   tool to say which policy governs it and nothing else.
    # * **exempt** — the handler runs as it would have without reeve. That is what the
    #   exemption says, and why it needs a reason.
    # * **neither** — governed by `config.unguarded_tools`, exactly like a tool with no
    #   guard. Under `:deny`, the default, the call is refused with `unbound_tool`; under
    #   `:allow_with_warning` it runs unscoped. Either way it is recorded, so a name the
    #   inventory missed shows up in the ledger rather than nowhere.
    #
    # +registered+ is not consulted. The host's own dispatcher already decided the name
    # exists; what this decides is whether reeve stands in front of it.
    def dispatch(name, arguments: {}, principal: :unset, agent: nil, metadata: {}, &handler)
      name = name.to_s
      tool = routes[name]
      if tool
        return Reeve.invoke(tool: tool, arguments: arguments, principal: principal,
                            agent: agent, metadata: metadata, &handler)
      end

      if handler.nil?
        raise ArgumentError, "#{name} is not routed to a tool, so dispatch needs the " \
                             "handler block that runs it"
      end

      return handler.call if exemption_reasons.key?(name)

      dispatch_unbound(name, arguments: arguments, principal: principal, agent: agent,
                             metadata: metadata, &handler)
    end

    def inspect
      "#<Reeve::Inventory>"
    end

    private

    def resolve
      names = registered_names
      routes = self.routes
      reasons = exemption_reasons

      both = routes.keys & reasons.keys
      unless both.empty?
        raise ArgumentError, "a tool is either routed through reeve or exempt from it, " \
                             "not both: #{both.join(', ')}"
      end

      [names, routes, reasons]
    end

    def registered_names
      names = read(:registered, @registered)
      unless names.respond_to?(:to_a) && !names.is_a?(Hash)
        raise ArgumentError, "registered must list tool names, got #{names.inspect}"
      end

      names.to_a.map { |name| name_from(:registered, name) }.uniq
    end

    def routes
      read_hash(:routed, @routed).to_h do |name, tool|
        unless tool.is_a?(Class)
          raise ArgumentError, "routed must map each name to a tool class; " \
                               "#{name} maps to #{tool.inspect}"
        end

        [name_from(:routed, name), tool]
      end
    end

    # An exemption with no reason is a hole someone forgot about. With one, it is a
    # decision someone can be asked about.
    def exemption_reasons
      read_hash(:exemptions, @exemptions).to_h do |name, options|
        name = name_from(:exemptions, name)
        reason = options.is_a?(Hash) ? (options[:reason] || options["reason"]) : nil
        if reason.nil? || reason.to_s.strip.empty?
          raise ArgumentError, "the exemption for #{name} needs a reason, e.g. " \
                               "{ \"#{name}\" => { reason: \"returns no application data\" } }"
        end

        [name, reason.to_s.strip]
      end
    end

    def read_hash(part, source)
      value = read(part, source)
      return value if value.is_a?(Hash)

      raise ArgumentError, "#{part} must be a Hash keyed by tool name, got #{value.inspect}"
    end

    def read(part, source)
      value = source.respond_to?(:call) ? source.call : source
      raise ArgumentError, "#{part} is nil" if value.nil?

      value
    end

    def name_from(part, name)
      string = name.respond_to?(:to_str) || name.is_a?(Symbol) ? name.to_s.strip : nil
      return string unless string.nil? || string.empty?

      raise ArgumentError, "#{part} contains a blank or non-string tool name: #{name.inspect}"
    end

    # A name the inventory has no entry for still goes through the envelope, under its
    # own name and with nothing to look up. The registry answer below is what makes the
    # refusal name the real cause — the inventory, not a missing `guard_with` on a class
    # that may not exist.
    def dispatch_unbound(name, arguments:, principal:, agent:, metadata:, &handler)
      config = Reeve.config.with_principal(principal)
      context = Context.new(tool_name: name, agent: agent, arguments: arguments,
                            metadata: metadata)

      Invocation.call(context, registry: Unbound.new(name, config), config: config, &handler)
    end

    # The registry the envelope consults for an unbound name. Under `:deny` it answers
    # with the refusal itself; under `:allow_with_warning` it has no guard to offer, and
    # the envelope runs the tool unscoped and records `guard: "none"` — the same worklist
    # an unguarded class lands on.
    class Unbound
      def initialize(name, config)
        @name = name
        @config = config
      end

      def guard_for(_tool_name)
        return nil if @config.unguarded_tools == :allow_with_warning

        Decision.deny(
          rule: Decision::UNBOUND_TOOL,
          detail: "#{@name} is neither routed through reeve nor exempted in the inventory"
        )
      end
    end
  end
end

require_relative "inventory/report"
