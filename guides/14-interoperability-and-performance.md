# Interoperability and performance

Caracola is tested against [SIPp](https://sipp.sourceforge.net), both for
interoperability and under load, and against
[FreeSWITCH](https://signalwire.com/freeswitch),
[baresip](https://github.com/baresip/baresip) and
[Asterisk](https://www.asterisk.org). These tests are excluded by default.
They need `sipp`, `freeswitch` and `baresip` in the `PATH` (for example
`brew install sipp freeswitch baresip`, or `apt install sip-tester baresip`
and the FreeSWITCH packages), and Docker for Asterisk and HEP.

## SIPp

```bash
mix test --only sipp
```

They run SIPp against Caracola services defined in
`test/support/interop_services.ex`, with the scenarios in
`test/interop/scenarios`:

* SIPp as UAC and Caracola as UAS: INVITE, ACK and BYE over UDP, TCP and
  TLS; OPTIONS; REGISTER, with and without digest authentication.
* Caracola as UAC and SIPp as UAS: INVITE, ACK and BYE over UDP and TCP.
* SIPp calling SIPp through a Caracola stateful and stateless proxy, with
  Record-Route.

## FreeSWITCH

```bash
mix test --only freeswitch
```

The tests start their own FreeSWITCH, with the minimal configuration in
`test/interop/freeswitch/freeswitch.xml`: a temporary directory, free ports,
the users 1000 to 1002 and a small dialplan. They drive it through its
event socket (as `fs_cli -x`), with the helper in `test/support/freeswitch.ex`. The
FreeSWITCH modules are taken from `brew --prefix freeswitch`, or from
`/usr/lib/freeswitch/mod`.

* Registrar: REGISTER with digest authentication, refresh and unregister,
  and a wrong password.
* Applications: calls to an echo extension, with hold (re-INVITE with
  `sendonly`), DTMF over INFO and BYE; FreeSWITCH hanging up; an unknown
  extension; a wrong password.
* FreeSWITCH as a B2BUA between two Caracola user agents registered as
  1000 and 1001: calls hung up by each side, busy, and CANCEL.
* Calls originated by FreeSWITCH (`originate`) to a Caracola UAS, and hung
  up by FreeSWITCH.
* `Caracola.B2BUA` between a Caracola user agent and FreeSWITCH (the B leg
  authenticated with digest): calls to the echo extension with hold and
  DTMF over INFO through the bridge, FreeSWITCH hanging up, and CANCEL of
  a call bridged again by FreeSWITCH to a registered user.

All INVITEs from Caracola are challenged (407), and FreeSWITCH asks for
session timers (`Require: timer`) in its responses.

## baresip

```bash
mix test --only baresip
```

Each test starts its own baresip phones (`test/support/baresip.ex`), with a
generated configuration in a temporary directory, without audio devices (a
sine wave as source, a file as player), and drives them through their
`ctrl_tcp` module, whose events (`CALL_ESTABLISHED`, `CALL_CLOSED`...) are
sent to the test. baresip ignores loopback addresses, so these tests need a
non-loopback IPv4 address: the phones and the Caracola services listen on
the first one of the host.

The phones register in a Caracola registrar and proxy for the `malla.test`
domain, with digest authentication, the `Caracola.Outbound` and
`Caracola.EventCompositor` plugins, and Record-Route:

* Registration and unregistration.
* Calls between two phones through the proxy, hung up by each side; an
  unknown user; CANCEL.
* Hold and resume (re-INVITE), and DTMF over INFO.
* Reliable provisional responses: PRACK end to end through the proxy.
* Blind transfer (REFER), and attended transfer (REFER and INVITE with
  Replaces between the phones, and to a Caracola phone with
  `Caracola.Replaces`).
* SIP outbound: REGISTER with `reg-id` and `+sip.instance`, and calls
  through the flows.
* Presence: PUBLISH stored by the proxy, SUBSCRIBE and NOTIFY between the
  phones through the proxy, a change of state, and MESSAGE.
* Presence server: the proxy, with `Caracola.Presence`, answers the
  SUBSCRIBEs of the phones and notifies them the states the others
  publish.

Caracola is also tested as user agent: baresip calling a Caracola UAS, and
Caracola calling baresip, hung up by each side.

And as B2BUA: the phones register in a Caracola registrar with
`Caracola.B2BUA`, that bridges their calls (each leg with its own Call-ID):
calls hung up by each side, hold and resume from both sides, DTMF over
INFO, an unknown user, CANCEL and busy.

## Asterisk

```bash
mix test --only asterisk
```

Asterisk 22 runs in a container (the `andrius/asterisk:22` image), with the
minimal configuration in `test/interop/asterisk`: PJSIP with the users 1000
to 1002, a small dialplan, the manager interface (AMI) and a mailbox. The
helper in `test/support/asterisk.ex` starts it with the docker CLI, using
the `orbstack` context unless `ASTERISK_DOCKER_CONTEXT` names another one,
and drives it through AMI. Its SIP and AMI ports are published on
`127.0.0.1`, and Asterisk announces that address in its messages; it
reaches the Caracola services at the first non-loopback IPv4 address of
the host.

* Registrar: REGISTER with digest authentication, unregister, and a wrong
  password; REGISTER for a user that only accepts SHA-256.
* Applications: calls to an echo extension, with hold, DTMF over INFO and
  BYE; Asterisk hanging up; an unknown extension; a wrong password.
* Asterisk as a B2BUA between two Caracola user agents: calls hung up by
  each side, busy, CANCEL, and a blind transfer started by Caracola
  (REFER, and the NOTIFYs with `message/sipfrag`).
* Events: a `message-summary` (MWI) subscription, and the unsolicited
  message waiting NOTIFY Asterisk sends when a phone registers (accepted
  with `sip_unsolicited_notify/2`).
* Busy lamp field: `dialog` and `presence` subscriptions to the hint of a
  user, with the dialog-info and PIDF documents of Asterisk read by
  `Caracola.DialogInfo.decode/1` and `Caracola.Presence.decode/1`, during a
  call between two Caracola user agents.
* Calls originated by Asterisk (AMI `Originate`) to a Caracola UAS.
* An attended transfer started by Caracola: a REFER with a Replaces in its
  Refer-To (`Caracola.Replaces.refer_to/2`).
* Asterisk as a trunk of a Caracola registrar and proxy that only accepts
  SHA-256: it registers through the proxy, and calls go through it in both
  directions.
* `Caracola.B2BUA` between a Caracola user agent and Asterisk: the echo
  extension with hold and DTMF over INFO through the bridge, and Asterisk
  hanging up.

The Asterisk endpoints use `refer_blind_progress=no`, so that the NOTIFYs
of a transfer are sent when it ends, and
`mwi_subscribe_replaces_unsolicited=yes`, so that MWI can be subscribed to.

## HEP

```bash
mix test --only hep
```

A service with `Caracola.HEP` sends its messages to
[sngrep](https://github.com/irontec/sngrep), listening for HEP in a
container (the `nicolaka/netshoot` image, where sngrep is installed when
it starts). sngrep writes what it gets to a pcap file, that tshark
decodes: the test checks the request and the response, their Call-ID and
the ports of the HEP packets.

## Cluster tests

```bash
epmd -daemon
mix test --only cluster
```

They start Erlang peer nodes (with `:peer`) running a
`Caracola.Registrar.Cluster` service, so they need Erlang distribution:
`epmd` running on the machine.

## Load tests

```bash
LOAD_CALLS=100000 LOAD_RATE=5000 mix test --only load
```

`LOAD_CALLS` (5,000 by default) is the number of calls of each test, and
`LOAD_RATE` (500 by default) the calls per second. The tests are:

* SIPp UAC to a Caracola UAS: INVITE, ACK and BYE over UDP.
* SIPp UAC to SIPp UAS, through a stateful and through a stateless
  Caracola proxy.
* OPTIONS over UDP, with four times the calls and the rate, which prints
  the memory used by each live call.

Each test fails if SIPp reports any failed call.

## Results

On an Apple M2 Max (12 cores, 32 GB), Elixir 1.20 and OTP 29, with SIPp
on the same machine:

| Test | Calls | Rate (calls/s) | Failed |
| --- | --- | --- | --- |
| UAS (INVITE, ACK, BYE) | 100,000 | 5,000 | 0 |
| Stateful proxy | 100,000 | 5,000 | 0 |
| Stateless proxy | 100,000 | 5,000 | 0 |
| OPTIONS | 400,000 | 20,000 | 0 |

There were no retransmissions in the proxy tests. At these rates SIPp
itself takes a large share of the CPU.

## Limits and sizing

* **Live calls.** Each Call-ID is a process, that lives until its last
  transaction ends. Over UDP, a non-INVITE server transaction waits for
  timer J (32 seconds) after its final response, to absorb
  retransmissions. So at 20,000 OPTIONS per second there are about 640,000
  live calls. The `max_calls` option (100,000 by default, up to 1,000,000)
  limits them; requests over the limit are answered with a 503.
* **Memory.** A call waiting only for its timers hibernates, and uses
  about 6 KB. An active call uses about 14 KB.
* **UDP.** Each UDP listener hands its datagrams to one worker per
  scheduler, chosen by the Call-ID: messages of different calls are
  parsed and processed in parallel, and the ones of the same call in
  order.
* **Shutdown.** Calls are spread among several supervisors (eight per
  scheduler). A service with 400,000 live calls stops in about 4 seconds.

## Known limitations

What the plugins do not do yet:

* **Call recording**: metadata updates, pause and resume, recording indications.
* **INFO packages**: `Recv-Info` in UPDATE, PRACK and ACK.
* **Call history**: `Reason` in the entries of failed branches, privacy of the entries.
* **B2BUA**: transfers (REFER) between the legs, forwarding of reliable provisional responses and early UPDATEs.
* **STIR/SHAKEN**: compact form PASSporTs, TNAuthList checks (RFC 8226), `verstat`.
* **Push notifications**: refreshes triggered by the proxy (`sip.pnsreg`), VAPID.
* **Watcher information** and **conference state**: full state only, no partial NOTIFYs.
* **Join**, **Siprec**, **Conference** and **Push**: the media (joining, copying, mixing) and the sending of push notifications are up to the application.
