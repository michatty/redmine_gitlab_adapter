require 'redmine'

require File.expand_path('lib/gitlab_repositories_helper_patch', __dir__)

prepare_hook = if defined?(ActiveSupport::Reloader)
                 ActiveSupport::Reloader
               else
                 Rails.application.config
               end

prepare_hook.to_prepare do
  require_dependency 'repositories_helper'

  unless RepositoriesHelper.included_modules.include?(GitlabRepositoriesHelperPatch)
    RepositoriesHelper.include(GitlabRepositoriesHelperPatch)
  end
end

begin
  require_dependency 'repositories_helper'
  unless RepositoriesHelper.included_modules.include?(GitlabRepositoriesHelperPatch)
    RepositoriesHelper.include(GitlabRepositoriesHelperPatch)
  end
rescue LoadError, NameError
end

Redmine::Plugin.register :redmine_gitlab_adapter do
  name 'Redmine Gitlab Adapter plugin'
  author 'Future Corporation (original) / michatty (fork maintainer)'
  description 'GitLab Adapter plugin for Redmine (fork for Redmine 6.1.1)'
  version '0.3.1'
  url 'https://github.com/michatty/redmine_gitlab_adapter'
  author_url 'https://github.com/michatty'
  Redmine::Scm::Base.add "Gitlab"
end
