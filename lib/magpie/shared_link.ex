defmodule Magpie.SharedLink do
  @moduledoc """
  Struct for a shared link returned by the sharing endpoints.

  Fields mirror Dropbox's `SharedLinkMetadata`; any field Dropbox leaves out
  stays `nil`. `path` is kept for backward compatibility — Dropbox reports the
  link's location as `path_lower`.

    * `preview_type` — the viewer's preview type for the file, or `nil` when
      it cannot be previewed
    * `created_timestamp` — when the link was created (ISO 8601 string)
    * `link_permissions` — the raw permissions map, including the effective
      `"audience"`. Besides `"public"`, `"team"`, `"no_one"` and `"password"`
      it may read `"public_logged_in_only"` (signed-in Dropbox users only),
      which the API reports but does not let you set.
  """
  @type t :: %__MODULE__{
          path: String.t() | nil,
          url: String.t() | nil,
          id: String.t() | nil,
          name: String.t() | nil,
          path_lower: String.t() | nil,
          expires: String.t() | nil,
          link_permissions: map() | nil,
          preview_type: String.t() | nil,
          created_timestamp: String.t() | nil
        }

  defstruct path: nil,
            url: nil,
            id: nil,
            name: nil,
            path_lower: nil,
            expires: nil,
            link_permissions: nil,
            preview_type: nil,
            created_timestamp: nil
end
