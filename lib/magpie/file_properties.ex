defmodule Magpie.FileProperties do
  @moduledoc """
  Endpoints of the Dropbox `file_properties` namespace: custom property
  groups attached to files, based on user- or team-owned templates.

  The `*_for_team` template functions require a Dropbox Business (team) token.
  """
  import Magpie

  @doc """
  Add property groups (instances of a template) to a file.

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#file_properties-properties-add
  """
  def properties_add(client, path, property_groups) do
    body = %{"path" => path, "property_groups" => property_groups}
    post(client, "/file_properties/properties/add", body)
  end

  @doc """
  Overwrite existing property groups on a file.

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#file_properties-properties-overwrite
  """
  def properties_overwrite(client, path, property_groups) do
    body = %{"path" => path, "property_groups" => property_groups}
    post(client, "/file_properties/properties/overwrite", body)
  end

  @doc """
  Remove all property groups of the given templates from a file.

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#file_properties-properties-remove
  """
  def properties_remove(client, path, property_template_ids) do
    body = %{"path" => path, "property_template_ids" => property_template_ids}
    post(client, "/file_properties/properties/remove", body)
  end

  @doc """
  Search across property templates for particular property field values.
  `opts` accepts `"template_filter"`.

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#file_properties-properties-search
  """
  def properties_search(client, queries, opts \\ %{}) do
    body = Map.merge(%{"queries" => queries}, opts)
    post(client, "/file_properties/properties/search", body)
  end

  @doc """
  Fetches the next page of results from `properties_search/3`.

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#file_properties-properties-search-continue
  """
  def properties_search_continue(client, cursor) do
    post(client, "/file_properties/properties/search/continue", %{"cursor" => cursor})
  end

  @doc """
  Add, update or remove property fields on a file.

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#file_properties-properties-update
  """
  def properties_update(client, path, update_property_groups) do
    body = %{"path" => path, "update_property_groups" => update_property_groups}
    post(client, "/file_properties/properties/update", body)
  end

  @doc """
  Add a new template owned by the current user.

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#file_properties-templates-add_for_user
  """
  def templates_add_for_user(client, name, description, fields) do
    body = %{"name" => name, "description" => description, "fields" => fields}
    post(client, "/file_properties/templates/add_for_user", body)
  end

  @doc """
  Add a new template owned by the team (team token).

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#file_properties-templates-add_for_team
  """
  def templates_add_for_team(client, name, description, fields) do
    body = %{"name" => name, "description" => description, "fields" => fields}
    post(client, "/file_properties/templates/add_for_team", body)
  end

  @doc """
  Get the definition of a user-owned template.

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#file_properties-templates-get_for_user
  """
  def templates_get_for_user(client, template_id) do
    post(client, "/file_properties/templates/get_for_user", %{"template_id" => template_id})
  end

  @doc """
  Get the definition of a team-owned template (team token).

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#file_properties-templates-get_for_team
  """
  def templates_get_for_team(client, template_id) do
    post(client, "/file_properties/templates/get_for_team", %{"template_id" => template_id})
  end

  @doc """
  List the identifiers of the user-owned templates.

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#file_properties-templates-list_for_user
  """
  def templates_list_for_user(client) do
    post(client, "/file_properties/templates/list_for_user")
  end

  @doc """
  List the identifiers of the team-owned templates (team token).

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#file_properties-templates-list_for_team
  """
  def templates_list_for_team(client) do
    post(client, "/file_properties/templates/list_for_team")
  end

  @doc """
  Permanently remove a user-owned template.

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#file_properties-templates-remove_for_user
  """
  def templates_remove_for_user(client, template_id) do
    post(client, "/file_properties/templates/remove_for_user", %{"template_id" => template_id})
  end

  @doc """
  Permanently remove a team-owned template (team token).

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#file_properties-templates-remove_for_team
  """
  def templates_remove_for_team(client, template_id) do
    post(client, "/file_properties/templates/remove_for_team", %{"template_id" => template_id})
  end

  @doc """
  Update a user-owned template. `opts` accepts `"name"`, `"description"`
  and `"add_fields"`.

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#file_properties-templates-update_for_user
  """
  def templates_update_for_user(client, template_id, opts \\ %{}) do
    body = Map.merge(%{"template_id" => template_id}, opts)
    post(client, "/file_properties/templates/update_for_user", body)
  end

  @doc """
  Update a team-owned template (team token). `opts` accepts `"name"`,
  `"description"` and `"add_fields"`.

  More info at: https://www.dropbox.com/developers/documentation/http/documentation#file_properties-templates-update_for_team
  """
  def templates_update_for_team(client, template_id, opts \\ %{}) do
    body = Map.merge(%{"template_id" => template_id}, opts)
    post(client, "/file_properties/templates/update_for_team", body)
  end
end
