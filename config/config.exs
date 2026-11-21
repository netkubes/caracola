import Config

config :logger, :default_formatter, metadata: [:service, :call_id]
