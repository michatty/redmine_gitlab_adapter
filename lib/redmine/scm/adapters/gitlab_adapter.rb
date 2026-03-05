require 'redmine/scm/adapters/abstract_adapter'
require 'gitlab'
require 'uri'

module Redmine
  module Scm
    module Adapters
      class GitlabAdapter < AbstractAdapter

        # Git executable name
        GITLAB_BIN = "gitlab"
        # Repositories created after 2020 may have a default branch of
        # "main" instead of "master"
        GITLAB_DEFAULT_BRANCH_NAMES = %w[main master].freeze

        PER_PAGE = 100
        MAX_PAGES = 10

        class GitlabBranch < Branch
          attr_accessor :is_default
        end

        class << self
          def client_command
            @@bin    ||= GITLAB_BIN
          end

          def sq_bin
            @@sq_bin ||= shell_quote_command
          end

          def client_version
            @@client_version ||= (scm_command_version || [])
          end

          def client_available
            !client_version.empty?
          end

          def scm_command_version
            scm_version = Gitlab::VERSION
            if m = scm_version.match(%r{\A(.*?)((\d+\.)+\d+)})
              m[2].scan(%r{\d+}).collect(&:to_i)
            end
          end
        end

        def initialize(url, root_url=nil, login=nil, password=nil, path_encoding=nil)
          super

          @entries_cache = {}
          @lastrev_cache = {}

          ## Get gitlab project
          @project = url.sub(root_url, '').sub(/^\//, '').sub(/\.git$/, '')

          ## Set Gitlab endpoint and token
          endpoint = root_url.to_s.chomp('/') + '/api/v4'

          httparty_opts = {}
          proxy = proxy_from_env(url)
          if proxy
            httparty_opts[:http_proxyaddr] = proxy.host
            httparty_opts[:http_proxyport] = proxy.port
            httparty_opts[:http_proxyuser] = proxy.user
            httparty_opts[:http_proxypass] = proxy.password
          end

          @client = ::Gitlab.client(
            endpoint: endpoint,
            private_token: password,
            httparty: httparty_opts
          )
        end

        def fetch_file_size?
          v = ENV['REDMINE_GITLAB_ADAPTER_FETCH_FILE_SIZE']
          v.to_s.strip.downcase == '1' || v.to_s.strip.downcase == 'true'
        end
        private :fetch_file_size?

        def proxy_from_env(url)
          uri = URI.parse(url.to_s)
          return nil if uri.host.to_s.empty?

          no_proxy = ENV['no_proxy'] || ENV['NO_PROXY']
          if no_proxy_match?(uri.host, no_proxy)
            return nil
          end

          proxy_env = if uri.scheme.to_s.downcase == 'https'
                        ENV['https_proxy'] || ENV['HTTPS_PROXY'] || ENV['http_proxy'] || ENV['HTTP_PROXY']
                      else
                        ENV['http_proxy'] || ENV['HTTP_PROXY']
                      end
          return nil if proxy_env.to_s.strip.empty?

          proxy_uri = URI.parse(proxy_env)
          return nil if proxy_uri.host.to_s.empty?

          proxy_uri
        rescue StandardError
          nil
        end
        private :proxy_from_env

        def no_proxy_match?(host, no_proxy_value)
          return false if host.to_s.empty?
          return false if no_proxy_value.to_s.strip.empty?

          host = host.to_s.downcase
          no_proxy_value.to_s.split(',').map(&:strip).reject(&:empty?).any? do |pattern|
            pattern = pattern.downcase
            return true if pattern == '*'
            next true if host == pattern
            next true if pattern.start_with?('.') && host.end_with?(pattern)

            false
          end
        end
        private :no_proxy_match?

        def info
          Info.new(:root_url => root_url, :lastrev => lastrev('',nil))
        rescue
          nil
        end

        def branches
          return @branches if @branches
          @branches = []
          1.step do |i|
            gitlab_branches = @client.branches(@project, {page: i, per_page: PER_PAGE})
            break if gitlab_branches.length == 0
            gitlab_branches.each do |gitlab_branche|
              bran = GitlabBranch.new(gitlab_branche.name)
              bran.revision = gitlab_branche.commit.id
              bran.scmid = gitlab_branche.commit.id
              bran.is_default = gitlab_branche.default
              @branches << bran
            end
          end
          @branches.sort!
        rescue Gitlab::Error::Error
          nil
        end

        def tags
          return @tags if @tags
          @tags = []
          1.step do |i|
            gitlab_tags = @client.tags(@project, {page: i, per_page: PER_PAGE})
            break if gitlab_tags.length == 0
            gitlab_tags.each do |gitlab_tag|
              @tags << gitlab_tag.name
            end
          end
          @tags
        rescue Gitlab::Error::Error
          nil
        end

        def default_branch
          return if branches.blank?

          (
            branches.detect(&:is_default) ||
            branches.detect {|b| GITLAB_DEFAULT_BRANCH_NAMES.include?(b.to_s)} ||
            branches.first
          ).to_s
        end

        def entry(path=nil, identifier=nil)
          parts = path.to_s.split(%r{[\/\\]}).select {|n| !n.blank?}
          search_path = parts[0..-2].join('/')
          search_name = parts[-1]
          if search_path.blank? && search_name.blank?
            # Root entry
            Entry.new(:path => '', :kind => 'dir')
          else
            # Search for the entry in the parent directory
            es = entries(search_path, identifier,
                         options = {:report_last_commit => false})
            es ? es.detect {|e| e.name == search_name} : nil
          end
        end

        def entries(path=nil, identifier=nil, options={})
          path ||= ''
          identifier = 'HEAD' if identifier.nil?

          report_last_commit = options[:report_last_commit] ? true : false
          fetch_size = fetch_file_size?
          cache_key = [path.to_s, identifier.to_s, report_last_commit ? 1 : 0, fetch_size ? 1 : 0]
          if @entries_cache.key?(cache_key)
          cached = @entries_cache[cache_key]
          return cached.deep_dup if cached.respond_to?(:deep_dup)
          return cached
          end

          entries = Entries.new
          seen_names = {}
          1.step do |i|
            files = @client.tree(@project, {path: path, ref: identifier, page: i, per_page: PER_PAGE})
            break if files.length == 0

            files.each do |file|
              full_path = path.empty? ? file.name : "#{path}/#{file.name}"
            next if seen_names[file.name]
            seen_names[file.name] = true

            size = nil
            if fetch_size && file.type != 'tree'
            # NOTE: This is an extra API call per file. Disabled by default for performance.
            gitlab_get_file = @client.get_file(@project, full_path, identifier)
            size = gitlab_get_file.size
            end
              entries << Entry.new({
                :name => file.name.dup,
                :path => full_path.dup,
                :kind => (file.type == "tree") ? 'dir' : 'file',
                :size => (file.type == "tree") ? nil : size,
            :lastrev => report_last_commit ? lastrev(full_path, identifier) : Revision.new
            })
            end
          end
          entries = entries.sort_by_name
          @entries_cache[cache_key] = entries
          entries
        rescue Gitlab::Error::Error
          nil
        end

        def lastrev(path, rev)
          return nil if path.nil?
          key = [path.to_s, rev.to_s]
          return @lastrev_cache[key] if @lastrev_cache.key?(key)
          gitlab_commits = @client.commits(@project, {path: path, ref_name: rev, per_page: 1})
          gitlab_commits.each do |gitlab_commit|
          rev_obj = Revision.new({
              :identifier => gitlab_commit.id,
              :scmid      => gitlab_commit.id,
              :author     => gitlab_commit.author_name,
              :time       => Time.parse(gitlab_commit.committed_date),
              :message    => nil,
              :paths      => nil
            })
          @lastrev_cache[key] = rev_obj
          return rev_obj
          end
          @lastrev_cache[key] = nil
          return nil
        rescue Gitlab::Error::Error
          @lastrev_cache[key] = nil
          nil
        end

        def revisions(path, identifier_from, identifier_to, options={})
          revs = Revisions.new
          per_page = PER_PAGE
          per_page = options[:limit].to_i if options[:limit]
          all = false
          all = options[:all] if options[:all]
          since = ''
          since = options[:last_committed_date] if options[:last_committed_date]

          if all
            ## STEP 1: Seek start_page
            start_page = 1
            0.step do |i|
              start_page = i * MAX_PAGES + 1
              gitlab_commits = @client.commits(@project, {all: true, since: since, page: start_page, per_page: per_page})
              if gitlab_commits.length < per_page
                start_page = start_page - MAX_PAGES if i > 0
                break
              end
            end

            ## Step 2: Get the commits from start_page
            start_page.step do |i|
              gitlab_commits = @client.commits(@project, {all: true, since: since, page: i, per_page: per_page})
              break if gitlab_commits.length == 0
              gitlab_commits.each do |gitlab_commit|
                files=[]
                gitlab_commit_diff = @client.commit_diff(@project, gitlab_commit.id)
                gitlab_commit_diff.each do |commit_diff|
                  if commit_diff.new_file
                    files << {:action => 'A', :path => commit_diff.new_path}
                  elsif commit_diff.deleted_file
                    files << {:action => 'D', :path => commit_diff.new_path}
                  elsif commit_diff.renamed_file
                    files << {:action => 'D', :path => commit_diff.old_path}
                    files << {:action => 'A', :path => commit_diff.new_path}
                  else
                    files << {:action => 'M', :path => commit_diff.new_path}
                  end
                end
                revision = Revision.new({
                  :identifier => gitlab_commit.id,
                  :scmid      => gitlab_commit.id,
                  :author     => gitlab_commit.author_name,
                  :time       => Time.parse(gitlab_commit.committed_date),
                  :message    => gitlab_commit.message,
                  :paths      => files,
                  :parents    => gitlab_commit.parent_ids.dup
                })
                revs << revision
              end
            end
          else
            gitlab_commits = @client.commits(@project, {path: path, ref_name: identifier_to, per_page: per_page})
            gitlab_commits.each do |gitlab_commit|
              revision = Revision.new({
                :identifier => gitlab_commit.id,
                :scmid      => gitlab_commit.id,
                :author     => gitlab_commit.author_name,
                :time       => Time.parse(gitlab_commit.committed_date),
                :message    => gitlab_commit.message,
                :paths      => [],
                :parents    => gitlab_commit.parent_ids.dup
              })
              revs << revision
            end
          end
          revs.sort! do |a, b|
            a.time <=> b.time
          end
          revs
        rescue Gitlab::Error::Error => e
          err_msg = "gitlab log error: #{e.message}"
          logger.error(err_msg)
        end

        def diff(path, identifier_from, identifier_to=nil)
          path ||= ''
          diff = []

          gitlab_diffs = []
          if identifier_to.nil?
            gitlab_diffs = @client.commit_diff(@project, identifier_from)
          else
            gitlab_diffs = @client.compare(@project, identifier_to, identifier_from).diffs
          end

          gitlab_diffs.each do |gitlab_diff|
            if identifier_to.nil? && path.length > 0
              next unless gitlab_diff.new_path == path
            end
            if gitlab_diff.kind_of?(Hash)
              renamed_file = gitlab_diff["renamed_file"]
              new_path = gitlab_diff["new_path"]
              old_path = gitlab_diff["old_path"]
              gitlab_diff_diff = gitlab_diff["diff"]
            else
              renamed_file = gitlab_diff.renamed_file
              new_path = gitlab_diff.new_path
              old_path = gitlab_diff.old_path
              gitlab_diff_diff = gitlab_diff.diff
            end

            if renamed_file
              filecontent = cat(new_path, identifier_from)
              if filecontent.nil?
                diff << "diff"
                diff << "--- a/#{old_path}"
                diff << "+++ b/#{new_path}"
              else
                diff << "diff"
                diff << "--- a/#{old_path}"
                diff << "+++ /dev/null"
                diff << "@@ -1,2 +0,0 @@"
                filecontent.split("\n").each do |line|
                  diff << "-#{line}"
                end
                diff << "diff"
                diff << "--- /dev/null"
                diff << "+++ b/#{new_path}"
                diff << "@@ -0,0 +1,2 @@"
                filecontent.split("\n").each do |line|
                  diff << "+#{line}"
                end
              end
            else
              diff << "diff"
              diff << "--- a/#{old_path}"
              diff << "+++ b/#{new_path}"
              diff << gitlab_diff_diff.split("\n")
            end
          end
          diff.flatten!
          diff.deep_dup
        rescue Gitlab::Error::Error
          nil
        end

        def annotate(path, identifier=nil)
          identifier = 'HEAD' if identifier.blank?
          blame = Annotate.new
          gitlab_get_file_blame = @client.get_file_blame(@project, path, identifier)
          gitlab_get_file_blame.each do |file_blame|
            file_blame.lines.each do |line|
              blame.add_line(line, Revision.new(
                                    :identifier => file_blame.commit.id,
                                    :revision   => file_blame.commit.id,
                                    :scmid      => file_blame.commit.id,
                                    :author     => file_blame.commit.author_name
                                    ))
            end
          end
          blame
        rescue Gitlab::Error::Error
          nil
        end

        def cat(path, identifier=nil)
          identifier = 'HEAD' if identifier.nil?
          @client.file_contents(@project, path, identifier)
        rescue Gitlab::Error::Error
          nil
        end

        class Revision < Redmine::Scm::Adapters::Revision
          # Returns the readable identifier
          def format_identifier
            identifier[0,8]
          end
        end

        def valid_name?(name)
          true
        end

      end
    end
  end
end
