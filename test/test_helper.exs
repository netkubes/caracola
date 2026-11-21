Logger.configure(level: :warning)
# Interoperability (SIPp) and load tests run with `mix test --only sipp`
# and `mix test --only load`
ExUnit.start(
  capture_log: true,
  assert_receive_timeout: 1_000,
  exclude: [:sipp, :load, :freeswitch, :baresip, :asterisk, :hep, :cluster]
)
