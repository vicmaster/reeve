# frozen_string_literal: true

# Minimal stand-ins for the collaborators the kernel funnels through. They exist so the
# envelope can be specified before the authorization, audit and testing modules are built
# — and they double as the written form of each collaborator's protocol.
# Protocol: #guard_for(tool_name) => guard declaration or nil
class FakeRegistry
  def initialize(guards = {})
    @guards = guards
  end

  def guard_for(tool_name)
    @guards[tool_name.to_s]
  end
end

class RaisingRegistry
  def guard_for(_tool_name)
    raise "registry exploded"
  end
end

# Protocol: #authorize(context:, guard:) => Reeve::Decision
class FakeAuthorizer
  attr_reader :calls

  def initialize(decision)
    @decision = decision
    @calls = []
  end

  def authorize(context:, guard:)
    @calls << { context: context, guard: guard }
    @decision
  end
end

class RaisingAuthorizer
  def authorize(context:, guard:)
    raise ArgumentError, "policy exploded"
  end
end

# Protocol: #scope(context:, guard:, result:) => Reeve::ScopeResult
class FakeScoper
  attr_reader :calls

  def initialize(scope_result = nil)
    @scope_result = scope_result
    @calls = []
  end

  def scope(context:, guard:, result:)
    @calls << { context: context, guard: guard, result: result }
    @scope_result || Reeve::ScopeResult.allow(records: result, record_ids: [], record_count: 0)
  end
end

# Protocol: #record(attributes) => anything; raises on failure
class FakeRecorder
  attr_reader :entries

  def initialize
    @entries = []
  end

  def record(attributes)
    @entries << attributes
    attributes
  end

  def entry
    raise "expected exactly one entry, got #{entries.size}" unless entries.size == 1

    entries.first
  end
end

class RaisingRecorder
  attr_reader :attempts

  def initialize
    @attempts = 0
  end

  def record(_attributes)
    @attempts += 1
    raise "ledger unavailable"
  end
end

class CapturingLogger
  attr_reader :warnings

  def initialize
    @warnings = []
  end

  def warn(message = nil)
    @warnings << (message || yield)
  end
end

# The concurrency specs write from several threads at once.
class ThreadSafeRecorder
  attr_reader :entries

  def initialize
    @entries = []
    @mutex = Mutex.new
  end

  def record(attributes)
    @mutex.synchronize { @entries << attributes }
    attributes
  end
end
