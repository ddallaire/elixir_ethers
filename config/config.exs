import Config

config :ethereumex,
  url: "https://eth.llamarpc.com",
  websocket_url: "wss://eth.llamarpc.com"

import_config "#{config_env()}.exs"
