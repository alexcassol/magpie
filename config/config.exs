import Config

if config_env() == :test do
  # Route all requests through Req.Test stubs instead of the network
  config :magpie, req_options: [plug: {Req.Test, Magpie}]
end
