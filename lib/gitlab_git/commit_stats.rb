module Gitlab
  module Git
    class CommitStats
      attr_reader :id, :additions, :deletions, :total

      def initialize(raw_commit)
        @id = raw_commit.oid
        @additions = 0
        @deletions = 0
        @total     = 0

        if raw_commit.parents.length == 0
          opt = {:reverse => true}
          raw_diff = raw_commit.tree.diff(nil,opt)
        else
          raw_diff = raw_commit.parents[0].diff(raw_commit)
        end

        raw_diff.each_patch do |p|
          @additions += p.additions
          @deletions += p.deletions
        end
        @total = @additions + @deletions
      end

    end
  end
end

