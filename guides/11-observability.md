# Observability

## Tracing messages

`Caracola.Telemetry.trace(true)` logs every SIP message sent or received,
with the service, direction, transport and address:

```
[info] SIP MyUA -> udp:10.0.0.2:5060
OPTIONS sip:10.0.0.2 SIP/2.0
Via: SIP/2.0/UDP 10.0.0.1:5060;rport;branch=z9hG4bK...
...
```

Messages are logged at the `:info` level. `Caracola.Telemetry.trace(false)`
stops it. It is meant for development: in production, attach your own
handler to the events below, filtering what you need.

## Telemetry events

Caracola emits `:telemetry` events, described in `Caracola.Telemetry`:

| Event | Measurements | Metadata |
|---|---|---|
| `[:caracola, :message, :received]` | `size` | `service`, `message`, `port` |
| `[:caracola, :message, :sent]` | `size` | `service`, `message`, `port` |
| `[:caracola, :call, :start]` | `system_time`, `monotonic_time` | `service`, `call_id` |
| `[:caracola, :call, :stop]` | `duration`, `monotonic_time` | `service`, `call_id` |
| `[:caracola, :uac, :stop]` | `duration` | `service`, `call_id`, `method`, `code` |
| `[:caracola, :uas, :stop]` | `duration` | `service`, `call_id`, `method`, `code` |
| `[:caracola, :dialog, :start]` | `system_time`, `monotonic_time` | `service`, `call_id`, `dialog_id` |
| `[:caracola, :dialog, :stop]` | `duration`, `monotonic_time` | `service`, `call_id`, `dialog_id` |
| `[:caracola, :rate_limit, :reject]` | `count` | `service`, `ip`, `reason` |
| `[:caracola, :rate_limit, :ban]` | `time` | `service`, `ip`, `reason` |
| `[:caracola, :dispatcher, :status]` | | `service`, `uri`, `status` |
| `[:caracola, :overload_control, :drop]` | `count` | `service`, `ip`, `loss` |

`[:caracola, :uac, :stop]` and `[:caracola, :uas, :stop]` are emitted
with the first final response of each transaction: their duration is the
response time.

With `Telemetry.Metrics`:

```elixir
[
  counter("caracola.message.received.size", tags: [:service]),
  distribution("caracola.uas.stop.duration",
    tags: [:service, :method, :code],
    unit: {:native, :millisecond}
  ),
  last_value("caracola.call.start.system_time", tags: [:service])
]
```

## HEP capture

With the `Caracola.HEP` plugin, every SIP message received or sent by the
service is also sent to a capture server (Homer, heplify-server...) with
HEPv3 over UDP:

```elixir
use Malla.Service,
  plugins: [Caracola.HEP],
  sip: [listen: "sip:all:5060"],
  hep: [host: "homer.example.com", port: 9060, capture_id: 101]
```

## Logs

Caracola logs with `Logger`, adding the `:service` and `:call_id`
metadata in the call processes. Add them to your formatter:

```elixir
config :logger, :default_formatter, metadata: [:service, :call_id]
```

## Inspecting calls and dialogs

* `Caracola.Call.find/2` returns the process of a call, if it exists.
* `Caracola.Dialog.list/2` and `Caracola.Dialog.get/1` return its dialogs.
* `Caracola.listeners/1` and `Caracola.Transport.connections/1` return the
  listeners and connections of a service.
