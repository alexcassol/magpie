defmodule Magpie.Client do
  @moduledoc """
  Holds the Dropbox access token used to authenticate every request.

      client = Magpie.Client.new("ACCESS_TOKEN")
  """
  defstruct access_token: nil

  @type access_token :: %{access_token: binary}
  @type t :: %__MODULE__{access_token: access_token}
  @type m :: %__MODULE__{}

  @spec new() :: m
  def new(), do: %__MODULE__{}

  @spec new(access_token) :: t
  def new(access_token) do
    %__MODULE__{access_token: access_token}
  end
end
