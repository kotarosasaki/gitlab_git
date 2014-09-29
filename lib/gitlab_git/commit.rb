# Gitlab::Git::Commit is a wrapper around native Grit::Commit object
# We dont want to use grit objects inside app/
# It helps us easily migrate to rugged in future
module Gitlab
  module Git
    class Commit
      attr_accessor :raw_commit, :head, :refs

      SERIALIZE_KEYS = [
        :id, :message, :parent_ids,
        :authored_date, :author_name, :author_email,
        :committed_date, :committer_name, :committer_email
      ]
      attr_accessor *SERIALIZE_KEYS

      class << self
        # Get commits collection
        #
        # Ex.
        #   Commit.where(
        #     repo: repo,
        #     ref: 'master',
        #     path: 'app/models',
        #     limit: 10,
        #     offset: 5,
        #   )
        #
        def where(options)
          repo = options.delete(:repo)
          raise 'Gitlab::Git::Repository is required' unless repo.respond_to?(:log)

          repo.log(options).map { |c| decorate(c) }
        end

        # Get single commit
        #
        # Ex.
        #   Commit.find(repo, '29eda46b')
        #
        #   Commit.find(repo, 'master')
        #
        def find(repo, commit_id = nil)
          use_rugged = true
          if use_rugged 
            if commit_id == "master"
              oid = repo.rugged_head.target
            else
              oid = commit_id
            end
            
            begin
              commit = repo.lookup(oid)
            rescue Rugged::InvalidError
              oid = repo.rugged_head.target
              commit = repo.lookup(oid)
            end
          else
            commit = repo.log(ref: commit_id, limit: 1).first
          end
          decorate(commit) if commit
        end

        # Get last commit for HEAD
        #
        # Ex.
        #   Commit.last(repo)
        #
        def last(repo)
          find(repo, nil)
        end

        # Get last commit for specified path and ref
        #
        # Ex.
        #   Commit.last_for_path(repo, '29eda46b', 'app/models')
        #
        #   Commit.last_for_path(repo, 'master', 'Gemfile')
        #
        def last_for_path(repo, ref, path = nil)
          where(
            repo: repo,
            ref: ref,
            path: path,
            limit: 1
          ).first
        end

        # Get commits between two refs
        #
        # Ex.
        #   Commit.between('29eda46b', 'master')
        #
        def between(repo, base, head)
          repo.commits_between(base, head).map do |commit|
            decorate(commit)
          end
        end

        # Delegate Repository#find_commits
        def find_all(repo, options = {})
          repo.find_commits(options)
        end

        def decorate(commit, ref = nil)
          Gitlab::Git::Commit.new(commit, ref)
        end
      end

      def initialize(raw_commit, head = nil)
        raise "Nil as raw commit passed" unless raw_commit

        if raw_commit.is_a?(Hash)
          init_from_hash(raw_commit)
        elsif raw_commit.is_a?(Rugged::Commit)
          init_from_rugged(raw_commit)
        else
          init_from_grit(raw_commit)
        end

        @head = head
      end

      def sha
        id
      end

      def short_id(length = 10)
        id.to_s[0..length]
      end

      def safe_message
        @safe_message ||= message
      end

      def created_at
        committed_date
      end

      # Was this commit committed by a different person than the original author?
      def different_committer?
        author_name != committer_name || author_email != committer_email
      end

      def parent_id
        parent_ids.first
      end

      # Shows the diff between the commit's parent and the commit.
      #
      # Cuts out the header and stats from #to_patch and returns only the diff.
      def to_diff
        # see Grit::Commit#show
        patch = to_patch

        # discard lines before the diff
        lines = patch.split("\n")
        while !lines.first.start_with?("diff --git") do
          lines.shift
        end
        lines.pop if lines.last =~ /^[\d.]+$/ # Git version
        lines.pop if lines.last == "-- "      # end of diff
        lines.join("\n")
      end

      def has_zero_stats?
        stats.total.zero?
      rescue
        true
      end

      def no_commit_message
        "--no commit message"
      end

      def to_hash
        serialize_keys.map.with_object({}) do |key, hash|
          hash[key] = send(key)
        end
      end

      def date
        committed_date
      end

      def diffs
        if raw_commit.is_a?(Rugged::Commit)
          if raw_commit.parents.length == 0
            opt = {:reverse => true}
            raw_diff = raw_commit.tree.diff(nil,opt)
          else
            raw_diff = raw_commit.parents[0].diff(raw_commit)
          end
          to_diff_rugged(raw_diff)

          idx = -1
          raw_diff.map do |diff|
            idx += 1
            rug_diff = Gitlab::Git::Diff.new(diff)
            rug_diff.diff = @diff_lines[idx][:@diff].to_s.force_encoding("utf-8")
            rug_diff.a_mode = @diff_lines[idx][:@a_mode]
            rug_diff.b_mode = @diff_lines[idx][:@b_mode]
            if not @diff_lines[idx][:@new_file]
              rug_diff.new_file = false
            end
            rug_diff.renamed_file = @diff_lines[idx][:@renamed_file]
            rug_diff.deleted_file = @diff_lines[idx][:@deleted_file]
            rug_diff
          end
        else
          raw_commit.diffs.map { |diff| Gitlab::Git::Diff.new(diff) }
        end
      end

      def to_diff_rugged(raw_diff)
        patch = raw_diff.patch
        diffs = patch.split("diff --git ")
        diffs.shift

        @diff_lines = Array.new

        diffs.each do |diff|
          @diff = String.new
          ab_path = String.new
          ab_mode = String.new
          new_file = false
          renamed_file = false
          deleted_file = false

          cnt = diff.index(/\n/)
          line_1 = diff.slice!(0,cnt+1)
          cnt = diff.index(/\n/)
          line_2 = diff.slice!(0,cnt+1)
          ab_parh = line_1.split(nil)
          ab_mode = line_2.split(nil)
          b_mode = ab_mode[2]
          if ab_mode[0] == "index"
          else
            if ab_mode[0] == "new"
              new_file = true
            elsif ab_mode[0] == "renamed"
              renamed_file = true
            elsif ab_mode[0] == "deleted"
              deleted_file = true
            end
            b_mode = ab_mode[3]
            cnt = diff.index(/\n/)
            line_3 = diff.slice!(0,cnt+1)
          end
          cnt = diff.index(/\n/)
          line = diff.slice!(0,cnt+1)
          cnt = diff.index(/\n/)
          line = diff.slice!(0,cnt+1)

          diff_hash = Hash[:@a_path, ab_path[0], :@b_path, ab_path[1], :@a_mode, nil, :@b_mode, b_mode, :@diff, diff, :@new_file, new_file, :@renamed_file, renamed_file, :@deleted_file, deleted_file]
          @diff_lines << diff_hash
        end
      end

      def parents
        if raw_commit.is_a?(Rugged::Commit)
          raw_commit.parents.map(&:oid)
        else
          raw_commit.parents
        end
      end

      def tree
        raw_commit.tree
      end

      def stats
        if raw_commit.is_a?(Rugged::Commit)
          Gitlab::Git::CommitStats.new(raw_commit)
        else
          raw_commit.stats
        end
      end

      def to_patch
        raw_commit.to_patch
      end

      # Get refs collection(Grit::Head or Grit::Remote or Grit::Tag)
      #
      # Ex.
      #   commit.ref(repo)
      #
      def refs(repo)
        repo.refs_hash[id]
      end

      # Get ref names collection
      #
      # Ex.
      #   commit.ref_names(repo)
      #
      def ref_names(repo)
        refs(repo).map(&:name)
      end

      private

      def init_from_grit(grit)
        @raw_commit = grit
        @id = grit.id
        @message = grit.message
        @authored_date = grit.authored_date
        @committed_date = grit.committed_date
        @author_name = grit.author.name
        @author_email = grit.author.email
        @committer_name = grit.committer.name
        @committer_email = grit.committer.email
        @parent_ids = grit.parents.map(&:id)
      end

      def init_from_rugged(rugged)
        @raw_commit = rugged
        @id = rugged.oid
        @message = rugged.message
        @authored_date = rugged.author[:time]
        @committed_date = rugged.committer[:time]
        @author_name = rugged.author[:name]
        @author_email = rugged.author[:email]
        @committer_name = rugged.committer[:name]
        @committer_email = rugged.committer[:email]
        @parent_ids = rugged.parents.map(&:oid)
      end

      def init_from_hash(hash)
        raw_commit = hash.symbolize_keys

        serialize_keys.each do |key|
          send("#{key}=", raw_commit[key])
        end
      end

      def serialize_keys
        SERIALIZE_KEYS
      end
    end
  end
end
