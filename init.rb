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
  author 'Future Corporation'
  description 'This is a Gitlab Adapter plugin for Redmine'
  version '0.3.0'
  url 'https://www.future.co.jp'
  author_url 'https://www.future.co.jp'
  Redmine::Scm::Base.add "Gitlab"
end
