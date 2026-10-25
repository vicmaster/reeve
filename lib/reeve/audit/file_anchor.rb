# frozen_string_literal: true

module Reeve
  module Audit
    # The anchor reeve ships (specs/004 FR-006a, research R6): a file it only ever appends to,
    # one checkpoint per line.
    #
    #   config.ledger_anchor = Reeve::Audit::FileAnchor.new("/mnt/ledger-anchor/production.checkpoints")
    #
    # A building block, not a guarantee. A checkpoint is worth exactly as much as the store's
    # refusal to let the database's users change or delete it, and a file on the database host
    # refuses nothing. Point it at storage those users cannot reach, such as a mount backed by
    # an object-locked bucket or a path a separate shipper collects.
    #
    # Append mode puts every write at the end of the file even with several processes writing,
    # and the lock keeps each line whole; the file is never opened any other way for writing.
    class FileAnchor
      attr_reader :path

      def initialize(path)
        @path = path.to_s
        freeze
      end

      def publish(line)
        if line.include?("\n")
          raise ArgumentError,
                "a checkpoint is one line; this one has a line break in it"
        end

        File.open(path, File::WRONLY | File::APPEND | File::CREAT, 0o644) do |file|
          file.flock(File::LOCK_EX)
          file.write("#{line}\n")
          file.fsync
        end
      end

      def checkpoints
        return [] unless File.exist?(path)

        File.readlines(path, chomp: true).reject { |line| line.strip.empty? }
      end

      def inspect
        "#<#{self.class.name} #{path}>"
      end
    end
  end
end
