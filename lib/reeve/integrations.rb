# frozen_string_literal: true

require_relative "../reeve"

module Reeve
  # Adapters for the MCP server libraries reeve rides on. Each is opt-in, conditionally
  # loaded, and never a dependency of the core (Constitution IV). What they share lives
  # here: the install, the version gate, and the check that stops a call being recorded
  # twice.
  module Integrations
    module_function

    # Gives +base+ the DSL and routes every subclass through +inheritance+: the ones
    # defined from here on through its `inherited` hook, the ones already defined through
    # `inheritance.wrap`. Idempotent, so requiring an adapter twice cannot stack two
    # envelopes around one call (FR-004).
    def install!(base, inheritance)
      unless base.include?(Reeve::Guard)
        base.include(Reeve::Guard)
        # The library's base class carries the DSL for its subclasses; it is not a tool.
        base.reeve_abstract!
      end

      base.singleton_class.prepend(inheritance) unless base.singleton_class.include?(inheritance)
      descendants(base).each { |klass| inheritance.wrap(klass) }
      base
    end

    # True while an envelope for +tool+ is open on this thread. The testing kit and a host
    # that wraps `Reeve.invoke` around a library call both open one before the library
    # runs the tool; the adapter then runs the body inside it instead of opening a second,
    # so a call is recorded once (FR-051).
    def inside?(tool)
      state = Authorization::Current.state
      !state.nil? && state.context.tool_name == Reeve.__send__(:tool_name_for, tool)
    end

    # An adapter that reaches into a library's internals is verified against a range of
    # its versions. Outside that range it refuses to load rather than guard by guesswork
    # (FR-013).
    def require_version!(adapter, gem_name, version, *requirements)
      requirement = Gem::Requirement.new(*requirements)
      return if requirement.satisfied_by?(Gem::Version.new(version))

      raise ConfigurationError,
            "#{adapter} supports #{gem_name} #{requirement}, but #{gem_name} #{version} is " \
            "loaded. Use a supported version, or a reeve release that supports this one."
    end

    # Whether +mod+ is prepended to +klass+ itself. Not `include?`: that also answers true
    # for a module prepended to a superclass, and a subclass that defines its own `call`
    # would then run ahead of the wrapper instead of behind it.
    def prepended?(klass, mod)
      klass.ancestors.take_while { |ancestor| !ancestor.equal?(klass) }.include?(mod)
    end

    # Every subclass at any depth. `Class#subclasses` arrived in Ruby 3.1 (ActiveSupport
    # adds it earlier); without it, ObjectSpace finds them.
    def descendants(base)
      if base.respond_to?(:subclasses)
        base.subclasses.flat_map { |klass| [klass, *descendants(klass)] }
      else
        ObjectSpace.each_object(base.singleton_class).reject { |klass| klass.equal?(base) }
      end
    end
  end
end
