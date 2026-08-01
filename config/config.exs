import Config

config :magpie, base_url: "https://api.dropboxapi.com/2"
config :magpie, upload_url: "https://content.dropboxapi.com/2/"

if config_env() == :test do
  # Route all requests through Req.Test stubs instead of the network
  config :magpie, req_options: [plug: {Req.Test, Magpie}]
end
