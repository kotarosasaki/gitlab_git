# Gitlab::Git::Diff is a wrapper around native Grit::Diff object
# We dont want to use grit objects inside app/
# It helps us easily migrate to rugged in future
module Gitlab
  module Git
    class Diff
      class TimeoutError < StandardError; end

      attr_accessor :raw_diff

      # Diff properties
      attr_accessor :old_path, :new_path, :a_mode, :b_mode, :diff

      # Stats properties
      attr_accessor  :new_file, :renamed_file, :deleted_file

      class << self
        def between(repo, head, base, *paths)
          # Only show what is new in the source branch compared to the target branch, not the other way around.
          # The linex below with merge_base is equivalent to diff with three dots (git diff branch1...branch2)
          # From the git documentation: "git diff A...B" is equivalent to "git diff $(git-merge-base A B) B"
          common_commit = repo.merge_base_commit(head, base)

          repo.diff(common_commit, head, *paths).map do |diff|
            Gitlab::Git::Diff.new(diff)
          end
        rescue Grit::Git::GitTimeout
          raise TimeoutError.new("Diff.between exited with timeout")
        end
      end

      def initialize(raw_diff)
        raise "Nil as raw diff passed" unless raw_diff

        if raw_diff.is_a?(Hash)
          init_from_hash(raw_diff)
        elsif raw_diff.is_a?(Rugged::Diff::Patch)
          # if rugged lib version over 19 ->  change to class - Rugged::Patch
          init_from_rugged(raw_diff)
        else
          init_from_grit(raw_diff)
        end
      end

      def serialize_keys
        @serialize_keys ||= %w(diff new_path old_path a_mode b_mode new_file renamed_file deleted_file).map(&:to_sym)
      end

      def to_hash
        hash = {}

        keys = serialize_keys

        keys.each do |key|
          hash[key] = send(key)
        end

        hash
      end

      private

      def init_from_grit(grit)
        @raw_diff = grit

        serialize_keys.each do |key|
          send(:"#{key}=", grit.send(key))
        end
      end

      def init_from_rugged(rugged)
        @raw_diff = rugged
        @diff = rugged
        @new_path = rugged.delta.new_file[:path]
        @old_path = rugged.delta.old_file[:path]
        @a_mode = rugged.delta.new_file[:mode]
        @b_mode = rugged.delta.old_file[:mode]
        @new_file = rugged.delta.new_file
        @old_file = rugged.delta.old_file
        @renamed_file = rugged.delta.renamed?
        @deleted_file = rugged.delta.deleted?
      end

      def init_from_hash(hash)
        raw_diff = hash.symbolize_keys

        serialize_keys.each do |key|
          send(:"#{key}=", raw_diff[key.to_sym])
        end
      end
    end
  end
end

