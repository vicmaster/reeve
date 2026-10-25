# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"

module Reeve
  module Audit
    class Chain
      module Retention
        # The archive a purge writes before it removes anything (specs/005 FR-007,
        # contracts/archive-v1.md): one JSON line of header, then every purged row with every
        # column, chain columns included, so the range can be verified on its own.
        #
        # Written to `path.tmp`, flushed and renamed, so a partial archive is never at `path`.
        module Archive
          FORMAT = "reeve-ledger-archive-v1"
          BATCH = 1_000

          module_function

          # Writes the archive for `plan` and returns its SHA-256.
          def write(path, plan, entry_class:)
            partial = "#{path}.tmp"
            File.open(partial, File::WRONLY | File::CREAT | File::EXCL, 0o644) do |file|
              file.puts(JSON.generate(header(plan)))
              each_row(plan, entry_class) { |row| file.puts(JSON.generate(line(row))) }
              file.flush
              file.fsync
            end
            File.rename(partial, path)
            ::Digest::SHA256.file(path).hexdigest
          rescue StandardError
            FileUtils.rm_f(partial)
            raise
          end

          def header(plan)
            {
              "format" => FORMAT, "ledger" => ChainRecord::LEDGER, "purge" => plan.purge,
              "from_sequence" => plan.from, "through_sequence" => plan.through,
              "through_checkpoint" => plan.checkpoint.to_line, "start" => plan.start || genesis,
              "chained" => plan.removed_chained, "pre_chain" => plan.removed_pre_chain,
              "reeve_version" => Reeve::VERSION
            }.sort.to_h
          end

          # Purge 0 starts at the genesis, so the archive carries it.
          def genesis
            record = ChainRecord.ledger
            fields = Canonical::GENESIS_FIELDS + ["genesis_digest"]
            { "genesis" => fields.to_h { |field| [field, value(record[field])] } }
          end

          # Pre-chain rows first, then the chained range in sequence order, a batch at a time.
          def each_row(plan, entry_class, &block)
            entry_class.where("contract_version < 3").order(:id).find_each(batch_size: BATCH,
&block)
            after = plan.from - 1
            loop do
              batch = entry_class.where(chain_sequence: (after + 1)..plan.through)
                                 .order(:chain_sequence).limit(BATCH).to_a
              batch.each(&block)
              break if batch.size < BATCH

              after = batch.last.chain_sequence
            end
          end

          # The header of the archive at `path`, refusing one in another format: a verifier
          # never guesses at a format it does not know.
          def read_header(path)
            header = JSON.parse(File.foreach(path).first.to_s)
            return header if header.is_a?(Hash) && header["format"] == FORMAT

            found = header.is_a?(Hash) ? header["format"].inspect : "unreadable"
            raise ArgumentError, "#{path} is not a #{FORMAT} archive (format #{found})"
          rescue JSON::ParserError
            raise ArgumentError, "#{path} is not a #{FORMAT} archive (its first line is not JSON)"
          end

          # The header's genesis, with its time as a Time again, for Canonical.genesis_digest.
          def genesis_values(genesis)
            genesis.merge("genesis_at" => Time.iso8601(genesis["genesis_at"]))
          end

          def line(row)
            row.attributes.except("id").transform_values { |item| value(item) }.sort.to_h
          end

          def value(item)
            item.respond_to?(:utc) ? item.utc.iso8601(6) : item
          end
        end
      end
    end
  end
end
