# frozen_string_literal: true

require "json"

module Reeve
  module Audit
    class Chain
      module Retention
        # Verifies an archive on its own (specs/005 FR-012, contracts/archive-v1.md): its boundary
        # checkpoint is genuine, its start link is the genesis (or the boundary before it), and
        # every chained row, rebuilt as an unsaved entry so it casts as the database did,
        # recomputes its digest against the row before it, ending at the checkpoint's digest.
        #
        # Needs the entries table's columns, for the casts, but none of its rows.
        class ArchiveCheck
          BOUNDARY = "its boundary checkpoint"

          def initialize(path, keyring:, entry_class:)
            @path = path
            @keyring = keyring
            @entry_class = entry_class
            @breaks = []
          end

          def call
            header = Archive.read_header(@path)
            checkpoint = Checkpoint.parse(header.fetch("through_checkpoint"), position: 1)
            return result(header, checkpoint) unless genuine?(checkpoint)

            check_end(header, checkpoint, walk(header, start_link(header, checkpoint)))
            result(header, checkpoint)
          end

          private

          attr_reader :keyring, :breaks

          def genuine?(checkpoint)
            signed = checkpoint.signed_by(keyring)
            key = checkpoint.key_id
            add(:unknown_key, nil, "#{BOUNDARY} is signed by key #{key}", key_id: key) if
              signed == :key_not_configured
            if signed == :altered
              add(:checkpoint_altered, nil,
                  "#{BOUNDARY} does not match its signature")
            end
            signed == :valid
          end

          # Purge 0 starts at the genesis, which is recomputed under its own key and must be the
          # one the checkpoint names; a later purge starts at the previous boundary's digest,
          # which the first row's own digest then binds.
          def start_link(header, checkpoint)
            genesis = header.dig("start", "genesis")
            return header.dig("start", "through_digest") unless genesis

            digest = genesis["genesis_digest"]
            secret = keyring.for(genesis["genesis_key_id"])
            if secret.nil?
              add(:unknown_key, 0, "the genesis is signed by key #{genesis['genesis_key_id']}",
                  key_id: genesis["genesis_key_id"])
            elsif Canonical.genesis_digest(secret, Archive.genesis_values(genesis)) != digest ||
                  checkpoint.genesis_digest != digest
              add(:genesis_altered, 0,
                  "the archive's genesis does not match its digest or its checkpoint")
            end
            digest
          end

          # Every row after the header: pre-chain rows counted, chained rows checked in order.
          def walk(header, link)
            expected = header["from_sequence"]
            last = nil
            @chained = @pre_chain = 0
            File.foreach(@path).drop(1).each do |line|
              entry = @entry_class.new(JSON.parse(line))
              next @pre_chain += 1 if entry.chain_sequence.nil?

              expected, link = visit(entry, expected, link)
              last = entry
            end
            last
          end

          def visit(entry, expected, link)
            @chained += 1
            sequence = entry.chain_sequence
            if sequence != expected
              kind = sequence < expected ? :duplicate : :missing
              add(kind, sequence < expected ? sequence : expected..(sequence - 1),
                  "out of order in the archive")
            end
            check_digest(entry, link)
            [sequence + 1, entry.chain_digest]
          end

          def check_digest(entry, link)
            secret = keyring.for(entry.chain_key_id)
            if secret.nil?
              return add(:unknown_key, entry.chain_sequence, "signed by key #{entry.chain_key_id}",
                         key_id: entry.chain_key_id)
            end
            return if Canonical.entry_digest(secret, entry,
                                             previous_digest: link) == entry.chain_digest

            add(:digest_mismatch, entry.chain_sequence, Walk::MISMATCH)
          rescue ArgumentError => e
            add(:digest_mismatch, entry.chain_sequence, e.message)
          end

          def check_end(header, checkpoint, last)
            reached = last&.chain_sequence == header["through_sequence"] &&
                      last&.chain_digest == checkpoint.head_digest
            unless reached
              add(:checkpoint_not_reached, nil, "the archive does not end at its boundary " \
                                                "checkpoint " \
                                                "##{Report.number(checkpoint.head_sequence)}")
            end
            return if @chained == header["chained"] && @pre_chain == header["pre_chain"]

            add(:missing, nil, "the header counts #{header['chained']} chained and " \
                               "#{header['pre_chain']} " \
                               "pre-chain rows; the archive holds #{@chained} and #{@pre_chain}")
          end

          def add(kind, sequence, detail, key_id: nil)
            breaks << Verification::Break.new(kind: kind, sequence: sequence, detail: detail,
                                              key_id: key_id)
          end

          def result(header, checkpoint)
            ArchiveResult.new(status: Verification.status_for(breaks), breaks: breaks,
                              covered: header["from_sequence"]..header["through_sequence"],
                              checkpoint: checkpoint, pre_chain: @pre_chain.to_i)
          end
        end

        # What verifying an archive found, in words (`bin/rails reeve:verify_archive`).
        ArchiveResult = Struct.new(:status, :breaks, :covered, :checkpoint, :pre_chain,
                                   keyword_init: true) do
          def intact? = status == :intact

          def to_s
            listed = breaks.reject { |found| found.kind == :unknown_key }
            [summary, *listed.map { |found| line(found) }].join("\n")
          end

          private

          def summary
            word, found =
              case status
              when :intact then ["INTACT", "sequences #{range} verified, ending at #{ending}"]
              when :broken then ["BROKEN", "#{n(breaks.size)} breaks in sequences #{range}"]
              else ["UNVERIFIABLE", "signed by a key not configured; nothing in #{range} verified"]
              end
            "reeve archive: #{word} — #{found}; #{counted}"
          end

          def range = "#{n(covered.first)}–#{n(covered.last)}"

          def ending
            "checkpoint ##{n(checkpoint.head_sequence)} (#{AnchorText.made_on(checkpoint.made_at)})"
          end

          def counted = "#{n(pre_chain)} pre-chain rows counted, not verified"

          def line(found)
            sequence = found.sequence
            where = sequence.is_a?(Range) ? "##{sequence.first}–#{sequence.last}" : "##{sequence}"
            "  #{sequence.nil? ? '—' : where} #{found.kind} #{found.detail}"
          end

          def n(value) = Report.number(value.to_i)
        end
      end
    end
  end
end
