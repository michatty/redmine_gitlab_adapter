# Redmine Gitlab Adapter Plugin

For Redmine 6.x.

This plugin uses the GitLab REST API (v4) via the Ruby gem `gitlab`.

## Porting notes

See: [docs/redmine-6_1_1-porting-notes.md](docs/redmine-6_1_1-porting-notes.md)

## Plugin installation

1. Copy the plugin directory into the $REDMINE_ROOT/plugins directory. Please
    note that plugin's folder name should be "redmine_gitlab_adapter".

2. Install 'gitlab'

    e.g. bundle install

3. (Re)Start Redmine.

## Settings

1. Login redmine used redmine admin account.

2. Open top menu "Administration" -> "Settings" -> "Repositories" page

3. Enabled "Gitlab" SCM.

4. Apply this configure.

## How to use

1. Login redmine used the project admin account.

2. Open this project "Settings" -> "Repositories" page.

3. Click "New reposiory".

4. Select "Gitlab" from SCM Pull Down Menu.

5. Paste `<Gitlab Project URL>` into "URL".

6. Paste `<Gitlab Personal Access Token>` into "API Token".

7. Click "Create" button.
